"""Real mosdns DNS behavior, entirely on loopback with synthetic upstreams.

Run with PGW_TEST_MOSDNS=/absolute/path/to/mosdns (v5.3.4). No production
configuration, network namespace, public DNS, or firewall is touched.
"""
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('PGW_TEST_MOSDNS', '')


class Upstream(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    # Join request handlers during cleanup before closing their UDP socket.
    daemon_threads = False


class Answer(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        offset = 12
        while data[offset]:
            offset += data[offset] + 1
        offset += 1
        qtype = struct.unpack('!H', data[offset:offset + 2])[0]
        question = data[12:offset + 4]
        records = b''
        if qtype == 1:
            records = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4)
            records += socket.inet_aton(self.server.answer)
        header = data[:2] + struct.pack('!HHHHH', 0x8180, 1, bool(records), 0, 0)
        sock.sendto(header + question + records, self.client_address)


def query(port, name, private=True, qtype=1):
    question = b''.join(bytes([len(x)]) + x.encode() for x in name.split('.'))
    packet = struct.pack('!HHHHHH', 123, 0x100, 1, 0, 0, 0)
    packet += question + b'\0' + struct.pack('!HH', qtype, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(3)
        sock.bind(('127.0.0.2' if private else '127.0.0.1', 0))
        sock.connect(('127.0.0.1', port))
        sock.sendall(struct.pack('!H', len(packet)) + packet)
        def receive(size):
            result = b''
            while len(result) < size:
                chunk = sock.recv(size - len(result))
                if not chunk:
                    raise OSError('unexpected DNS EOF')
                result += chunk
            return result
        data = receive(struct.unpack('!H', receive(2))[0])
    answers = struct.unpack('!H', data[6:8])[0]
    return socket.inet_ntoa(data[-4:]) if answers and qtype == 1 else None


@unittest.skipUnless(BINARY, 'set PGW_TEST_MOSDNS for real-engine loopback tests')
class APNsDNSIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.upstreams = []
        for ip in ('203.0.113.7', '198.51.100.7'):
            server = Upstream(('127.0.0.1', 0), Answer)
            server.answer = ip
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            self.upstreams.append(server.server_address[1])
        self.proc = None
        self.addCleanup(self.stop)

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            self.proc.wait(timeout=5)
            self.proc = None

    def start(self, action=''):
        self.stop()
        domains = 'push.apple.com\nexample.cn\n'
        (self.base / 'chinalist.txt').write_text(domains)
        (self.base / 'gfwlist.txt').write_text('push.apple.com\nexample.org\n')
        for kind in ('direct', 'proxy', 'block'):
            (self.base / ('override-' + kind + '.txt')).write_text(
                'push.apple.com\n' if action == kind else '')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        text = (ROOT / 'lib/mosdns.yaml.template').read_text()
        # Only the fixture's transport and private source are adapted. All
        # domain matchers, sequence order, caches and goto actions are real.
        text = text.replace('/etc/mosdns/', str(self.base) + '/')
        text = text.replace('client_ip 172.22.0.0/16', 'client_ip 127.0.0.2/32')
        text = text.replace('"0.0.0.0:853"', '"127.0.0.1:%d"' % self.port)
        text = '\n'.join(x for x in text.splitlines()
                         if not x.lstrip().startswith(('cert:', 'key:'))) + '\n'
        text = text.replace('__SERVER_IP__', '192.0.2.1').replace('__CACHE_SIZE__', '100')
        # No external fallback traffic, even if the fixture is slow or fails.
        for address in ('1.1.1.1:53', '8.8.8.8:53', '22.22.22.22:53'):
            text = text.replace('- addr: ' + address,
                                '- addr: udp://127.0.0.1:%d' % self.upstreams[0])
        for side, port in zip(('REMOTE', 'LOCAL'), self.upstreams):
            for tier in ('PRIMARY', 'SECONDARY'):
                text = text.replace('__%s_%s_UPSTREAMS__' % (side, tier),
                                    '        - addr: udp://127.0.0.1:%d' % port)
        config = self.base / 'config.yaml'
        config.write_text(text)
        log = self.base / 'engine.log'
        with log.open('wb') as output:
            self.proc = subprocess.Popen([BINARY, 'start', '-c', str(config)],
                                         stdout=output, stderr=subprocess.STDOUT)
        for _ in range(100):
            if self.proc.poll() is not None:
                self.fail(log.read_text())
            try:
                with socket.create_connection(('127.0.0.1', self.port), timeout=.1):
                    return
            except OSError:
                time.sleep(.03)
        self.fail('mosdns did not listen: ' + log.read_text())

    def test_private_exception_public_policy_and_suffix_boundaries(self):
        self.start()
        for name in ('push.apple.com', '1-courier.push.apple.com',
                     'courier.sandbox.push.apple.com'):
            with self.subTest(name=name):
                # APNs is present in BOTH downloaded lists. The exception must
                # still use remote real DNS rather than local DNS or synthesis.
                self.assertEqual(query(self.port, name), '203.0.113.7')
                self.assertIsNone(query(self.port, name, qtype=28))
                self.assertEqual(query(self.port, name, private=False), '198.51.100.7')
        for name in ('example.org', 'apple.com', 'notpush.apple.com',
                     'push.apple.com.example.org'):
            self.assertEqual(query(self.port, name), '192.0.2.1')
        self.assertEqual(query(self.port, 'example.cn'), '198.51.100.7')
        self.assertEqual(query(self.port, 'example.org', private=False), '203.0.113.7')

    def test_explicit_overrides_still_win_and_public_is_unchanged(self):
        for action, expected in (('block', None), ('direct', '198.51.100.7'),
                                 ('proxy', '192.0.2.1')):
            with self.subTest(action=action):
                self.start(action)
                self.assertEqual(query(self.port, '1-courier.push.apple.com'), expected)
                self.assertIsNone(query(self.port, '1-courier.push.apple.com', qtype=28))
                self.assertEqual(query(self.port, '1-courier.push.apple.com', private=False),
                                 '198.51.100.7')


if __name__ == '__main__':
    unittest.main()
