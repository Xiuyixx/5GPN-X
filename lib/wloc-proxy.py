#!/usr/bin/env python3
"""Scoped Apple WLOC TLS reverse proxy for 5GPN-X.

sniproxy sends only the two managed Apple location hosts to the loopback
listeners below.  The proxy terminates TLS with pre-generated leaf
certificates, forwards the original HTTP request to Apple, and changes only
coordinates in valid ``/clls/wloc`` protobuf responses.  Unknown fields and
Apple's reported accuracy are preserved.  Any parsing or upstream error is
failed closed for the intercepted connection and recorded without logging
BSSIDs or response bodies.
"""

import argparse
import gzip
import json
import logging
import math
import os
import re
import socket
import ssl
import tempfile
import threading
import time
from collections import namedtuple

STATE_PATH = os.environ.get("WLOC_STATE", "/var/lib/5gpn-wloc/state.json")
STATUS_PATH = os.environ.get("WLOC_STATUS", "/var/lib/5gpn-wloc/status.json")
TLS_DIR = os.environ.get("WLOC_TLS_DIR", "/var/lib/5gpn-wloc/tls")
HOST_PORTS = {
    "gs-loc.apple.com": 9080,
    "gs-loc-cn.apple.com": 9081,
}
TARGET_PATH = "/clls/wloc"
MAC_RE = re.compile(r"^[0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5}$")
RESOLVERS = ("1.1.1.1", "8.8.8.8", "9.9.9.9", "223.5.5.5")
LOG = logging.getLogger("5gpn-wloc")
Field = namedtuple("Field", "number wire value raw")


class WlocFormatError(ValueError):
    """The Apple response does not contain a safely patchable WLOC payload."""


def read_varint(data, offset):
    value = 0
    shift = 0
    for _ in range(10):
        if offset >= len(data):
            raise WlocFormatError("truncated varint")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, offset
        shift += 7
    raise WlocFormatError("varint too long")


def encode_varint(value):
    value = int(value)
    if value < 0:
        value += 1 << 64
    if not 0 <= value < 1 << 64:
        raise WlocFormatError("value outside int64")
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def parse_fields(data):
    data = bytes(data)
    fields = []
    offset = 0
    while offset < len(data):
        start = offset
        key, offset = read_varint(data, offset)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise WlocFormatError("protobuf field zero")
        if wire == 0:
            value, offset = read_varint(data, offset)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if offset + size > len(data):
                raise WlocFormatError("truncated fixed field")
            value = data[offset:offset + size]
            offset += size
        elif wire == 2:
            size, offset = read_varint(data, offset)
            if offset + size > len(data):
                raise WlocFormatError("truncated bytes field")
            value = data[offset:offset + size]
            offset += size
        else:
            raise WlocFormatError("unsupported wire type")
        fields.append(Field(number, wire, value, data[start:offset]))
    return fields


def encode_field(number, wire, value):
    key = encode_varint((int(number) << 3) | int(wire))
    if wire == 0:
        return key + encode_varint(value)
    if wire in (1, 5):
        raw = bytes(value)
        expected = 8 if wire == 1 else 4
        if len(raw) != expected:
            raise WlocFormatError("invalid fixed field")
        return key + raw
    if wire == 2:
        raw = bytes(value)
        return key + encode_varint(len(raw)) + raw
    raise WlocFormatError("unsupported wire type")


def _patch_location(data, latitude, longitude, stats):
    fields = parse_fields(data)
    has_lat = any(field.number == 1 and field.wire == 0 for field in fields)
    has_lon = any(field.number == 2 and field.wire == 0 for field in fields)
    if not has_lat or not has_lon:
        return bytes(data), False
    result = []
    for field in fields:
        if field.number == 1 and field.wire == 0:
            result.append(encode_field(1, 0, round(latitude * 100_000_000)))
        elif field.number == 2 and field.wire == 0:
            result.append(encode_field(2, 0, round(longitude * 100_000_000)))
        else:
            result.append(field.raw)
    stats["locations"] += 1
    return b"".join(result), True


def _patch_wifi(data, latitude, longitude, stats):
    fields = parse_fields(data)
    is_wifi = False
    for field in fields:
        if field.number == 1 and field.wire == 2:
            try:
                is_wifi = bool(MAC_RE.fullmatch(field.value.decode("ascii")))
            except UnicodeDecodeError:
                pass
    if not is_wifi:
        return bytes(data), False
    result = []
    changed = False
    for field in fields:
        if field.number == 2 and field.wire == 2:
            try:
                value, patched = _patch_location(field.value, latitude, longitude, stats)
                result.append(encode_field(2, 2, value))
                changed = changed or patched
            except WlocFormatError:
                stats["skipped"] += 1
                result.append(field.raw)
        else:
            result.append(field.raw)
    if changed:
        stats["wifi"] += 1
    return b"".join(result), changed


def _patch_cell(data, latitude, longitude, stats):
    fields = parse_fields(data)
    result = []
    changed = False
    for field in fields:
        if field.number == 5 and field.wire == 2:
            try:
                value, patched = _patch_location(field.value, latitude, longitude, stats)
                result.append(encode_field(5, 2, value))
                changed = changed or patched
            except WlocFormatError:
                stats["skipped"] += 1
                result.append(field.raw)
        else:
            result.append(field.raw)
    if changed:
        stats["cell"] += 1
    return b"".join(result), changed


def _patch_payload(data, latitude, longitude, stats):
    result = []
    before = stats["locations"]
    for field in parse_fields(data):
        if field.number == 2 and field.wire == 2:
            value, _ = _patch_wifi(field.value, latitude, longitude, stats)
            result.append(encode_field(2, 2, value))
        elif field.number in (22, 24) and field.wire == 2:
            value, _ = _patch_cell(field.value, latitude, longitude, stats)
            result.append(encode_field(field.number, 2, value))
        else:
            result.append(field.raw)
    if stats["locations"] == before:
        raise WlocFormatError("no patchable WLOC locations")
    return b"".join(result)


def _patch_frame(data, base, latitude, longitude):
    if base < 0 or len(data) < base + 10:
        raise WlocFormatError("frame too short")
    size = int.from_bytes(data[base + 8:base + 10], "big")
    if size <= 0 or base + 10 + size > len(data):
        raise WlocFormatError("invalid frame length")
    stats = {"wifi": 0, "cell": 0, "locations": 0, "skipped": 0}
    payload = data[base + 10:base + 10 + size]
    patched = _patch_payload(payload, latitude, longitude, stats)
    if len(patched) > 0xFFFF:
        raise WlocFormatError("payload too large")
    result = (data[:base + 8] + len(patched).to_bytes(2, "big") + patched
              + data[base + 10 + size:])
    return result, stats


def _patch_plain(data, latitude, longitude):
    preferred = list(range(0, min(18, max(0, len(data) - 9)), 2))
    limit = min(96, max(0, len(data) - 10))
    preferred.extend(index for index in range(limit + 1) if index not in preferred)
    for base in preferred:
        try:
            return _patch_frame(data, base, latitude, longitude)
        except WlocFormatError:
            pass
    for base in range(min(256, len(data)) + 1):
        stats = {"wifi": 0, "cell": 0, "locations": 0, "skipped": 0}
        try:
            patched = _patch_payload(data[base:], latitude, longitude, stats)
            return data[:base] + patched, stats
        except WlocFormatError:
            pass
    raise WlocFormatError("no patchable WLOC payload")


def patch_wloc_body(data, latitude, longitude):
    latitude = float(latitude)
    longitude = float(longitude)
    if not math.isfinite(latitude) or not -90 <= latitude <= 90:
        raise ValueError("latitude outside -90..90")
    if not math.isfinite(longitude) or not -180 <= longitude <= 180:
        raise ValueError("longitude outside -180..180")
    raw = bytes(data)
    if raw.startswith(b"\x1f\x8b"):
        patched, stats = _patch_plain(gzip.decompress(raw), latitude, longitude)
        return gzip.compress(patched, mtime=0), stats
    return _patch_plain(raw, latitude, longitude)


def load_target(path=STATE_PATH):
    try:
        with open(path, encoding="utf-8") as source:
            state = json.load(source)
        if not state.get("enabled"):
            return None
        latitude = float(state["latitude"])
        longitude = float(state["longitude"])
        if not math.isfinite(latitude) or not -90 <= latitude <= 90:
            return None
        if not math.isfinite(longitude) or not -180 <= longitude <= 180:
            return None
        return {
            "latitude": latitude,
            "longitude": longitude,
            "label": str(state.get("label") or ""),
            "generation": int(state.get("generation") or 0),
        }
    except (OSError, TypeError, ValueError, KeyError, json.JSONDecodeError):
        return None


def _dns_a(host, server, timeout=4):
    query = (b"\x51\x47\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
             + b"".join(bytes([len(part)]) + part.encode("ascii") for part in host.split("."))
             + b"\x00\x00\x01\x00\x01")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(query, (server, 53))
        data, _ = sock.recvfrom(2048)
    finally:
        sock.close()
    if len(data) < 12:
        return None
    offset = 12
    while offset < len(data) and data[offset]:
        offset += 1 + data[offset]
    offset += 5
    while offset + 12 <= len(data):
        kind = int.from_bytes(data[offset + 2:offset + 4], "big")
        size = int.from_bytes(data[offset + 10:offset + 12], "big")
        offset += 12
        if kind == 1 and size == 4 and offset + 4 <= len(data):
            return socket.inet_ntoa(data[offset:offset + 4])
        offset += size
    return None


def resolve_upstream(host):
    for resolver in RESOLVERS:
        try:
            address = _dns_a(host, resolver)
        except (OSError, ValueError):
            address = None
        if address:
            return address
    return None


def _recv_http(sock, initial=b"", limit=8 * 1024 * 1024):
    data = bytearray(initial)
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(16384)
        if not chunk:
            raise OSError("connection closed before HTTP headers")
        data.extend(chunk)
        if len(data) > 65536:
            raise OSError("HTTP headers too large")
    head, body = bytes(data).split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    content_length = None
    chunked = False
    for line in lines[1:]:
        name, sep, value = line.partition(b":")
        if not sep:
            continue
        if name.strip().lower() == b"content-length":
            content_length = int(value.strip())
        elif name.strip().lower() == b"transfer-encoding" and b"chunked" in value.lower():
            chunked = True
    if content_length is not None:
        if content_length > limit:
            raise OSError("HTTP body too large")
        while len(body) < content_length:
            chunk = sock.recv(min(65536, content_length - len(body)))
            if not chunk:
                raise OSError("truncated HTTP body")
            body += chunk
        body = body[:content_length]
    elif chunked:
        while b"\r\n0\r\n\r\n" not in b"\r\n" + body[-64:]:
            chunk = sock.recv(65536)
            if not chunk:
                break
            body += chunk
            if len(body) > limit:
                raise OSError("HTTP body too large")
    return lines, body, chunked


def _dechunk(data):
    result = bytearray()
    while data:
        line, sep, rest = data.partition(b"\r\n")
        if not sep:
            raise OSError("invalid chunked response")
        size = int(line.split(b";", 1)[0], 16)
        if size == 0:
            return bytes(result)
        if len(rest) < size + 2:
            raise OSError("truncated chunk")
        result.extend(rest[:size])
        data = rest[size + 2:]
    raise OSError("missing final chunk")


def forward_request(host, request_lines, body):
    address = resolve_upstream(host)
    if not address:
        raise OSError("upstream DNS failed")
    kept = []
    for line in request_lines[1:]:
        lower = line.lower()
        if lower.startswith((b"host:", b"connection:", b"content-length:",
                             b"accept-encoding:")):
            continue
        if line.strip():
            kept.append(line)
    request = (request_lines[0] + b"\r\nHost: " + host.encode("ascii") + b"\r\n"
               + b"\r\n".join(kept)
               + (b"\r\n" if kept else b"")
               + b"Accept-Encoding: identity\r\nContent-Length: "
               + str(len(body)).encode("ascii") + b"\r\nConnection: close\r\n\r\n" + body)
    raw = socket.create_connection((address, 443), timeout=15)
    try:
        context = ssl.create_default_context()
        with context.wrap_socket(raw, server_hostname=host) as upstream:
            upstream.sendall(request)
            response_lines, response_body, chunked = _recv_http(upstream)
    finally:
        try:
            raw.close()
        except OSError:
            pass
    if not response_lines or b" 200 " not in response_lines[0]:
        raise OSError("Apple returned " + response_lines[0][:80].decode("latin1", "ignore"))
    if chunked:
        response_body = _dechunk(response_body)
    return response_lines, response_body


def _write_status(target, host, patched, stats=None, error=""):
    document = {
        "received_at": time.time(),
        "host": host,
        "generation": target.get("generation", 0) if target else 0,
        "label": target.get("label", "") if target else "",
        "patched": bool(patched),
        "locations": int((stats or {}).get("locations", 0)),
        "error": str(error or "")[:160],
    }
    directory = os.path.dirname(STATUS_PATH)
    try:
        os.makedirs(directory, mode=0o750, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix="status.", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as target_file:
                json.dump(document, target_file, ensure_ascii=False)
            os.chmod(temporary, 0o640)
            os.replace(temporary, STATUS_PATH)
        except Exception:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise
    except OSError:
        pass


def _response_head(lines, body):
    kept = []
    for line in lines[1:]:
        if line.lower().startswith((b"content-length:", b"transfer-encoding:", b"connection:")):
            continue
        kept.append(line)
    return (lines[0] + b"\r\n" + b"\r\n".join(kept)
            + b"\r\nContent-Length: " + str(len(body)).encode("ascii")
            + b"\r\nConnection: close\r\n\r\n")


def handle_connection(connection, host, context):
    target = None
    try:
        connection.settimeout(30)
        with context.wrap_socket(connection, server_side=True) as client:
            request_lines, request_body, _ = _recv_http(client)
            parts = request_lines[0].split()
            if len(parts) < 2 or parts[0] != b"POST" or parts[1].split(b"?", 1)[0] != TARGET_PATH.encode():
                raise OSError("unexpected request path")
            target = load_target()
            response_lines, response_body = forward_request(host, request_lines, request_body)
            patched = False
            stats = None
            if target:
                response_body, stats = patch_wloc_body(
                    response_body, target["latitude"], target["longitude"])
                patched = True
            client.sendall(_response_head(response_lines, response_body) + response_body)
            _write_status(target, host, patched, stats)
    except Exception as exc:  # noqa: BLE001
        LOG.warning("WLOC request failed host=%s type=%s", host, type(exc).__name__)
        _write_status(target, host, False, error=type(exc).__name__)
    finally:
        try:
            connection.close()
        except OSError:
            pass


def serve_listener(host, port, bind):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(
        os.path.join(TLS_DIR, host + ".crt"),
        os.path.join(TLS_DIR, host + ".key"),
    )
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((bind, port))
    listener.listen(128)
    LOG.info("listening host=%s address=%s:%d", host, bind, port)
    while True:
        connection, _ = listener.accept()
        threading.Thread(
            target=handle_connection,
            args=(connection, host, context),
            daemon=True,
        ).start()


def main():
    global STATE_PATH, STATUS_PATH, TLS_DIR  # noqa: PLW0603
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--state", default=STATE_PATH)
    parser.add_argument("--status", default=STATUS_PATH)
    parser.add_argument("--tls-dir", default=TLS_DIR)
    args = parser.parse_args()
    STATE_PATH, STATUS_PATH, TLS_DIR = args.state, args.status, args.tls_dir
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    threads = []
    for host, port in HOST_PORTS.items():
        thread = threading.Thread(target=serve_listener, args=(host, port, args.bind), daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()


if __name__ == "__main__":
    main()
