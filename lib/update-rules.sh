#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/mosdns"
GFWLIST_URL="https://github.com/gfwlist/gfwlist/raw/master/gfwlist.txt"
CHINALIST_URL="https://github.com/felixonmars/dnsmasq-china-list/raw/master/accelerated-domains.china.conf"
GFWLIST_RAW="${BASE_DIR}/gfwlist.raw"
CHINALIST_RAW="${BASE_DIR}/chinalist.raw"
GFWLIST_FILE="${BASE_DIR}/gfwlist.txt"
CHINALIST_FILE="${BASE_DIR}/chinalist.txt"
GFWLIST_EXTRA_FILE="${BASE_DIR}/gfwlist-extra-local.txt"
DEFAULT_RULES_FILE="/etc/5gpn/rules-default.conf"
MOSDNS_TEMPLATE="${BASE_DIR}/config.yaml.template"
MOSDNS_CONF="${BASE_DIR}/config.yaml"
DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_LOCAL_DNS=("101.226.4.6" "218.30.118.6" "180.76.76.76" "119.29.29.29")

normalize_domain() {
    local domain="${1:-}"
    domain="${domain%%#*}"
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"
    domain="${domain%.}"
    domain="${domain#www.}"
    printf '%s' "$domain"
}

valid_domain() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]
}

append_local_gfwlist_extras() {
    [[ -f "$GFWLIST_EXTRA_FILE" ]] || return 0
    local domain
    while IFS= read -r domain || [[ -n "$domain" ]]; do
        domain=$(normalize_domain "$domain")
        [[ -z "$domain" ]] && continue
        if valid_domain "$domain"; then
            printf '%s\n' "$domain"
        else
            echo "[!] Skipping invalid local GFWList extra domain: $domain" >&2
        fi
    done < "$GFWLIST_EXTRA_FILE" >> "$GFWLIST_FILE"
}

append_default_rule_domains() {
    [[ -f "$DEFAULT_RULES_FILE" ]] || return 0
    python3 - "$DEFAULT_RULES_FILE" >> "$GFWLIST_FILE" <<'PY'
import re
import sys
import urllib.request

domain_re = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$")

def clean(value):
    value = value.strip().strip("'\"")
    for prefix in ("+.", "*."):
        if value.startswith(prefix):
            value = value[2:]
    value = value.lstrip(".").rstrip(".")
    return value[4:] if value.startswith("www.") else value

def parse_rule_text(text):
    domains = set()
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.lower().startswith("payload") or line[:1] in "!;":
            continue
        line = line.lstrip("- ").strip().strip("'\"")
        parts = [part.strip().strip("'\"") for part in line.split(",")]
        if len(parts) > 1 and parts[0].upper() in ("DOMAIN", "HOST", "DOMAIN-SUFFIX", "HOST-SUFFIX"):
            domain = clean(parts[1])
        else:
            domain = clean(line)
        if domain_re.match(domain):
            domains.add(domain)
    return domains

result = set()
with open(sys.argv[1], encoding="utf-8") as rules:
    for raw in rules:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 2 or parts[-1].lower() in ("direct", "dir", "block", "reject"):
            continue
        rule_type = parts[0].upper()
        if rule_type in ("DOMAIN", "HOST", "DOMAIN-SUFFIX", "HOST-SUFFIX"):
            domain = clean(parts[1])
            if domain_re.match(domain):
                result.add(domain)
        elif rule_type == "RULE-SET" and parts[1].startswith("http"):
            try:
                with urllib.request.urlopen(parts[1], timeout=15) as response:
                    result.update(parse_rule_text(response.read().decode("utf-8", "ignore")))
            except Exception as exc:
                print(f"[!] default rule-set fetch failed ({parts[1]}): {exc}", file=sys.stderr)

for domain in sorted(result):
    print(domain)
PY
}

parse_gfwlist() {
    local decoded
    decoded=$(mktemp "${BASE_DIR}/gfwlist.decoded.XXXXXX")
    if ! base64 -d "$GFWLIST_RAW" > "$decoded" 2>/dev/null; then
        base64 -d -i "$GFWLIST_RAW" > "$decoded" 2>/dev/null || true
    fi
    python3 - "$decoded" > "$GFWLIST_FILE" <<'PY'
import re
import sys
from urllib.parse import urlsplit

domain_re = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$")
domains = set()
with open(sys.argv[1], encoding="utf-8", errors="ignore") as source:
    for raw in source:
        line = raw.strip()
        if not line or line[0] in "!@[":
            continue
        if line.startswith("||"):
            domain = line[2:].split("^", 1)[0].split("/", 1)[0]
        elif line.startswith("|http://") or line.startswith("|https://"):
            domain = urlsplit(line[1:]).hostname or ""
        elif line.startswith("*."):
            domain = line[2:].split("/", 1)[0]
        else:
            domain = line.split("/", 1)[0].split("^", 1)[0]
        domain = domain.lstrip(".").removeprefix("www.").rstrip(".")
        if domain_re.match(domain):
            domains.add(domain)
for domain in sorted(domains):
    print(domain)
PY
    rm -f "$decoded"
}

parse_chinalist() {
    sed -n 's#^[[:space:]]*server=/\([^/]*\)/.*#\1#p' "$CHINALIST_RAW" | sort -u > "$CHINALIST_FILE"
}

yaml_upstreams() {
    local input="${1:-}" fallback="${2:-}" mode="${3:-primary}"
    local protocol="${4:-udp}"
    python3 - "$input" "$fallback" "$mode" "$protocol" <<'PY'
import ipaddress
import sys

items = list(dict.fromkeys(sys.argv[1].replace(",", " ").split()))
fallbacks = sys.argv[2].split()
mode = sys.argv[3]
protocol = sys.argv[4] if len(sys.argv) > 4 else "udp"
if mode == "primary":
    selected = items[:1] if items else fallbacks[:1]
elif mode == "secondary":
    selected = items[1:] if len(items) > 1 else [next((item for item in fallbacks if item != items[0]), fallbacks[0])] if items else fallbacks[1:]
elif mode == "all":
    # Use all items (for China DNS 4-server race).
    selected = items if items else fallbacks
else:
    selected = items if items else fallbacks
if not selected:
    selected = fallbacks
for item in selected:
    # If it is already a scheme URL, emit as-is.
    if "://" in item:
        print(f"        - addr: {item}")
        continue
    if item.count(":") > 1:
        try:
            ipaddress.ip_address(item)
            item = f"{protocol}://[{item}]:53"
        except ValueError:
            pass
    elif ":" not in item:
        item = f"{protocol}://{item}:53"
    else:
        # Already has host:port, prepend protocol.
        item = f"{protocol}://{item}"
    print(f"        - addr: {item}")
PY
}

render_config() {
    local server_ip remote_dns local_dns cache_size
    local remote_primary remote_secondary local_primary local_secondary
    server_ip=$(cat "$BASE_DIR/.public_ip" 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n1)
    [[ -n "$server_ip" ]] || server_ip="127.0.0.1"
    remote_dns=$(cat "$BASE_DIR/.remote_dns" 2>/dev/null || printf '%s ' "${DEFAULT_REMOTE_DNS[@]}")
    local_dns=$(cat "$BASE_DIR/.local_dns" 2>/dev/null || printf '%s ' "${DEFAULT_LOCAL_DNS[@]}")
    cache_size=$(cat "$BASE_DIR/.cache_size" 2>/dev/null || echo 500000)
    [[ "$cache_size" =~ ^[0-9]+$ ]] || cache_size=500000
    remote_primary=$(yaml_upstreams "$remote_dns" "1.1.1.1 8.8.8.8 9.9.9.9" primary udp)
    remote_secondary=$(yaml_upstreams "$remote_dns" "9.9.9.9 1.0.0.1" secondary udp)
    local_primary=$(yaml_upstreams "$local_dns" "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29" all udp)
    local_secondary=$(yaml_upstreams "$local_dns" "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29" all tcp)

    python3 - "$MOSDNS_TEMPLATE" "$MOSDNS_CONF.tmp" "$server_ip" "$cache_size" \
        "$remote_primary" "$remote_secondary" "$local_primary" "$local_secondary" <<'PY'
import sys

template, output, server_ip, cache_size = sys.argv[1:5]
with open(template, encoding="utf-8") as source:
    content = source.read()
replacements = {
    "__SERVER_IP__": server_ip,
    "__CACHE_SIZE__": cache_size,
    "__REMOTE_PRIMARY_UPSTREAMS__": sys.argv[5],
    "__REMOTE_SECONDARY_UPSTREAMS__": sys.argv[6],
    "__LOCAL_PRIMARY_UPSTREAMS__": sys.argv[7],
    "__LOCAL_SECONDARY_UPSTREAMS__": sys.argv[8],
}
for marker, value in replacements.items():
    content = content.replace(marker, value)
with open(output, "w", encoding="utf-8") as target:
    target.write(content)
PY

    if command -v mosdns >/dev/null 2>&1; then
        local validate_conf validate_log rc=0
        validate_conf=$(mktemp "${BASE_DIR}/config.validate.XXXXXX.yaml")
        validate_log=$(mktemp "${BASE_DIR}/config.validate.XXXXXX.log")
        sed -e 's/"0.0.0.0:53"/"127.0.0.1:0"/g' \
            -e 's/"0.0.0.0:853"/"127.0.0.1:0"/g' "$MOSDNS_CONF.tmp" > "$validate_conf"
        timeout 2 mosdns start -c "$validate_conf" > "$validate_log" 2>&1 || rc=$?
        if [[ $rc -ne 0 && $rc -ne 124 ]]; then
            cat "$validate_log" >&2
            rm -f "$validate_conf" "$validate_log" "$MOSDNS_CONF.tmp"
            echo "[!] Generated mosdns configuration failed validation; running config unchanged." >&2
            return 1
        fi
        rm -f "$validate_conf" "$validate_log"
    fi
    chmod 0644 "$MOSDNS_CONF.tmp"
    mv -f "$MOSDNS_CONF.tmp" "$MOSDNS_CONF"
}

echo "[$(date)] Starting mosdns rule update..."
mkdir -p "$BASE_DIR"
touch "$GFWLIST_EXTRA_FILE"

if wget -qO "$GFWLIST_RAW.tmp" "$GFWLIST_URL" 2>/dev/null; then
    mv "$GFWLIST_RAW.tmp" "$GFWLIST_RAW"
    parse_gfwlist
else
    rm -f "$GFWLIST_RAW.tmp"
    echo "[!] Failed to download GFWList; keeping the previous domain set" >&2
    touch "$GFWLIST_FILE"
fi
append_local_gfwlist_extras
append_default_rule_domains
sort -u -o "$GFWLIST_FILE" "$GFWLIST_FILE"

if wget -qO "$CHINALIST_RAW.tmp" "$CHINALIST_URL" 2>/dev/null; then
    mv "$CHINALIST_RAW.tmp" "$CHINALIST_RAW"
    parse_chinalist
else
    rm -f "$CHINALIST_RAW.tmp"
    echo "[!] Failed to download ChinaList; keeping the previous domain set" >&2
    touch "$CHINALIST_FILE"
fi

render_config
echo "[OK] mosdns configuration generated and validated"
if systemctl is-active --quiet mosdns; then
    systemctl restart mosdns
else
    systemctl start mosdns
fi
systemctl is-active --quiet mosdns || { echo "[!] mosdns failed after rule update" >&2; exit 1; }
echo "[$(date)] Rule update completed."
