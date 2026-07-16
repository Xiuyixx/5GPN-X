#!/usr/bin/env python3
"""Build a mihomo smart-routing TUN config from gateway rules."""
import hashlib
import ipaddress
import json
import os
import re
import shutil
import sys
from urllib.parse import urldefrag


EXITS_DIR = os.environ.get("EXITS_DIR", "/etc/5gpn/exits")
WG_DIR = os.environ.get("WG_DIR", "/etc/wireguard")
CACHE_DIR = os.environ.get("PGW_RULESET_CACHE", "/etc/5gpn/rulesets")
POLICY_MAP_FILE = os.environ.get("PGW_POLICY_MAP", "/etc/5gpn/policy-map.conf")
DEFAULT_TARGET = os.environ.get("PGW_DEFAULT_TARGET", "direct")
INTERVAL = int(os.environ.get("PGW_RULESET_INTERVAL", "86400"))
GEOSITE_MRS = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/%s.mrs"
GEOIP_MRS = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/%s.mrs"
DOMAIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)+$")


def die(message):
    sys.stderr.write(message.rstrip() + "\n")
    raise SystemExit(1)


def load_policy_map():
    mapping = {}
    try:
        with open(POLICY_MAP_FILE, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    mapping[key.strip()] = value.strip()
    except OSError:
        pass
    return mapping


def parse_endpoint(value):
    value = value.strip()
    if value.startswith("[") and "]:" in value:
        host, port = value[1:].rsplit("]:", 1)
    else:
        host, _, port = value.rpartition(":")
    return host, int(port) if port.isdigit() else 51820


def wg_to_proxy(name, path):
    interface, peer, section = {}, {}, ""
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("["):
                section = line.strip("[]").lower()
                continue
            if "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            (interface if section == "interface" else peer)[key.lower()] = value
    host, port = parse_endpoint(peer.get("endpoint", ""))
    addresses = [item.strip() for item in interface.get("address", "").split(",") if item.strip()]
    if not host or not addresses:
        die("invalid WireGuard exit '%s'" % name)
    ipv4 = next((item for item in addresses if ":" not in item), "")
    ipv6 = next((item for item in addresses if ":" in item), "")
    if not ipv4:
        die("WireGuard exit '%s' needs an IPv4 Interface Address" % name)
    proxy = {"name": name, "type": "wireguard", "server": host, "port": port,
             "ip": ipv4, "private-key": interface.get("privatekey", ""),
             "public-key": peer.get("publickey", ""), "udp": True,
             "allowed-ips": [item.strip() for item in peer.get("allowedips", "0.0.0.0/0").split(",") if item.strip()]}
    if ipv6:
        proxy["ipv6"] = ipv6
    if peer.get("presharedkey"):
        proxy["pre-shared-key"] = peer["presharedkey"]
    if interface.get("mtu", "").isdigit():
        proxy["mtu"] = int(interface["mtu"])
    if peer.get("persistentkeepalive", "").isdigit():
        proxy["persistent-keepalive"] = int(peer["persistentkeepalive"])
    return proxy


def build_exit_proxy(name):
    config_path = os.path.join(EXITS_DIR, name + ".yaml")
    if os.path.exists(config_path):
        try:
            with open(config_path, encoding="utf-8") as handle:
                proxy = dict(json.load(handle)["proxies"][0])
        except Exception as exc:
            die("cannot read exit '%s' config: %s" % (name, exc))
        proxy["name"] = name
        return proxy
    wg_path = os.path.join(WG_DIR, "pgw-%s.conf" % name)
    if os.path.exists(wg_path):
        return wg_to_proxy(name, wg_path)
    die("rule references unknown exit: '%s' (add it first)" % name)


def parse_classical_rules(text):
    payload = []
    for raw in text.splitlines():
        line = raw.strip().strip("'\"")
        if not line or line.startswith(("#", ";", "!", "payload:")):
            continue
        line = re.sub(r"^-\s*", "", line).strip().strip("'\"")
        if not line:
            continue
        if "," in line:
            parts = [part.strip().strip("'\"") for part in line.split(",")]
            kind = parts[0].upper().replace("_", "-")
            if kind in ("DOMAIN", "HOST", "DOMAIN-SUFFIX", "HOST-SUFFIX", "DOMAIN-KEYWORD", "HOST-KEYWORD") and len(parts) >= 2:
                normalized = {"HOST": "DOMAIN", "HOST-SUFFIX": "DOMAIN-SUFFIX", "HOST-KEYWORD": "DOMAIN-KEYWORD"}.get(kind, kind)
                payload.append("%s,%s" % (normalized, parts[1]))
            elif kind in ("IP-CIDR", "IP-CIDR6") and len(parts) >= 2:
                try:
                    ipaddress.ip_network(parts[1], strict=False)
                    payload.append("%s,%s" % (kind, parts[1]))
                except ValueError:
                    pass
        else:
            domain = re.sub(r"^[*+]?\.", "", line).rstrip(".")
            if DOMAIN_RE.match(domain):
                payload.append("DOMAIN-SUFFIX,%s" % domain)
    return list(dict.fromkeys(payload))


def main():
    if len(sys.argv) != 2:
        die("usage: mihomo-router-config.py <rules-file>")
    rules_path = sys.argv[1]
    if not os.path.exists(rules_path):
        die("rules file not found: " + rules_path)
    try:
        mtu = int(os.environ.get("MIHOMO_MTU", "1400"))
    except ValueError:
        die("MIHOMO_MTU must be an integer")

    proxies, proxy_names = [], set()
    providers, rules = {}, []
    policy_map = load_policy_map()
    final = "DIRECT"

    def target(policy):
        raw = policy.strip()
        low = raw.lower()
        if low in ("direct", "direct-out", "dir"):
            return "DIRECT"
        if low in ("block", "reject", "reject-drop"):
            return "REJECT"
        resolved = policy_map.get(raw, raw)
        if resolved.lower() in ("direct", "dir"):
            return "DIRECT"
        if resolved.lower() in ("block", "reject"):
            return "REJECT"
        if not (os.path.exists(os.path.join(EXITS_DIR, resolved + ".yaml")) or
                os.path.exists(os.path.join(WG_DIR, "pgw-%s.conf" % resolved))):
            die("policy '%s' references unknown exit or category '%s'" % (raw, resolved))
        if resolved not in proxy_names:
            proxies.append(build_exit_proxy(resolved))
            proxy_names.add(resolved)
        return resolved

    def provider_tag(source, prefix="rs"):
        return "%s_%s" % (prefix, hashlib.sha256(source.encode()).hexdigest()[:12])

    def add_mrs(tag, url, behavior):
        providers.setdefault(tag, {"type": "http", "behavior": behavior, "format": "mrs",
                                   "url": url, "path": "./providers/%s.mrs" % tag,
                                   "interval": INTERVAL, "proxy": "DIRECT"})

    def add_ruleset(source, policy):
        source, behavior_hint = urldefrag(source)
        behavior_hint = behavior_hint.lower()
        if behavior_hint not in ("", "domain", "ipcidr", "classical"):
            die("rule-set URL fragment must be #domain, #ipcidr, or #classical")
        if source.lower().endswith(".srs"):
            die("sing-box .srs rule-sets are unsupported; use mihomo .mrs, text, or YAML")
        tag = provider_tag(source)
        if source.startswith(("http://", "https://")):
            suffix = source.lower().split("?", 1)[0]
            if suffix.endswith(".mrs"):
                behavior = behavior_hint or ("ipcidr" if any(word in suffix for word in ("geoip", "ipcidr", "ip-set")) else "domain")
                if behavior == "classical":
                    die("mihomo .mrs providers support domain or ipcidr behavior, not classical")
                add_mrs(tag, source, behavior)
            else:
                fmt = "text" if suffix.endswith((".txt", ".list")) else "yaml"
                behavior = behavior_hint or ("domain" if any(word in suffix for word in ("domain-set", "domain_set", "geosite"))
                                             else "ipcidr" if any(word in suffix for word in ("ipcidr", "ip-set", "geoip"))
                                             else "classical")
                providers[tag] = {"type": "http", "behavior": behavior, "format": fmt,
                                  "url": source, "path": "./providers/%s.%s" % (tag, "txt" if fmt == "text" else "yaml"),
                                  "interval": INTERVAL, "proxy": "DIRECT"}
        else:
            if not os.path.isabs(source):
                die("local rule-set path must be absolute: %s" % source)
            if not os.path.exists(source):
                die("local rule-set not found: %s" % source)
            os.makedirs(CACHE_DIR, exist_ok=True)
            if source.lower().endswith(".mrs"):
                cached = os.path.join(CACHE_DIR, tag + ".mrs")
                shutil.copyfile(source, cached)
                behavior = behavior_hint or ("ipcidr" if any(word in source.lower() for word in ("geoip", "ipcidr", "ip-set")) else "domain")
                if behavior == "classical":
                    die("mihomo .mrs providers support domain or ipcidr behavior, not classical")
                providers[tag] = {"type": "file", "behavior": behavior, "format": "mrs", "path": cached}
            else:
                with open(source, encoding="utf-8") as handle:
                    payload = parse_classical_rules(handle.read())
                if not payload:
                    die("local rule-set produced no supported rules: %s" % source)
                cached = os.path.join(CACHE_DIR, tag + ".json")
                with open(cached, "w", encoding="utf-8") as handle:
                    json.dump({"payload": payload}, handle, ensure_ascii=False, indent=2)
                providers[tag] = {"type": "file", "behavior": "classical", "format": "yaml", "path": cached}
        rules.append("RULE-SET,%s,%s" % (tag, policy))

    with open(rules_path, encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith(("#", ";")):
                continue
            parts = [part.strip() for part in line.split(",")]
            kind = parts[0].upper().replace("_", "-")
            if kind == "FINAL":
                if len(parts) < 2:
                    die("line %d: FINAL needs a policy" % line_number)
                final = target(parts[1])
                continue
            if len(parts) < 3:
                die("line %d: rule needs <type>,<value>,<policy>" % line_number)
            value, policy = parts[1], target(parts[2])
            if kind in ("DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6"):
                rules.append("%s,%s,%s" % (kind, value, policy))
            elif kind == "GEOSITE":
                tag = "geosite_" + re.sub(r"[^a-z0-9_-]", "", value.lower())
                add_mrs(tag, GEOSITE_MRS % value.lower(), "domain")
                rules.append("RULE-SET,%s,%s" % (tag, policy))
            elif kind == "GEOIP":
                tag = "geoip_" + re.sub(r"[^a-z0-9_-]", "", value.lower())
                add_mrs(tag, GEOIP_MRS % value.lower(), "ipcidr")
                rules.append("RULE-SET,%s,%s" % (tag, policy))
            elif kind in ("RULE-SET", "RULESET"):
                add_ruleset(value, policy)
            else:
                die("line %d: unsupported rule type '%s'" % (line_number, parts[0]))
    rules.append("MATCH,%s" % final)
    config = {"mode": "rule", "log-level": "warning", "ipv6": False, "find-process-mode": "off",
              "tun": {"enable": True, "stack": os.environ.get("MIHOMO_STACK", "gvisor"),
                      "device": "pgw-smart", "auto-route": False, "auto-redirect": False,
                      "strict-route": False, "mtu": mtu},
              "sniffer": {"enable": True, "force-dns-mapping": True, "parse-pure-ip": True,
                          "override-destination": True,
                          "sniff": {"TLS": {"ports": [443, 8443]}, "HTTP": {"ports": [80, "8080-8880"]}}},
              "proxies": proxies, "rule-providers": providers, "rules": rules}
    sys.stdout.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
