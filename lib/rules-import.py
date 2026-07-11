#!/usr/bin/env python3
"""
Convert a rule list into the gateway's smart-routing rules.

The output keeps the original *policy group* as the rule's "category"
(e.g. AI, Netflix, dir). A separate policy-map (category -> exit/direct/block,
edited on the bot) resolves categories to real egress targets at config-gen
time. Server-meaningless matchers are dropped; OR/AND groups are flattened to
their domain/IP members.

Usage:  rules-import.py <rule-list-file>     (emits gateway rules on stdout)
Also prints, on stderr, a summary and the unique category list (CATEGORIES=...).
"""
import os
import re
import sys

# Matchers we can apply on the gateway (domain/IP/list based).
KEEP = {"DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6",
        "RULE-SET", "GEOIP", "GEOSITE"}
# Client-only matchers — meaningless on a server gateway.
DROP = {"PROCESS-NAME", "SRC-IP", "SRC-PORT", "DEST-PORT", "IN-PORT",
        "MAC-ADDRESS", "DEVICE-NAME", "IP-ASN", "USER-AGENT", "SUBNET",
        "PROTOCOL", "CELLULAR-RADIO", "SSID"}
MODIFIERS = re.compile(r"^(no-resolve|extended-matching|dns-failed|pre-matching"
                       r"|update-interval=.*|interval=.*)$", re.I)


def csv_split(s):
    """Split on commas, respecting double quotes."""
    out, cur, q = [], "", False
    for ch in s:
        if ch == '"':
            q = not q
        elif ch == "," and not q:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [x.strip() for x in out]


def norm_category(p):
    p = p.strip().strip('"').strip()
    p = re.sub(r"^[^\w一-鿿]+", "", p).strip()   # drop leading emoji/symbols
    return p or "Proxy"


# Optional simplification: keep only these categories distinct; collapse the
# rest into direct / block / Proxy. Set PGW_KEEP_CATEGORIES="AI" for "AI + 其它代理".
_KEEP = {c.strip() for c in re.split(r"[,\s]+", os.environ.get("PGW_KEEP_CATEGORIES", "")) if c.strip()}
# Categories forced to DIRECT (e.g. domestic services like 小红书/bilibili/iqiyi).
# Matched case-insensitively; takes priority over keep/Proxy collapse.
_DIRECT = {c.strip().lower() for c in re.split(r"[,\s]+", os.environ.get("PGW_DIRECT_CATEGORIES", "")) if c.strip()}


def category_of(policy):
    cat = norm_category(policy)
    if cat.lower() in _DIRECT:
        return "direct"
    if not _KEEP or cat in _KEEP:
        return cat
    low = cat.lower()
    if low in ("dir", "direct", "china", "lan", "domestic"):
        return "direct"
    if any(x in low for x in ("advert", "hijack", "privacy", "reject", "广告", "malware")):
        return "block"
    return "Proxy"


def split_top_parens(s):
    """Top-level (...) members inside an OR/AND group body."""
    out, depth, start = [], 0, None
    for i, ch in enumerate(s):
        if ch == "(":
            if depth == 0:
                start = i + 1
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(s[start:i])
                start = None
    return out


def parse_logical(line):
    """OR,((a),(b)),POLICY  ->  (members, policy)."""
    i = line.index("(")
    depth, end = 0, None
    for j in range(i, len(line)):
        if line[j] == "(":
            depth += 1
        elif line[j] == ")":
            depth -= 1
            if depth == 0:
                end = j
                break
    if end is None:
        return [], None
    group = line[i + 1:end]               # strip the outer ( )
    tail = line[end + 1:].lstrip(",")
    policy = csv_split(tail)[0] if tail else None
    return split_top_parens(group), policy


def emit(typ, value, category, sink):
    typ = typ.upper()
    if typ == "IP-CIDR6":
        typ = "IP-CIDR"
    sink.append("%s,%s,%s" % (typ, value, category_of(category)))


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: rules-import.py <rule-list-file>\n")
        sys.exit(1)

    rules, cats = [], {}
    final = None
    dropped, flattened = 0, 0

    for raw in open(sys.argv[1], encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith(("#", ";", "[")):
            continue
        typ = line.split(",", 1)[0].strip().upper()

        if typ in ("OR", "AND"):
            members, policy = parse_logical(line)
            if not policy:
                continue
            took = False
            for m in members:
                p = csv_split(m)
                mt = p[0].upper()
                if mt in KEEP and len(p) >= 2:
                    emit(mt, p[1], policy, rules)
                    cats[category_of(policy)] = True
                    took = True
            flattened += 1 if took else 0
            dropped += 0 if took else 1
            continue

        parts = csv_split(line)
        if typ == "FINAL":
            final = category_of(parts[1]) if len(parts) > 1 else None
            continue
        if typ in DROP:
            dropped += 1
            continue
        if typ not in KEEP or len(parts) < 3:
            dropped += 1
            continue
        # value = parts[1]; policy = first non-modifier field after it
        rest = [x for x in parts[2:] if not MODIFIERS.match(x.strip().strip('"'))]
        if not rest:
            dropped += 1
            continue
        emit(typ, parts[1], rest[0], rules)   # emit applies category_of once
        cats[category_of(rest[0])] = True

    if final:
        rules.append("FINAL,%s" % final)
        cats[final] = True

    sys.stdout.write("\n".join(rules) + "\n")
    sys.stderr.write("converted=%d dropped=%d or_flattened=%d categories=%d\n"
                     % (len(rules), dropped, flattened, len(cats)))
    sys.stderr.write("CATEGORIES=" + "\t".join(sorted(cats)) + "\n")


if __name__ == "__main__":
    main()
