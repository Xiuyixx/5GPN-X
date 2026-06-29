#!/usr/bin/env python3
"""
Convert a rule-list file into a sing-box "router" exit config.

This powers the `smart` exit: among proxied traffic, route each domain to a
different egress (another configured exit), DIRECT, or REJECT — driven by rules
that can match domains, keywords, IP-CIDRs, geosite/geoip, and external rule
sets (local files or remote URLs).

Rules file syntax (one rule per line, first match wins; '#'/';' = comment):
    DOMAIN,api.example.com,us
    DOMAIN-SUFFIX,google.com,us
    DOMAIN-KEYWORD,netflix,jp
    IP-CIDR,1.2.3.0/24,direct
    GEOSITE,telegram,us
    GEOIP,cn,direct
    RULE-SET,https://example.com/list.txt,us     # remote plain-text domain list
    RULE-SET,https://example.com/rules.srs,jp     # remote sing-box .srs
    RULE-SET,/etc/proxy-gateway/rules/my.list,jp  # local file (text or .srs)
    FINAL,direct                                  # default policy

Policy = an exit name (socks/ss/wireguard exit), `direct`, or `block`/`reject`.

Usage:  singbox-router-config.py <rules-file>   (emits sing-box JSON on stdout)
Env: EXITS_DIR, WG_DIR, PGW_RULESET_CACHE, SINGBOX_STACK, SINGBOX_MTU
"""
import hashlib
import json
import os
import re
import sys
import urllib.request

EXITS_DIR = os.environ.get("EXITS_DIR", "/etc/proxy-gateway/exits")
WG_DIR = os.environ.get("WG_DIR", "/etc/wireguard")
CACHE_DIR = os.environ.get("PGW_RULESET_CACHE", "/etc/proxy-gateway/rulesets")
STACK = os.environ.get("SINGBOX_STACK", "gvisor")
SINGBOX_BIN = os.environ.get("SINGBOX_BIN", "/opt/proxy-gateway/bin/sing-box")
POLICY_MAP_FILE = os.environ.get("PGW_POLICY_MAP", "/etc/proxy-gateway/policy-map.conf")
DEFAULT_TARGET = os.environ.get("PGW_DEFAULT_TARGET", "direct")
try:
    MTU = int(os.environ.get("SINGBOX_MTU", "1400"))
except ValueError:
    MTU = 1400


def load_policy_map():
    """category -> target (exit name / direct / block)."""
    m = {}
    try:
        for raw in open(POLICY_MAP_FILE, encoding="utf-8"):
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            m[k.strip()] = v.strip()
    except OSError:
        pass
    return m

GEOSITE_SRS = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-%s.srs"
GEOIP_SRS = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-%s.srs"
DOMAIN_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$")


def die(msg):
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(1)


# --------------------------------------------------------------------------- #
# Outbounds (one per referenced exit, plus direct/block)
# --------------------------------------------------------------------------- #
def wg_to_outbound(name, path):
    iface, peer, section = {}, {}, None
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            section = line.strip("[]").lower()
            continue
        if "=" not in line:
            continue
        k, v = (x.strip() for x in line.split("=", 1))
        (iface if section == "interface" else peer)[k.lower()] = v
    host, _, port = peer.get("endpoint", "").rpartition(":")
    ob = {
        "type": "wireguard", "tag": name,
        "server": host, "server_port": int(port) if port.isdigit() else 51820,
        "local_address": [a.strip() for a in iface.get("address", "").split(",") if a.strip()],
        "private_key": iface.get("privatekey", ""),
        "peer_public_key": peer.get("publickey", ""),
    }
    if peer.get("presharedkey"):
        ob["pre_shared_key"] = peer["presharedkey"]
    if iface.get("mtu", "").isdigit():
        ob["mtu"] = int(iface["mtu"])
    return ob


def build_exit_outbound(name):
    jp = os.path.join(EXITS_DIR, name + ".json")
    if os.path.exists(jp):
        try:
            cfg = json.load(open(jp))
            ob = dict(cfg["outbounds"][0])
            if ob.get("tag") == "out" and len(cfg.get("outbounds", [])) > 1:
                by_tag = {o.get("tag"): o for o in cfg.get("outbounds", [])}
                for rule in cfg.get("route", {}).get("rules", []):
                    tag = rule.get("outbound")
                    if tag and tag not in ("out", "direct", "block") and tag in by_tag:
                        ob = dict(by_tag[tag])
                        break
        except Exception as e:
            die("cannot read exit '%s' config: %s" % (name, e))
        ob["tag"] = name
        return ob
    wg = os.path.join(WG_DIR, "pgw-%s.conf" % name)
    if os.path.exists(wg):
        return wg_to_outbound(name, wg)
    die("rule references unknown exit: '%s' (add it first)" % name)


# --------------------------------------------------------------------------- #
# Rule sets
# --------------------------------------------------------------------------- #
def parse_rule_list(text):
    """Parse a plain / domain/IP list into a sing-box source rule dict
    (domain / domain_suffix / domain_keyword / ip_cidr)."""
    dom, suf, kw, ip = set(), set(), set(), set()
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith(("!", ";")) or line.lower().startswith("payload"):
            continue
        line = line.lstrip("- ").strip().strip("'\"")   # YAML list / quoted entries
        if "," in line:
            parts = [p.strip().strip("'\"") for p in line.split(",")]
            t, v = parts[0].upper(), (parts[1] if len(parts) > 1 else "")
            if t in ("DOMAIN", "HOST"):
                if DOMAIN_RE.match(v):
                    dom.add(v)
            elif t in ("DOMAIN-SUFFIX", "HOST-SUFFIX"):
                v = v.lstrip(".")
                if DOMAIN_RE.match(v):
                    suf.add(v)
            elif t in ("DOMAIN-KEYWORD", "HOST-KEYWORD"):
                if v:
                    kw.add(v)
            elif t in ("IP-CIDR", "IP-CIDR6"):
                if v:
                    ip.add(v)
        else:
            v = re.sub(r"^[*+]?\.", "", line).rstrip(".")
            if DOMAIN_RE.match(v):
                suf.add(v)
    rule = {}
    if dom:
        rule["domain"] = sorted(dom)
    if suf:
        rule["domain_suffix"] = sorted(suf)
    if kw:
        rule["domain_keyword"] = sorted(kw)
    if ip:
        rule["ip_cidr"] = sorted(ip)
    return rule


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "proxy-gateway"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main():
    if len(sys.argv) != 2:
        die("usage: singbox-router-config.py <rules-file>")
    rules_path = sys.argv[1]
    if not os.path.exists(rules_path):
        die("rules file not found: " + rules_path)

    outbounds, ob_tags = [], set()
    rule_sets, rs_tags = [], set()
    route_rules = []
    final = "direct"
    policy_map = load_policy_map()

    def _materialize_target(t):
        """t is a concrete target: direct / block / <exit-name>. Return its tag."""
        low = t.strip().lower()
        if low in ("direct", "direct-out", "dir"):
            return "direct"
        if low in ("block", "reject", "reject-drop"):
            return "block"
        name = t.strip()
        if name not in ob_tags:
            outbounds.append(build_exit_outbound(name))
            ob_tags.add(name)
        return name

    def ensure_policy(policy, _depth=0):
        """Resolve a policy/category to an outbound tag (via the policy map)."""
        p = policy.strip()
        low = p.lower()
        if low in ("direct", "direct-out", "dir"):
            return "direct"
        if low in ("block", "reject", "reject-drop"):
            return "block"
        # a category mapped in the policy map -> its concrete target
        if p in policy_map and _depth < 4:
            return _materialize_target(policy_map[p])
        # an existing exit referenced directly
        if os.path.exists(os.path.join(EXITS_DIR, p + ".json")) or \
           os.path.exists(os.path.join(WG_DIR, "pgw-%s.conf" % p)):
            return _materialize_target(p)
        # unmapped category -> default target
        return _materialize_target(DEFAULT_TARGET)

    def add_remote_srs(tag, url):
        if tag in rs_tags:
            return
        rule_sets.append({"type": "remote", "tag": tag, "format": "binary",
                          "url": url, "download_detour": "direct"})
        rs_tags.add(tag)

    def add_local_source(tag, rule):
        """rule = a sing-box source rule dict; returns True if added."""
        if tag in rs_tags:
            return True
        if not rule:
            return False
        os.makedirs(CACHE_DIR, exist_ok=True)
        src_path = os.path.join(CACHE_DIR, tag + ".json")
        json.dump({"version": 1, "rules": [rule]}, open(src_path, "w"))
        # Compile to a binary .srs when sing-box is available: far lighter in
        # memory than a source rule-set (important on small hosts with many lists).
        srs_path = os.path.join(CACHE_DIR, tag + ".srs")
        compiled = False
        if os.path.exists(SINGBOX_BIN):
            try:
                import subprocess
                subprocess.run([SINGBOX_BIN, "rule-set", "compile", src_path, "-o", srs_path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=60, check=True)
                compiled = os.path.exists(srs_path)
            except Exception:
                compiled = False
        if compiled:
            os.remove(src_path)
            rule_sets.append({"type": "local", "tag": tag, "format": "binary", "path": srs_path})
        else:
            rule_sets.append({"type": "local", "tag": tag, "format": "source", "path": src_path})
        rs_tags.add(tag)
        return True

    def handle_ruleset(src, pol_tag):
        """Add a rule-set rule; skip (warn) on fetch/parse failure. Returns bool."""
        tag = "rs_" + hashlib.md5(src.encode()).hexdigest()[:8]
        cached_srs = os.path.join(CACHE_DIR, tag + ".srs")
        ok = False
        if src.startswith("http") and src.lower().endswith(".srs"):
            add_remote_srs(tag, src); ok = True
        elif tag not in rs_tags and os.path.exists(cached_srs):
            rule_sets.append({"type": "local", "tag": tag, "format": "binary", "path": cached_srs})
            rs_tags.add(tag); ok = True
        elif tag in rs_tags:
            ok = True
        elif src.startswith("http"):
            try:
                rule = parse_rule_list(fetch(src).decode("utf-8", "replace"))
                ok = add_local_source(tag, rule)
                if not ok:
                    sys.stderr.write("[skip] rule-set produced nothing: %s\n" % src)
            except Exception as e:
                sys.stderr.write("[skip] rule-set fetch failed (%s): %s\n" % (e, src))
                ok = False
        else:  # local file
            if not os.path.exists(src):
                sys.stderr.write("[skip] local rule-set not found: %s\n" % src); return False
            if src.lower().endswith(".srs"):
                rule_sets.append({"type": "local", "tag": tag, "format": "binary", "path": src})
                rs_tags.add(tag); ok = True
            else:
                ok = add_local_source(tag, parse_rule_list(open(src, encoding="utf-8").read()))
        if ok:
            route_rules.append({"rule_set": [tag], "outbound": pol_tag})
        return ok

    for ln, raw in enumerate(open(rules_path, encoding="utf-8"), 1):
        line = raw.split("#", 1)[0].split(";", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(",")]
        typ = parts[0].upper().replace("_", "-")
        if typ == "FINAL":
            if len(parts) < 2:
                die("line %d: FINAL needs a policy" % ln)
            final = ensure_policy(parts[1])
            continue
        if len(parts) < 3:
            die("line %d: '%s' needs <type>,<value>,<policy>" % (ln, line))
        value, pol = parts[1], ensure_policy(parts[2])
        if typ == "DOMAIN":
            route_rules.append({"domain": [value], "outbound": pol})
        elif typ == "DOMAIN-SUFFIX":
            route_rules.append({"domain_suffix": [value], "outbound": pol})
        elif typ == "DOMAIN-KEYWORD":
            route_rules.append({"domain_keyword": [value], "outbound": pol})
        elif typ in ("IP-CIDR", "IP-CIDR6"):
            route_rules.append({"ip_cidr": [value], "outbound": pol})
        elif typ == "GEOSITE":
            tag = "geosite_" + re.sub(r"[^a-z0-9]", "", value.lower())
            add_remote_srs(tag, GEOSITE_SRS % value.lower())
            route_rules.append({"rule_set": [tag], "outbound": pol})
        elif typ == "GEOIP":
            tag = "geoip_" + re.sub(r"[^a-z0-9]", "", value.lower())
            add_remote_srs(tag, GEOIP_SRS % value.lower())
            route_rules.append({"rule_set": [tag], "outbound": pol})
        elif typ in ("RULE-SET", "RULESET"):
            handle_ruleset(value, pol)
        else:
            die("line %d: unsupported rule type '%s'" % (ln, parts[0]))

    # direct + block always available (FINAL/policies/rule-set downloads).
    outbounds.append({"type": "direct", "tag": "direct"})
    outbounds.append({"type": "block", "tag": "block"})

    route = {"rules": route_rules, "final": final, "auto_detect_interface": True}
    if rule_sets:
        route["rule_set"] = rule_sets

    config = {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [{
            "type": "tun", "tag": "pgw-in",
            "interface_name": "pgw-smart",
            "inet4_address": "172.19.0.1/30",
            "mtu": MTU, "auto_route": False, "strict_route": False,
            "stack": STACK,
            "sniff": True, "sniff_override_destination": True,
        }],
        "outbounds": outbounds,
        "route": route,
    }
    sys.stdout.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
