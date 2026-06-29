#!/usr/bin/env python3
"""
Generate a sing-box config for one proxy-gateway egress exit from a proxy URI.

Supports:
  socks5://[user:pass@]host:port         (password may contain @ : / # ? % space
  socks://[user:pass@]host:port           literally — parsed from the rightmost @)
  ss://...   Shadowsocks (SIP002 and legacy base64), including Shadowsocks-2022
             methods (2022-blake3-aes-128-gcm, 2022-blake3-aes-256-gcm,
             2022-blake3-chacha20-poly1305).

Usage:  singbox-exit-config.py <exit-name> <uri>
Emits sing-box JSON on stdout. Exits non-zero with a message on stderr on error.

Env:
  SINGBOX_STACK  TUN network stack: system|gvisor|mixed   (default: system)
  SINGBOX_MTU    TUN MTU                                   (default: 1400)
"""
import base64
import json
import os
import re
import sys
from urllib.parse import parse_qs, unquote, urlparse

PROXY_TYPES = {
    "shadowsocks", "vmess", "trojan", "vless", "hysteria", "hysteria2",
    "tuic", "anytls", "shadowtls", "socks", "http",
}

SS_METHODS = {
    "2022-blake3-aes-128-gcm",
    "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
    "aes-128-gcm",
    "aes-192-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "xchacha20-ietf-poly1305",
    "chacha20-ietf",
    "aes-128-ctr",
    "aes-256-ctr",
    "aes-128-cfb",
    "aes-256-cfb",
    "rc4-md5",
    "none",
    "plain",
}


def die(msg):
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(1)


def b64decode_any(s):
    s = s.strip()
    pad = "=" * (-len(s) % 4)
    for dec in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return dec(s + pad).decode("utf-8")
        except Exception:
            continue
    raise ValueError("not base64")


def parse_hostport(s):
    s = s.strip()
    # Ignore accidental URI tail/comments after the host:port portion.
    s = re.split(r"[/?#]", s, 1)[0].strip()
    # [v6]:port
    m = re.match(r"^\[(.+)\]:(\d+)$", s)
    if m:
        return m.group(1), int(m.group(2))
    m = re.match(r"^(.+):(\d+)$", s)
    if m:
        return m.group(1), int(m.group(2))
    die("cannot parse host:port from %r" % s)


def parse_ss(uri):
    rest = uri[len("ss://"):]
    rest = rest.split("#", 1)[0]   # drop tag
    rest = rest.split("?", 1)[0]   # drop plugin/query (plugins unsupported)

    if "@" in rest:
        userinfo, server = rest.rsplit("@", 1)
        method, password = decode_ss_userinfo(userinfo)
        host, port = parse_hostport(server)
    else:
        # legacy: base64(method:password@host:port)
        try:
            dec = b64decode_any(rest)
        except ValueError:
            die("invalid ss:// (not SIP002 and not valid base64)")
        if "@" not in dec or ":" not in dec:
            die("invalid legacy ss:// payload")
        creds, server = dec.rsplit("@", 1)
        method, password = creds.split(":", 1)
        host, port = parse_hostport(server)

    if not method:
        die("ss:// missing method")
    return host, port, method, password


def decode_ss_userinfo(userinfo):
    # SIP002 userinfo is usually base64(method:password); for 2022 it is often
    # the plaintext "method:password" (password itself base64).
    try:
        dec = b64decode_any(userinfo)
        if ":" in dec:
            m = dec.split(":", 1)[0]
            if re.match(r"^[a-z0-9-]+$", m):
                return dec.split(":", 1)
    except ValueError:
        pass
    plain = unquote(userinfo)
    if ":" in plain:
        return plain.split(":", 1)
    die("cannot parse ss:// credentials")


def parse_socks(uri):
    # Parse manually (not urlparse) so special characters in the password
    # (@ : / # ? % space etc.) are taken LITERALLY on a single line — no URL
    # encoding required. host:port is always the last "@"-separated segment, so
    # splitting on the rightmost "@" is unambiguous regardless of password chars.
    rest = re.sub(r"^socks(?:5h|5)?://", "", uri, flags=re.I)
    if "@" in rest:
        userinfo, hostport = rest.rsplit("@", 1)
    else:
        userinfo, hostport = "", rest
    hostport = re.split(r"[/?#]", hostport, 1)[0].strip()
    host, port = parse_hostport(hostport)
    user = password = None
    if userinfo:
        # Username is everything up to the FIRST ":"; the rest is the password
        # (so passwords may contain ":"). Taken literally — not percent-decoded.
        if ":" in userinfo:
            user, password = userinfo.split(":", 1)
        else:
            user = userinfo
    return host, port, (user or None), (password or None)


def query_map(u):
    return {k: v[0] for k, v in parse_qs(u.query).items()}


def tls_block(server_name, insecure=False):
    block = {"enabled": True}
    if server_name:
        block["server_name"] = server_name
    if insecure:
        block["insecure"] = True
    return block


def transport_block(net, host=None, path=None, service=None):
    net = (net or "tcp").lower()
    if net in ("ws", "websocket"):
        block = {"type": "ws", "path": path or "/"}
        if host:
            block["headers"] = {"Host": host}
        return block
    if net == "grpc":
        return {"type": "grpc", "service_name": service or (path or "").lstrip("/")}
    return None


def tag_from_uri(u, fallback):
    return unquote(u.fragment).strip() or fallback


def parse_vmess(uri):
    try:
        data = json.loads(b64decode_any(uri[len("vmess://"):]))
    except Exception as e:
        die("invalid vmess:// payload: %s" % e)
    host = data.get("add")
    port = int(data.get("port") or 443)
    outbound = {
        "type": "vmess",
        "tag": "out",
        "server": host,
        "server_port": port,
        "uuid": data.get("id", ""),
        "alter_id": int(data.get("aid", 0) or 0),
        "security": data.get("scy") or "auto",
    }
    if str(data.get("tls", "")).lower() in ("tls", "true", "1"):
        outbound["tls"] = tls_block(data.get("sni") or data.get("host") or host)
    tr = transport_block(data.get("net"), data.get("host"), data.get("path"))
    if tr:
        outbound["transport"] = tr
    return outbound, host, port


def parse_trojan(uri):
    u = urlparse(uri)
    q = query_map(u)
    host = u.hostname
    port = u.port or 443
    outbound = {
        "type": "trojan",
        "tag": "out",
        "server": host,
        "server_port": port,
        "password": unquote(u.username or ""),
        "tls": tls_block(q.get("sni") or q.get("peer") or host, q.get("allowInsecure") in ("1", "true")),
    }
    tr = transport_block(q.get("type"), q.get("host"), q.get("path"), q.get("serviceName") or q.get("service_name"))
    if tr:
        outbound["transport"] = tr
    return outbound, host, port


def parse_vless(uri):
    u = urlparse(uri)
    q = query_map(u)
    host = u.hostname
    port = u.port or 443
    outbound = {
        "type": "vless",
        "tag": "out",
        "server": host,
        "server_port": port,
        "uuid": unquote(u.username or ""),
    }
    if q.get("flow"):
        outbound["flow"] = q["flow"]
    security = (q.get("security") or "tls").lower()
    if security in ("tls", "reality"):
        tls = tls_block(q.get("sni") or host, q.get("allowInsecure") in ("1", "true"))
        if security == "reality":
            tls["reality"] = {"enabled": True, "public_key": q.get("pbk") or q.get("public_key", "")}
            if q.get("sid") or q.get("short_id"):
                tls["reality"]["short_id"] = q.get("sid") or q.get("short_id")
        outbound["tls"] = tls
    tr = transport_block(q.get("type") or q.get("transport"), q.get("host"), q.get("path"), q.get("serviceName") or q.get("service_name"))
    if tr:
        outbound["transport"] = tr
    return outbound, host, port


def parse_hysteria2(uri):
    u = urlparse(uri)
    q = query_map(u)
    host = u.hostname
    port = u.port or 443
    outbound = {
        "type": "hysteria2",
        "tag": "out",
        "server": host,
        "server_port": port,
        "password": unquote(u.username or ""),
        "tls": tls_block(q.get("sni") or host, q.get("insecure") in ("1", "true")),
    }
    if q.get("obfs"):
        outbound["obfs"] = {"type": q.get("obfs"), "password": q.get("obfs-password") or q.get("obfs_password", "")}
    return outbound, host, port


def parse_tuic(uri):
    u = urlparse(uri)
    q = query_map(u)
    host = u.hostname
    port = u.port or 443
    if ":" in (u.username or ""):
        uuid, password = unquote(u.username).split(":", 1)
    else:
        uuid, password = unquote(u.username or ""), unquote(u.password or "")
    outbound = {
        "type": "tuic",
        "tag": "out",
        "server": host,
        "server_port": port,
        "uuid": uuid,
        "password": password,
        "tls": tls_block(q.get("sni") or host, q.get("allow_insecure") in ("1", "true")),
    }
    return outbound, host, port


def parse_anytls(uri):
    u = urlparse(uri)
    q = query_map(u)
    host = u.hostname
    port = u.port or 443
    outbound = {
        "type": "anytls",
        "tag": "out",
        "server": host,
        "server_port": port,
        "password": unquote(u.username or ""),
        "tls": tls_block(q.get("sni") or host, q.get("insecure") in ("1", "true")),
    }
    return outbound, host, port


def parse_http(uri):
    u = urlparse(uri)
    host = u.hostname
    port = u.port or (443 if u.scheme.lower() == "https" else 80)
    outbound = {"type": "http", "tag": "out", "server": host, "server_port": port}
    if u.username:
        outbound["username"] = unquote(u.username)
    if u.password:
        outbound["password"] = unquote(u.password)
    if u.scheme.lower() == "https":
        outbound["tls"] = tls_block(host)
    return outbound, host, port


def parse_proxy_uri(uri):
    low = uri.lower()
    if low.startswith("ss://"):
        host, port, method, password = parse_ss(uri)
        return {"type": "shadowsocks", "tag": "out", "server": host, "server_port": port, "method": method, "password": password}, host, port
    if low.startswith(("socks5h://", "socks5://", "socks://")):
        host, port, user, password = parse_socks(uri)
        outbound = {"type": "socks", "tag": "out", "server": host, "server_port": port, "version": "5"}
        if user:
            outbound["username"] = user
        if password:
            outbound["password"] = password
        return outbound, host, port
    if low.startswith("vmess://"):
        return parse_vmess(uri)
    if low.startswith("trojan://"):
        return parse_trojan(uri)
    if low.startswith("vless://"):
        return parse_vless(uri)
    if low.startswith(("hysteria2://", "hy2://")):
        return parse_hysteria2(uri)
    if low.startswith("tuic://"):
        return parse_tuic(uri)
    if low.startswith("anytls://"):
        return parse_anytls(uri)
    if low.startswith(("http://", "https://")):
        return parse_http(uri)
    die("unsupported URI scheme (expected ss://, vmess://, trojan://, vless://, hysteria2://, tuic://, anytls://, socks5:// or http://)")


def main():
    if len(sys.argv) != 3:
        die("usage: singbox-exit-config.py <name> <uri>")
    name, uri = sys.argv[1], sys.argv[2].strip()
    if not re.match(r"^[\w\-\u4e00-\u9fff]{1,16}$", name, re.UNICODE) or name == "local":
        die("invalid exit name")

    # gvisor (userspace netstack) is the reliable tun2socks stack; the "system"
    # stack does not forward on many kernels. Override with SINGBOX_STACK if needed.
    stack = os.environ.get("SINGBOX_STACK", "gvisor")
    try:
        mtu = int(os.environ.get("SINGBOX_MTU", "1400"))
    except ValueError:
        mtu = 1400

    # Remote DNS ("socks5h"): resolve the target hostname at the exit server.
    # We recover the hostname by sniffing the TLS ClientHello / HTTP Host in the
    # TUN, then forward the domain (not the IP) to the upstream proxy.
    remote_dns = os.environ.get("PGW_REMOTE_DNS", "").lower() in ("1", "true", "yes", "on")

    low = uri.lower()
    if low.startswith("socks5h://"):
        remote_dns = True
    outbound, host, port = parse_proxy_uri(uri)

    # Credentials supplied out-of-band (PGW_USER/PGW_PASS) win for SOCKS5/HTTP,
    # so passwords with @ : / # ? need no URL-encoding.
    if outbound.get("type") in ("socks", "http"):
        env_user = os.environ.get("PGW_USER", "")
        env_pass = os.environ.get("PGW_PASS", "")
        if env_user:
            outbound["username"] = env_user
        if env_pass:
            outbound["password"] = env_pass

    inbound = {
        "type": "tun",
        "tag": "pgw-in",
        "interface_name": "pgw-" + name,
        "address": ["172.19.0.1/30"],
        "mtu": mtu,
        "auto_route": False,
        "strict_route": False,
        "stack": stack,
        "sniff": remote_dns,
    }
    if remote_dns:
        # Replace the (locally-resolved) destination IP with the sniffed domain
        # so the upstream proxy performs the DNS lookup.
        inbound["sniff_override_destination"] = True

    config = {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [inbound],
        "outbounds": [outbound],
        "route": {"final": "out"},
    }
    sys.stdout.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
