#!/bin/bash
set -euo pipefail

BASE_DIR="/etc/dnsdist"
GFWLIST_URL="https://github.com/gfwlist/gfwlist/raw/master/gfwlist.txt"
CHINALIST_URL="https://github.com/felixonmars/dnsmasq-china-list/raw/master/accelerated-domains.china.conf"
GFWLIST_FILE="${BASE_DIR}/gfwlist.raw"
CHINALIST_FILE="${BASE_DIR}/chinalist.raw"
GFWLIST_LUA="${BASE_DIR}/gfwlist.lua"
CHINALIST_LUA="${BASE_DIR}/chinalist.lua"
CHINALIST_CHUNK_DIR="${BASE_DIR}/chinalist.d"
CHINALIST_CHUNK_SIZE=20000
GFWLIST_EXTRA_FILE="${BASE_DIR}/gfwlist-extra-local.txt"
DEFAULT_RULES_FILE="/etc/proxy-gateway/rules-default.conf"
DNSDIST_TEMPLATE="${BASE_DIR}/dnsdist.conf.template"
DNSDIST_CONF="/etc/dnsdist/dnsdist.conf"
DEFAULT_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_PUBLIC_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8")

render_overseas_dns_servers() {
    local input="${1:-}"
    local pool="${2:-overseas}"
    local prefix="${3:-overseas}"
    local dns_list=()
    local item order=1 name

    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_OVERSEAS_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi

    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            echo "[!] Skipping invalid overseas DNS address: $item" >&2
            continue
        fi
        name="${prefix}${order}"
        printf 'newServer({address="%s:53", pool="%s", name="%s", order=%d, useClientSubnet=true})\n' "$item" "$pool" "$name" "$order"
        order=$((order + 1))
    done
}

append_local_gfwlist_extras() {
    [[ -f "${GFWLIST_EXTRA_FILE}" ]] || return 0

    echo "[*] Loading local GFWList extras..."
    touch "${GFWLIST_LUA}"
    local gfw_domain_index="${BASE_DIR}/gfwlist.domains"
    local domain extra_count=0

    sed -n 's/^gfwList:add(newDNSName("\(.*\)"))$/\1/p' "${GFWLIST_LUA}" | sort -u > "${gfw_domain_index}"

    while IFS= read -r domain || [[ -n "${domain}" ]]; do
        domain="${domain%%#*}"
        domain="${domain#"${domain%%[![:space:]]*}"}"
        domain="${domain%"${domain##*[![:space:]]}"}"
        domain="${domain%.}"
        domain="${domain#www.}"
        [[ -z "${domain}" ]] && continue
        [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]] || {
            echo "[!] Skipping invalid local GFWList extra domain: ${domain}" >&2
            continue
        }
        if grep -Fxq "${domain}" "${gfw_domain_index}"; then
            continue
        fi
        echo "gfwList:add(newDNSName(\"${domain}\"))" >> "${GFWLIST_LUA}"
        echo "${domain}" >> "${gfw_domain_index}"
        extra_count=$((extra_count + 1))
    done < "${GFWLIST_EXTRA_FILE}"

    rm -f "${gfw_domain_index}"
    echo "[+] Local GFWList extras: ${extra_count} domains"
}

# Domains targeted by the bundled default smart rules (e.g. speedtest) must also
# be hijacked into the proxy, otherwise the "which exit" rule never sees them.
# Derives domains from rules-default.conf (plain DOMAIN* lines + RULE-SET URLs),
# skipping direct/block categories, and adds them to the GFWList.
append_default_rule_domains() {
    [[ -f "${DEFAULT_RULES_FILE}" ]] || return 0

    echo "[*] Hijacking domains from default smart rules (so they enter the proxy)..."
    touch "${GFWLIST_LUA}"
    local gfw_domain_index="${BASE_DIR}/gfwlist.domains"
    sed -n 's/^gfwList:add(newDNSName("\(.*\)"))$/\1/p' "${GFWLIST_LUA}" | sort -u > "${gfw_domain_index}"

    local domains
    domains="$(python3 - "${DEFAULT_RULES_FILE}" <<'PY'
import sys, re, urllib.request
DOM = re.compile(r'^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$')
def clean(s):
    s = s.strip().strip("'\"")
    for p in ("+.", "*."):
        if s.startswith(p):
            s = s[2:]
    s = s.lstrip(".").rstrip(".")
    if s.startswith("www."):
        s = s[4:]
    return s
def from_list(text):
    out = []
    for raw in text.splitlines():
        l = raw.split("#", 1)[0].strip()
        if not l or l.lower().startswith("payload") or l[:1] in "!;":
            continue
        l = l.lstrip("- ").strip().strip("'\"")
        if "," in l:
            parts = [p.strip().strip("'\"") for p in l.split(",")]
            if parts[0].upper() in ("DOMAIN", "HOST", "DOMAIN-SUFFIX", "HOST-SUFFIX") and len(parts) > 1:
                d = clean(parts[1])
                if DOM.match(d):
                    out.append(d)
        else:
            d = clean(l)
            if DOM.match(d):
                out.append(d)
    return out
res = set()
for raw in open(sys.argv[1]):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 2:
        continue
    typ, cat = parts[0].upper(), parts[-1].lower()
    if cat in ("direct", "dir", "block", "reject"):
        continue
    if typ in ("DOMAIN", "HOST", "DOMAIN-SUFFIX", "HOST-SUFFIX"):
        d = clean(parts[1])
        if DOM.match(d):
            res.add(d)
    elif typ == "RULE-SET" and parts[1].startswith("http"):
        try:
            with urllib.request.urlopen(parts[1], timeout=15) as r:
                res.update(from_list(r.read().decode("utf-8", "ignore")))
        except Exception as e:
            sys.stderr.write("[!] default rule-set fetch failed (%s): %s\n" % (parts[1], e))
for d in sorted(res):
    print(d)
PY
)"

    local added=0 domain
    while IFS= read -r domain; do
        [[ -z "${domain}" ]] && continue
        if grep -Fxq "${domain}" "${gfw_domain_index}"; then
            continue
        fi
        echo "gfwList:add(newDNSName(\"${domain}\"))" >> "${GFWLIST_LUA}"
        echo "${domain}" >> "${gfw_domain_index}"
        added=$((added + 1))
    done <<< "${domains}"

    rm -f "${gfw_domain_index}"
    echo "[+] Default-rule hijack domains: ${added}"
}

install_chinalist_chunks() {
    local tmp_chunk_dir="$1"
    local tmp_loader="$2"
    local old_chunk_dir="${CHINALIST_CHUNK_DIR}.old"

    rm -rf "${old_chunk_dir}"
    if [[ -d "${CHINALIST_CHUNK_DIR}" ]]; then
        mv "${CHINALIST_CHUNK_DIR}" "${old_chunk_dir}"
    fi
    mv "${tmp_chunk_dir}" "${CHINALIST_CHUNK_DIR}"
    mv "${tmp_loader}" "${CHINALIST_LUA}"
    rm -rf "${old_chunk_dir}"
}

write_chinalist_chunks() {
    local tmp_chunk_dir="$1"
    local tmp_loader="$2"
    local count=0 chunk_index=0 entries_in_chunk=0 chunk_file=""
    local chunk_paths=()
    local domain basename final_path

    mkdir -p "${tmp_chunk_dir}"

    start_chinalist_chunk() {
        printf -v basename 'chinalist-%03d.lua' "${chunk_index}"
        chunk_file="${tmp_chunk_dir}/${basename}"
        final_path="${CHINALIST_CHUNK_DIR}/${basename}"
        printf 'local chinaList = ...\n' > "${chunk_file}"
        chunk_paths+=("${final_path}")
        chunk_index=$((chunk_index + 1))
        entries_in_chunk=0
    }

    while IFS= read -r domain; do
        [[ -z "${domain}" ]] && continue
        if [[ ${entries_in_chunk} -eq 0 ]]; then
            start_chinalist_chunk
        fi
        echo "chinaList:add(newDNSName(\"${domain}\"))" >> "${chunk_file}"
        count=$((count + 1))
        entries_in_chunk=$((entries_in_chunk + 1))
        if [[ ${entries_in_chunk} -ge ${CHINALIST_CHUNK_SIZE} ]]; then
            entries_in_chunk=0
        fi
    done < <(grep -oP 'server=/\K[^/]+' "${CHINALIST_FILE}")

    if [[ ${#chunk_paths[@]} -eq 0 ]]; then
        echo "-- (no chinalist rules loaded)" > "${tmp_loader}"
    else
        {
            echo "local chinalistChunks = {"
            for final_path in "${chunk_paths[@]}"; do
                printf '    "%s",\n' "${final_path}"
            done
            echo "}"
            echo "for _, chunk in ipairs(chinalistChunks) do"
            echo "    assert(loadfile(chunk))(chinaList)"
            echo "end"
        } > "${tmp_loader}"
    fi

    chmod -R u=rwX,go=rX "${tmp_chunk_dir}"
    chmod 0644 "${tmp_loader}"
    echo "${count}"
}

echo "[$(date)] Starting rule update..."
mkdir -p "${BASE_DIR}"

echo "[*] Downloading GFWList..."
if ! wget -qO "${GFWLIST_FILE}" "${GFWLIST_URL}" 2>/dev/null; then
    echo "[!] Failed to download GFWList"
    touch "${GFWLIST_LUA}" 2>/dev/null || true
else
    echo "[*] Parsing GFWList..."
    decoded="${BASE_DIR}/gfwlist.decoded"
    true >"${decoded}"
    base64 -d "${GFWLIST_FILE}" > "${decoded}" 2>/dev/null || \
        base64 -d -i "${GFWLIST_FILE}" > "${decoded}" 2>/dev/null || \
        openssl enc -base64 -d -in "${GFWLIST_FILE}" > "${decoded}" 2>/dev/null || true

    true >"${GFWLIST_LUA}"
    count=0
    max=20000
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*[![\]].* ]] && continue
        [[ -z "${line}" ]] && continue
        domain=""
        if [[ "${line}" =~ ^\|\|(.+)\^*$ ]]; then
            domain="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^\|https?://([^/]+) ]]; then
            domain="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^\*\.(.+) ]]; then
            domain="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-\.]+) ]]; then
            domain="${line}"
        fi
        domain="${domain%/}"
        domain="${domain#www.}"
        if [[ -n "${domain}" && "${domain}" =~ \. && ! "${domain}" =~ [\*\/\?\&\=] ]]; then
            echo "gfwList:add(newDNSName(\"${domain}\"))" >> "${GFWLIST_LUA}"
            count=$((count + 1))
            [[ ${count} -ge ${max} ]] && break
        fi
    done < "${decoded}"
    rm -f "${decoded}"
    echo "[+] GFWList: ${count} domains"
fi
append_local_gfwlist_extras
append_default_rule_domains

echo "[*] Downloading ChinaList..."
if ! wget -qO "${CHINALIST_FILE}" "${CHINALIST_URL}" 2>/dev/null; then
    echo "[!] Failed to download ChinaList"
    touch "${CHINALIST_LUA}" 2>/dev/null || true
else
    echo "[*] Parsing ChinaList..."
    tmp_chunk_dir=$(mktemp -d "${BASE_DIR}/chinalist.d.tmp.XXXXXX")
    tmp_loader=$(mktemp "${BASE_DIR}/chinalist.lua.tmp.XXXXXX")
    count=$(write_chinalist_chunks "${tmp_chunk_dir}" "${tmp_loader}")
    install_chinalist_chunks "${tmp_chunk_dir}" "${tmp_loader}"
    echo "[+] ChinaList: ${count} domains"
fi

if [[ ! -f "${DNSDIST_TEMPLATE}" ]]; then
    echo "[!] Template not found"
    exit 1
fi

echo "[*] Generating dnsdist configuration..."

SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "127.0.0.1")
DOMAIN=$(cat "${BASE_DIR}/.domain" 2>/dev/null || echo "example.com")

CERT_BASENAME="${DOMAIN}"
if [[ -f "/opt/proxy-gateway/etc/.cert_basename" ]]; then
    CERT_BASENAME=$(cat "/opt/proxy-gateway/etc/.cert_basename")
fi
PRIVATE_OVERSEAS_DNS=$(cat "${BASE_DIR}/.overseas_private_dns" 2>/dev/null || cat "${BASE_DIR}/.overseas_dns" 2>/dev/null || echo "${DEFAULT_OVERSEAS_DNS[*]}")
PUBLIC_OVERSEAS_DNS=$(cat "${BASE_DIR}/.overseas_public_dns" 2>/dev/null || echo "${DEFAULT_PUBLIC_OVERSEAS_DNS[*]}")
OVERSEAS_PRIVATE_DNS_SERVERS=$(render_overseas_dns_servers "$PRIVATE_OVERSEAS_DNS" "overseas_private" "overseas_private")
OVERSEAS_PUBLIC_DNS_SERVERS=$(render_overseas_dns_servers "$PUBLIC_OVERSEAS_DNS" "overseas_public" "overseas_public")
PACKET_CACHE_SIZE=$(cat "${BASE_DIR}/.cache_size" 2>/dev/null || echo "500000")
[[ "${PACKET_CACHE_SIZE}" =~ ^[0-9]+$ ]] || PACKET_CACHE_SIZE=500000

python3 - "${DNSDIST_TEMPLATE}" "${GFWLIST_LUA}" "${CHINALIST_LUA}" "${SERVER_IP}" "${CERT_BASENAME}" "${OVERSEAS_PRIVATE_DNS_SERVERS}" "${OVERSEAS_PUBLIC_DNS_SERVERS}" "${PACKET_CACHE_SIZE}" "${DNSDIST_CONF}" <<'PYEOF'
import sys
template_path = sys.argv[1]
gfw_path = sys.argv[2]
china_path = sys.argv[3]
server_ip = sys.argv[4]
domain = sys.argv[5]
overseas_private_servers = sys.argv[6]
overseas_public_servers = sys.argv[7]
packet_cache_size = sys.argv[8]
output_path = sys.argv[9]
with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()
with open(gfw_path, "r", encoding="utf-8") as f:
    gfw_rules = f.read().strip()
if not gfw_rules:
    gfw_rules = "-- (no gfwlist rules loaded)"
with open(china_path, "r", encoding="utf-8") as f:
    china_rules = f.read().strip()
if not china_rules:
    china_rules = "-- (no chinalist rules loaded)"
content = content.replace("__GFWLIST_RULES__", gfw_rules)
content = content.replace("__CHINALIST_RULES__", china_rules)
content = content.replace("__SERVER_IP__", server_ip)
content = content.replace("__DOMAIN__", domain)
content = content.replace("__OVERSEAS_PRIVATE_DNS_SERVERS__", overseas_private_servers)
content = content.replace("__OVERSEAS_PUBLIC_DNS_SERVERS__", overseas_public_servers)
content = content.replace("__PACKET_CACHE_SIZE__", packet_cache_size)
with open(output_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

echo "[OK]   dnsdist configuration generated"

if command -v dnsdist >/dev/null 2>&1; then
    echo "[*] Validating dnsdist configuration..."
    if ! dnsdist --check-config -C "${DNSDIST_CONF}"; then
        echo "[!] Generated dnsdist configuration failed validation; leaving running dnsdist unchanged." >&2
        exit 1
    fi
    echo "[OK]   dnsdist configuration validated"
else
    echo "[!]    dnsdist binary not found; skipping config validation"
fi

ensure_dnsdist_active() {
    sleep 1
    if ! systemctl is-active --quiet dnsdist; then
        echo "[!]    dnsdist is not active after reload, restarting..."
        systemctl restart dnsdist
    fi
}

# dnsdist has no signal-based config reload (SIGHUP makes it EXIT), so apply the
# new rules by restarting it.
echo "[*] Restarting dnsdist to apply rules..."
if systemctl is-active --quiet dnsdist; then
    systemctl restart dnsdist && echo "[OK]   dnsdist restarted"
    ensure_dnsdist_active
else
    systemctl start dnsdist
fi

echo "[$(date)] Rule update completed."
