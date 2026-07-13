#!/usr/bin/env python3
"""Generate a standalone mihomo TUN config from one proxy share URI.

The emitted document is JSON, which is valid YAML 1.2. This keeps the helper
stdlib-only while safely quoting credentials and other user-controlled values.
"""
import base64
import hashlib
import json
import os
import re
import sys
from urllib.parse import parse_qs, unquote, urlparse


def die(message):
    sys.stderr.write(message.rstrip() + "\n")
    raise SystemExit(1)


def b64decode_any(value):
    value = value.strip()
    pad = "=" * (-len(value) % 4)
    for decoder in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return decoder(value + pad).decode("utf-8")
        except Exception:
            pass
    raise ValueError("not base64")


def parse_hostport(value):
    value = re.split(r"[/?#]", value.strip(), 1)[0].strip()
    match = re.match(r"^\[(.+)\]:(\d+)$", value) or re.match(r"^(.+):(\d+)$", value)
    if not match:
        die("cannot parse host:port from %r" % value)
    return require_host(match.group(1)), valid_port(match.group(2))


def require_host(value):
    if not value:
        die("proxy URI missing server host")
    return value


def valid_port(value):
    try:
        port = int(value)
    except (TypeError, ValueError):
        die("proxy URI port must be an integer")
    if not 1 <= port <= 65535:
        die("proxy URI port out of range: %s" % value)
    return port


def parsed_port(parsed, default):
    try:
        return valid_port(parsed.port or default)
    except ValueError as exc:
        die("invalid proxy URI port: %s" % exc)


def query_map(parsed):
    return {key: values[0] for key, values in parse_qs(parsed.query).items()}


def truthy(value):
    return str(value or "").lower() in ("1", "true", "yes", "on")


def tls_fields(proxy, servername, insecure=False):
    proxy["tls"] = True
    if servername:
        proxy["servername"] = servername
    if insecure:
        proxy["skip-cert-verify"] = True


def transport_fields(proxy, network, host=None, path=None, service=None):
    network = (network or "tcp").lower()
    if network in ("ws", "websocket"):
        proxy["network"] = "ws"
        opts = {"path": unquote(path or "/")}
        if host:
            opts["headers"] = {"Host": host}
        proxy["ws-opts"] = opts
    elif network == "grpc":
        proxy["network"] = "grpc"
        proxy["grpc-opts"] = {"grpc-service-name": unquote(service or (path or "").lstrip("/"))}
    elif network in ("http", "h2"):
        proxy["network"] = "h2"
        proxy["h2-opts"] = {"path": unquote(path or "/"), "host": [host] if host else []}


def decode_ss_userinfo(value):
    try:
        decoded = b64decode_any(value)
        if ":" in decoded and re.match(r"^[a-z0-9-]+$", decoded.split(":", 1)[0]):
            method, password = decoded.split(":", 1)
            return method, unquote(password)
    except ValueError:
        pass
    value = unquote(value)
    if ":" not in value:
        die("cannot parse ss:// credentials")
    method, password = value.split(":", 1)
    return method, unquote(password)


def parse_ss(uri):
    rest = uri[5:].split("#", 1)[0].split("?", 1)[0]
    if "@" in rest:
        userinfo, server = rest.rsplit("@", 1)
        method, password = decode_ss_userinfo(userinfo)
        host, port = parse_hostport(server)
    else:
        try:
            decoded = b64decode_any(rest)
        except ValueError:
            die("invalid ss:// payload")
        if "@" not in decoded or ":" not in decoded:
            die("invalid legacy ss:// payload")
        creds, server = decoded.rsplit("@", 1)
        method, password = creds.split(":", 1)
        host, port = parse_hostport(server)
    return {"name": "out", "type": "ss", "server": host, "port": port,
            "cipher": method, "password": password, "udp": True}


def parse_socks(uri):
    rest = re.sub(r"^socks(?:5h|5)?://", "", uri, flags=re.I)
    userinfo, hostport = rest.rsplit("@", 1) if "@" in rest else ("", rest)
    host, port = parse_hostport(hostport)
    proxy = {"name": "out", "type": "socks5", "server": host, "port": port, "udp": True}
    if userinfo:
        user, password = userinfo.split(":", 1) if ":" in userinfo else (userinfo, "")
        proxy["username"] = user
        if password:
            proxy["password"] = password
    return proxy


def parse_vmess(uri):
    try:
        data = json.loads(b64decode_any(uri[8:]))
    except Exception as exc:
        die("invalid vmess:// payload: %s" % exc)
    host, port = require_host(data.get("add")), valid_port(data.get("port") or 443)
    proxy = {"name": "out", "type": "vmess", "server": host, "port": port,
             "uuid": data.get("id", ""), "alterId": int(data.get("aid", 0) or 0),
             "cipher": data.get("scy") or "auto", "udp": True}
    if str(data.get("tls", "")).lower() in ("tls", "true", "1"):
        tls_fields(proxy, data.get("sni") or data.get("host") or host)
    transport_fields(proxy, data.get("net"), data.get("host"), data.get("path"))
    return proxy


def parse_trojan(uri):
    parsed, proxy = urlparse(uri), {"name": "out", "type": "trojan", "udp": True}
    query = query_map(parsed)
    proxy.update(server=require_host(parsed.hostname), port=parsed_port(parsed, 443), password=unquote(parsed.username or ""))
    tls_fields(proxy, query.get("sni") or query.get("peer") or parsed.hostname,
               truthy(query.get("allowInsecure")))
    transport_fields(proxy, query.get("type"), query.get("host"), query.get("path"),
                     query.get("serviceName") or query.get("service_name"))
    return proxy


def parse_vless(uri):
    parsed = urlparse(uri)
    query = query_map(parsed)
    proxy = {"name": "out", "type": "vless", "server": require_host(parsed.hostname),
             "port": parsed_port(parsed, 443), "uuid": unquote(parsed.username or ""), "udp": True}
    if query.get("flow"):
        proxy["flow"] = query["flow"]
    security = (query.get("security") or "tls").lower()
    if security in ("tls", "reality"):
        tls_fields(proxy, query.get("sni") or parsed.hostname, truthy(query.get("allowInsecure")))
    if security == "reality":
        public_key = query.get("pbk") or query.get("public_key")
        if not public_key:
            die("vless reality URI missing public key (pbk)")
        proxy["reality-opts"] = {"public-key": public_key,
                                  "short-id": query.get("sid") or query.get("short_id", "")}
        proxy["client-fingerprint"] = query.get("fp") or "chrome"
    transport_fields(proxy, query.get("type") or query.get("transport"), query.get("host"),
                     query.get("path"), query.get("serviceName") or query.get("service_name"))
    return proxy


def parse_hysteria2(uri):
    parsed, query = urlparse(uri), query_map(urlparse(uri))
    host = require_host(parsed.hostname)
    proxy = {"name": "out", "type": "hysteria2", "server": host,
             "port": parsed_port(parsed, 443), "password": unquote(parsed.username or ""), "udp": True,
             "sni": query.get("sni") or host,
             "skip-cert-verify": truthy(query.get("insecure"))}
    if query.get("obfs"):
        proxy["obfs"] = query["obfs"]
        proxy["obfs-password"] = query.get("obfs-password") or query.get("obfs_password", "")
    return proxy


def parse_tuic(uri):
    parsed, query = urlparse(uri), query_map(urlparse(uri))
    raw_user = unquote(parsed.username or "")
    uuid, password = raw_user.split(":", 1) if ":" in raw_user else (raw_user, unquote(parsed.password or ""))
    host = require_host(parsed.hostname)
    return {"name": "out", "type": "tuic", "server": host,
            "port": parsed_port(parsed, 443), "uuid": uuid, "password": password, "udp": True,
            "sni": query.get("sni") or host,
            "skip-cert-verify": truthy(query.get("allow_insecure")),
            "udp-relay-mode": query.get("udp_relay_mode") or "native",
            "congestion-controller": query.get("congestion_control") or "bbr"}


def parse_anytls(uri):
    parsed, query = urlparse(uri), query_map(urlparse(uri))
    host = require_host(parsed.hostname)
    return {"name": "out", "type": "anytls", "server": host,
            "port": parsed_port(parsed, 443), "password": unquote(parsed.username or ""), "udp": True,
            "sni": query.get("sni") or host,
            "skip-cert-verify": truthy(query.get("insecure"))}


def parse_http(uri):
    parsed = urlparse(uri)
    host = require_host(parsed.hostname)
    proxy = {"name": "out", "type": "http", "server": host,
             "port": parsed_port(parsed, 443 if parsed.scheme.lower() == "https" else 80)}
    if parsed.username:
        proxy["username"] = unquote(parsed.username)
    if parsed.password:
        proxy["password"] = unquote(parsed.password)
    if parsed.scheme.lower() == "https":
        tls_fields(proxy, host)
    return proxy


def parse_proxy_uri(uri):
    low = uri.lower()
    parsers = (("ss://", parse_ss), ("vmess://", parse_vmess), ("trojan://", parse_trojan),
               ("vless://", parse_vless), ("hysteria2://", parse_hysteria2), ("hy2://", parse_hysteria2),
               ("tuic://", parse_tuic), ("anytls://", parse_anytls), ("socks5h://", parse_socks),
               ("socks5://", parse_socks), ("socks://", parse_socks), ("http://", parse_http),
               ("https://", parse_http))
    for prefix, parser in parsers:
        if low.startswith(prefix):
            return parser(uri)
    die("unsupported URI scheme")


def interface_name(name):
    if re.fullmatch(r"[A-Za-z0-9_-]{1,11}", name):
        return "pgw-" + name
    digest = hashlib.sha256(name.encode("utf-8")).hexdigest()[:11]
    return "pgw-" + digest


def main():
    if len(sys.argv) != 3:
        die("usage: mihomo-exit-config.py <name> <uri>")
    name, uri = sys.argv[1], sys.argv[2].strip()
    if name in ("local", "smart") or not re.match(r"^[\w\-\u4e00-\u9fff]{1,16}$", name, re.UNICODE):
        die("invalid exit name")
    proxy = parse_proxy_uri(uri)
    if proxy["type"] in ("socks5", "http"):
        if os.environ.get("PGW_USER"):
            proxy["username"] = os.environ["PGW_USER"]
        if os.environ.get("PGW_PASS"):
            proxy["password"] = os.environ["PGW_PASS"]
    remote_dns = truthy(os.environ.get("PGW_REMOTE_DNS")) or uri.lower().startswith("socks5h://")
    try:
        mtu = int(os.environ.get("MIHOMO_MTU", "1400"))
    except ValueError:
        die("MIHOMO_MTU must be an integer")
    config = {
        "mode": "rule", "log-level": "warning", "ipv6": False, "find-process-mode": "off",
        "tun": {"enable": True, "stack": os.environ.get("MIHOMO_STACK", "gvisor"),
                "device": interface_name(name), "auto-route": False, "auto-redirect": False,
                "strict-route": False, "mtu": mtu},
        "proxies": [proxy], "rules": ["MATCH,out"],
    }
    if remote_dns:
        config["sniffer"] = {"enable": True, "force-dns-mapping": True, "parse-pure-ip": True,
                             "override-destination": True,
                             "sniff": {"TLS": {"ports": [443, 8443]}, "HTTP": {"ports": [80, "8080-8880"]}}}
    sys.stdout.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
