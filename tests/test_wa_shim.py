#!/usr/bin/env python3
import asyncio
import importlib.util
import ipaddress
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.update(WA_SHIM_ALLOW_CIDR="172.22.0.0/16", WA_SHIM_SELF_IPS="127.0.0.1")
spec = importlib.util.spec_from_file_location("wa_shim", os.path.join(ROOT, "wa-shim.py"))
wa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wa)

assert wa.classify(b"ED\x00\x01x") == ("whatsapp", "known")
assert wa.classify(b"WA\x06\x03x") == ("whatsapp", "known")
assert wa.classify(b"ED\x00\x99x") == ("whatsapp", "new")
assert wa.classify(b"\x16\x03\x01") == ("backend", "")
assert wa.classify(b"E") == ("backend", "")
assert wa.source_allowed("172.22.1.2") and not wa.source_allowed("8.8.8.8")

question = wa.qname("g.whatsapp.net")
txid = 1234
packet = struct.pack(">HHHHHH", txid, 0x8180, 1, 1, 0, 0) + question + struct.pack(">HH", 1, 1)
packet += b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + ipaddress.ip_address("1.2.3.4").packed
assert wa.parse_answers(packet, txid, question) == ["1.2.3.4"]
assert wa.parse_answers(packet, 9999, question) == []
assert wa.hostport("1.1.1.1:5353", 53) == ("1.1.1.1", 5353)
assert wa.hostport("[2606:4700:4700::1111]:5353", 53) == ("2606:4700:4700::1111", 5353)
assert wa.hostport("2606:4700:4700::1111", 53) == ("2606:4700:4700::1111", 53)
assert wa.hostport("1.1.1.1", 53) == ("1.1.1.1", 53)
assert "127.0.0.1" in wa.SELF_IPS and "::1" in wa.SELF_IPS


async def fail_open_on_edge_error():
    calls = []
    original_relay, original_resolve, original_allowed = wa.relay, wa.resolve_edge, wa.source_allowed
    async def fake_relay(_reader, _writer, host, _port, _first):
        calls.append(host)
        return host == wa.BACKEND_HOST
    async def fake_resolve():
        return ["1.1.1.1"]
    wa.relay, wa.resolve_edge, wa.source_allowed = fake_relay, fake_resolve, lambda _src: True
    class Writer:
        def get_extra_info(self, _name): return ("172.22.1.2", 1234)
        def close(self): pass
    reader = asyncio.StreamReader(); reader.feed_data(b"ED\0\1"); reader.feed_eof()
    await wa.handle(reader, Writer())
    wa.relay, wa.resolve_edge, wa.source_allowed = original_relay, original_resolve, original_allowed
    return calls


assert asyncio.run(fail_open_on_edge_error()) == ["1.1.1.1", wa.BACKEND_HOST]


async def fragmented_peek():
    reader = asyncio.StreamReader()
    reader.feed_data(b"E")
    await asyncio.sleep(0)
    reader.feed_data(b"D\x00\x01rest")
    reader.feed_eof()
    return await wa.peek(reader)


assert asyncio.run(fragmented_peek()).startswith(b"ED\x00\x01")
print("wa shim policy OK")
