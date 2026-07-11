#!/usr/bin/env python3
"""Fail-open WhatsApp no-SNI shim for the 5GPN-X TCP/443 listener.

Derived from Loading886/iOS-5GPN-WhatsApp-Patch (MIT). Only ED/WA Noise
prefixes from configured client CIDRs go to g.whatsapp.net; everything else is
replayed unchanged to the local sniproxy backend.
"""
import asyncio
import ipaddress
import logging
import os
import socket
import struct
import time

LISTEN = os.environ.get("WA_SHIM_LISTEN", "0.0.0.0")
PORT = int(os.environ.get("WA_SHIM_PORT", "443"))
BACKEND = os.environ.get("WA_SHIM_BACKEND", "127.0.0.1:8443")
WA_HOST = os.environ.get("WA_SHIM_WA_HOST", "g.whatsapp.net")
WA_PORT = int(os.environ.get("WA_SHIM_WA_PORT", "443"))
RESOLVERS = [x.strip() for x in os.environ.get("WA_SHIM_RESOLVER", "1.1.1.1,8.8.8.8").split(",") if x.strip()]
SELF_IPS = {x.strip() for x in os.environ.get("WA_SHIM_SELF_IPS", "").split(",") if x.strip()}
SELF_IPS.update({"127.0.0.1", "::1", "0.0.0.0", "::"})
ALLOW = []
for value in os.environ.get("WA_SHIM_ALLOW_CIDR", "172.22.0.0/16,127.0.0.0/8").split(","):
    try:
        ALLOW.append(ipaddress.ip_network(value.strip(), strict=False))
    except ValueError:
        pass
PEEK_TIMEOUT = float(os.environ.get("WA_SHIM_PEEK_TIMEOUT", "3"))
CONNECT_TIMEOUT = float(os.environ.get("WA_SHIM_CONNECT_TIMEOUT", "8"))
DNS_TTL = float(os.environ.get("WA_SHIM_DNS_TTL", "60"))
MAX_CONN = int(os.environ.get("WA_SHIM_MAXCONN", "8192"))
WA_PREFIXES = (b"ED", b"WA")
KNOWN = (bytes.fromhex("45440001"), bytes.fromhex("57410603"))
ACTIVE = 0
_CACHE = ([], 0.0)

logging.basicConfig(level=logging.INFO, format="%(asctime)s wa-shim %(message)s")
LOG = logging.getLogger("wa-shim")


def hostport(value, default):
    if value.startswith("[") and "]:" in value:
        host, port = value[1:].rsplit("]:", 1)
        return host, int(port) if port.isdigit() else default
    host, sep, port = value.rpartition(":")
    # A bare IPv6 literal has multiple colons and no port.
    return (host, int(port)) if sep and port.isdigit() and value.count(":") == 1 else (value, default)


BACKEND_HOST, BACKEND_PORT = hostport(BACKEND, 8443)


def source_allowed(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return any(address in network for network in ALLOW)


def classify(data):
    if len(data) >= 2 and data[:2] in WA_PREFIXES:
        return "whatsapp", "known" if data[:4] in KNOWN else "new"
    return "backend", ""


def qname(host):
    return b"".join(bytes([len(label)]) + label.encode("idna") for label in host.rstrip(".").split(".")) + b"\0"


def skip_name(data, offset):
    while offset < len(data):
        size = data[offset]
        if size == 0:
            return offset + 1
        if size & 0xC0 == 0xC0:
            return offset + 2
        offset += size + 1
    return offset


def parse_answers(data, transaction, question):
    if len(data) < 12:
        return []
    txid, flags, questions, answers = struct.unpack(">HHHH", data[:8])
    if txid != transaction or not flags & 0x8000 or questions < 1 or data[12:12 + len(question)].lower() != question.lower():
        return []
    offset = 12
    for _ in range(questions):
        offset = skip_name(data, offset) + 4
    result = []
    for _ in range(min(answers, 64)):
        offset = skip_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, _, _, length = struct.unpack(">HHIH", data[offset:offset + 10])
        offset += 10
        if offset + length > len(data):
            break
        if rtype == 1 and length == 4:
            result.append(socket.inet_ntoa(data[offset:offset + 4]))
        offset += length
    return result


def query_a(host, resolver):
    resolver_host, resolver_port = hostport(resolver, 53)
    transaction = int.from_bytes(os.urandom(2), "big")
    question = qname(host)
    packet = struct.pack(">HHHHHH", transaction, 0x0100, 1, 0, 0, 0) + question + struct.pack(">HH", 1, 1)
    try:
        family = socket.AF_INET6 if ":" in resolver_host else socket.AF_INET
        target = (resolver_host, resolver_port, 0, 0) if family == socket.AF_INET6 else (resolver_host, resolver_port)
        sock = socket.socket(family, socket.SOCK_DGRAM)
    except OSError:
        return []
    try:
        sock.settimeout(3)
        sock.connect(target)
        sock.send(packet)
        return parse_answers(sock.recv(4096), transaction, question)
    except OSError:
        return []
    finally:
        sock.close()


async def resolve_edge():
    global _CACHE
    try:
        ipaddress.ip_address(WA_HOST)
        return [] if WA_HOST in SELF_IPS else [WA_HOST]
    except ValueError:
        pass
    if _CACHE[0] and time.time() - _CACHE[1] < DNS_TTL:
        return _CACHE[0]
    loop = asyncio.get_running_loop()
    addresses = []
    for resolver in RESOLVERS:
        addresses = await loop.run_in_executor(None, query_a, WA_HOST, resolver)
        if addresses:
            break
    clean = []
    for address in addresses:
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError:
            continue
        if address not in SELF_IPS and parsed.is_global:
            clean.append(address)
    _CACHE = (clean, time.time())
    return clean


async def peek(reader):
    deadline = asyncio.get_running_loop().time() + PEEK_TIMEOUT
    data = b""
    while len(data) < 8:
        if len(data) >= 2 and (data[:2] not in WA_PREFIXES or len(data) >= 4):
            break
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            break
        try:
            chunk = await asyncio.wait_for(reader.read(8 - len(data)), remaining)
        except (asyncio.TimeoutError, OSError):
            break
        if not chunk:
            break
        data += chunk
    return data


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.write_eof()
        except (OSError, AttributeError):
            pass


async def relay(client_reader, client_writer, host, port, first):
    try:
        upstream_reader, upstream_writer = await asyncio.wait_for(asyncio.open_connection(host, port), CONNECT_TIMEOUT)
        upstream_writer.write(first)
        await upstream_writer.drain()
        await asyncio.gather(pipe(client_reader, upstream_writer), pipe(upstream_reader, client_writer))
        upstream_writer.close()
        return True
    except (OSError, asyncio.TimeoutError):
        return False


async def handle(reader, writer):
    global ACTIVE
    source = (writer.get_extra_info("peername") or ("?",))[0]
    if ACTIVE >= MAX_CONN:
        writer.close()
        return
    ACTIVE += 1
    try:
        first = await peek(reader)
        route, version = classify(first)
        if route == "whatsapp" and source_allowed(source):
            addresses = await resolve_edge()
            if addresses:
                LOG.info("WhatsApp %s src=%s -> %s", version, source, addresses[0])
                if await relay(reader, writer, addresses[0], WA_PORT, first):
                    writer.close()
                    return
                LOG.warning("WhatsApp edge unavailable; failing open to backend for src=%s", source)
        await relay(reader, writer, BACKEND_HOST, BACKEND_PORT, first)
    finally:
        ACTIVE -= 1
        writer.close()


async def main():
    server = await asyncio.start_server(handle, LISTEN, PORT, backlog=4096)
    LOG.info("listening %s:%d backend=%s:%d allow=%s", LISTEN, PORT, BACKEND_HOST, BACKEND_PORT, ALLOW)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
