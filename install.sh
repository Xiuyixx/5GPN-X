#!/usr/bin/env bash
set -euo pipefail
REPO_URL="https://github.com/Xiuyixx/5GPN-X.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
LIB_DIR="${SCRIPT_DIR}/lib"
BASE_DIR="/opt/proxy-gateway"
CONF_DIR="${BASE_DIR}/etc"
SRC_DIR="${BASE_DIR}/src"
WWW_DIR="${BASE_DIR}/www"
IOS_PROFILE_PORT=8111
EXIT_USER="pxout"
EXIT_MARK="0x1"
EXIT_TABLE="100"
WG_DIR="/etc/wireguard"
EXITS_DIR="/etc/proxy-gateway/exits"
RULES_FILE="/etc/proxy-gateway/rules.conf"
POLICY_MAP="/etc/proxy-gateway/policy-map.conf"
KEEP_FILE="/etc/proxy-gateway/keep-categories"
DIRECT_FILE="/etc/proxy-gateway/direct-categories"
RULES_DEFAULT="/etc/proxy-gateway/rules-default.conf"
RULESET_CACHE="/etc/proxy-gateway/rulesets"
MIHOMO_BIN="/opt/proxy-gateway/bin/mihomo"
MIHOMO_CFG_GEN="/opt/proxy-gateway/bin/mihomo-exit-config.py"
MIHOMO_ROUTER_GEN="/opt/proxy-gateway/bin/mihomo-router-config.py"
RULES_IMPORT="/opt/proxy-gateway/bin/rules-import.py"
MIHOMO_VERSION_DEFAULT="1.19.28"
MOSDNS_VERSION_DEFAULT="5.3.4"
DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_LOCAL_DNS=("101.226.4.6" "218.30.118.6" "180.76.76.76" "119.29.29.29")
bootstrap_from_repo_if_needed() {
    local required=(
        install.sh
        lib/renew-hook.sh lib/sniproxy.conf lib/quic-proxy.go
        lib/mosdns.yaml.template lib/update-rules.sh lib/ios-http.py lib/tgbot.py
        lib/wa-shim.py lib/rules-import.py lib/mihomo-exit-config.py
        lib/mihomo-router-config.py lib/rules-default.conf lib/host-setup.sh
    )
    local missing=0 f tmpdir
    for f in "${required[@]}"; do
        [[ -f "${SCRIPT_DIR}/${f}" ]] || { missing=1; break; }
    done
    if [[ $missing -eq 0 ]]; then
        return 0
    fi
    if [[ -n "${G5PNX_BOOTSTRAPPED:-}" ]]; then
        return 0
    fi
    tmpdir="$(mktemp -d /tmp/5gpnx-src.XXXXXX)"
    if git clone --depth=1 --branch main "$REPO_URL" "$tmpdir" >/dev/null 2>&1; then
        export G5PNX_BOOTSTRAPPED=1
        exec bash "$tmpdir/install.sh" "$@"
    fi
    echo "[ERR]  无法自动获取完整源码树。请用 git clone 后再运行 install.sh。" >&2
    exit 1
}
bootstrap_from_repo_if_needed "$@"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
render_sniproxy_dns_nameservers() {
    local input="${1:-}"
    local dns_list=()
    local item
    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_REMOTE_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$item" == *://* ]]; then
            item=$(python3 - "$item" <<'PYEOF'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PYEOF
)
        elif [[ "$item" == \[*\]:* ]]; then
            item="${item#\[}"
            item="${item%%\]:*}"
        elif [[ "$item" =~ ^([0-9]+\.){3}[0-9]+:[0-9]+$ ]]; then
            item="${item%:*}"
        fi
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid sniproxy DNS address: $item"
            continue
        fi
        printf '    nameserver %s\n' "$item"
    done
}
first_plain_dns() {
    local rendered
    rendered=$(render_sniproxy_dns_nameservers "${1:-}")
    awk 'NR == 1 { print $2 }' <<< "$rendered"
}
normalize_dns_list() {
    local input="${1:-}"
    local dns_list=() out=() item
    input="${input//,/ }"
    read -r -a dns_list <<< "$input"
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            err "Invalid DNS address: $item"
            exit 1
        fi
        python3 - "$item" <<'PYEOF' || { err "Invalid DNS address: $item"; exit 1; }
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1])
PYEOF
        out+=("$item")
    done
    [[ ${#out[@]} -gt 0 ]] || { err "DNS list cannot be empty"; exit 1; }
    printf '%s' "${out[*]}"
}
normalize_dns_upstreams() {
    local input="${1:-}"
    local dns_list=() out=() item host port
    input="${input//,/ }"
    read -r -a dns_list <<< "$input"
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$item" == *://* ]]; then
            python3 - "$item" <<'PYEOF' || { err "Invalid DNS upstream URL: $item"; exit 1; }
import ipaddress
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
parsed = urlsplit(value)
if parsed.scheme not in {"https", "tls", "udp", "tcp"}:
    raise SystemExit(1)
if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit(1)
try:
    ipaddress.ip_address(parsed.hostname)
except ValueError:
    raise SystemExit(1)
if parsed.port is not None and not 1 <= parsed.port <= 65535:
    raise SystemExit(1)
if parsed.scheme == "https" and parsed.path != "/dns-query":
    raise SystemExit(1)
if parsed.scheme != "https" and parsed.path not in {"", "/"}:
    raise SystemExit(1)
PYEOF
            out+=("$item")
            continue
        fi
        if [[ "$item" == *:* ]]; then
            if python3 - "$item" <<'PYEOF' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PYEOF
            then
                host="$item"
                port="53"
            else
                host="${item%:*}"
                port="${item##*:}"
            fi
        else
            host="$item"
            port="53"
        fi
        [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || { err "Invalid DNS upstream port: $item"; exit 1; }
        python3 - "$host" <<'PYEOF' || { err "Invalid DNS upstream IP: $item"; exit 1; }
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1])
PYEOF
        if [[ "$port" == "53" ]]; then
            out+=("$host")
        else
            out+=("$host:$port")
        fi
    done
    [[ ${#out[@]} -gt 0 ]] || { err "DNS upstream list cannot be empty"; exit 1; }
    printf '%s' "${out[*]}"
}
rewrite_sniproxy_dns() {
    local sniproxy_dns="${1:-}" nameservers
    [[ -f /etc/sniproxy.conf ]] || return 0
    nameservers=$(render_sniproxy_dns_nameservers "$sniproxy_dns")
    python3 - /etc/sniproxy.conf "$nameservers" <<'PYEOF'
import sys

path, nameservers = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

start = None
end = None
for idx, line in enumerate(lines):
    if line.strip() == "resolver {":
        start = idx
        break
if start is not None:
    for idx in range(start + 1, len(lines)):
        if lines[idx].strip() == "}":
            end = idx
            break
if start is None or end is None:
    raise SystemExit("resolver block not found in /etc/sniproxy.conf")

replacement = ["resolver {"] + nameservers.splitlines() + ["    mode ipv4_only", "}"]
new_lines = lines[:start] + replacement + lines[end + 1:]
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(new_lines) + "\n")
PYEOF
}
restore_or_remove_file() {
    local old_value="${1-}" target="${2-}"
    [[ -n "$target" ]] || return 0
    if [[ -n "$old_value" ]]; then
        if ! printf '%s\n' "$old_value" > "$target"; then
            err "restore_or_remove_file: failed to restore $target"
            return 1
        fi
    else
        rm -f "$target"
    fi
}
resolve_domain_a_records() {
    local domain="${1:-}" resolver="" line=""
    local records=()
    local public_resolvers=(1.1.1.1 8.8.8.8 9.9.9.9 223.5.5.5 114.114.114.114)
    if command -v dig >/dev/null 2>&1; then
        for resolver in "${public_resolvers[@]}"; do
            while IFS= read -r line; do
                [[ "$line" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && records+=("$line")
            done < <(dig +time=2 +tries=1 +short A "$domain" @"$resolver" 2>/dev/null || true)
        done
    fi
    if command -v getent >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && records+=("$line")
        done < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' || true)
    fi
    if [[ ${#records[@]} -gt 0 ]]; then
        printf '%s\n' "${records[@]}" | awk '!seen[$0]++'
    fi
}
domain_resolves_to_public_ip() {
    local domain="${1:-}" expected_ip="${2:-}" ip=""
    [[ -n "$domain" && -n "$expected_ip" ]] || return 1
    while IFS= read -r ip; do
        [[ "$ip" == "$expected_ip" ]] && return 0
    done < <(resolve_domain_a_records "$domain")
    return 1
}
certbot_diagnostics() {
    local domain="${1:-}" resolved=""
    resolved=$(resolve_domain_a_records "$domain" | paste -sd',' - || true)
    echo "诊断: domain=${domain:-未知}"
    echo "诊断: public_ip=${PUBLIC_IP:-未知}"
    echo "诊断: resolved=${resolved:-无}"
    echo "诊断: certbot=$(command -v certbot 2>/dev/null || echo missing)"
    if command -v ss >/dev/null 2>&1; then
        echo "诊断: tcp80_listen=$(ss -H -ltnp 'sport = :80' 2>/dev/null | head -n 3 | sed 's/[[:space:]]\+/ /g' | paste -sd ';' - || true)"
    fi
}
configure_dns_upstreams() {
    local remote_selected="${REMOTE_DNS:-${DNS_UPSTREAMS:-${OVERSEAS_DNS:-${PRIVATE_OVERSEAS_DNS:-${SNIPROXY_DNS:-}}}}}"
    local local_selected="${LOCAL_DNS:-}"
    local mosdns_dir="${MOSDNS_DIR:-/etc/mosdns}"
    if [[ -z "$remote_selected" ]]; then
        remote_selected=$(cat "${mosdns_dir}/.remote_dns" 2>/dev/null || cat /etc/dnsdist/.remote_dns 2>/dev/null || true)
    fi
    if [[ -z "$local_selected" ]]; then
        local_selected=$(cat "${mosdns_dir}/.local_dns" 2>/dev/null || cat /etc/dnsdist/.local_dns 2>/dev/null || true)
    fi
    if [[ -z "$remote_selected" && -t 0 ]]; then
        echo ""
        read -r -p "国际 DNS remote [1.1.1.1,8.8.8.8,9.9.9.9]: " remote_selected
    fi
    if [[ -z "$local_selected" && -t 0 ]]; then
        read -r -p "国内 DNS local [101.226.4.6,218.30.118.6,180.76.76.76,119.29.29.29]: " local_selected
    fi
    [[ -n "$remote_selected" ]] || remote_selected="${DEFAULT_REMOTE_DNS[*]}"
    [[ -n "$local_selected" ]] || local_selected="${DEFAULT_LOCAL_DNS[*]}"
    REMOTE_DNS=$(normalize_dns_upstreams "$remote_selected")
    LOCAL_DNS=$(normalize_dns_upstreams "$local_selected")
    mkdir -p "$CONF_DIR"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.remote_dns"
    echo "$LOCAL_DNS" > "${CONF_DIR}/.local_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.overseas_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.overseas_private_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.overseas_public_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.sniproxy_dns"
    info "DNS 设置: remote=$REMOTE_DNS local=$LOCAL_DNS"
}
configure_overseas_dns() { configure_dns_upstreams; }
usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  (none)         Full interactive installation
  --status       Show service status
  --update-rules Update GFWList/ChinaList and reload mosdns
  --renew-cert   Force renew certificates and reload services
  --set-dot-domain <domain>
                 Change DoT domain, issue certificate, reload mosdns
  --set-dot-domain-force <domain>
                 Force-change DoT domain without issuing a certificate first
  --set-dns <remote-dns> [local-dns]
                 Set primary/fallback DNS upstreams and reload mosdns/sniproxy.
                 remote is used for international/proxy-side resolution; local
                 is used for ChinaList direct resolution.
  --list-exits   List configured egress exits and which one is active
  --check-exits  Test reachability of each exit's upstream node (UP/DOWN)
  --add-exit <name> [wg.conf | proxy-uri]
                 Register an egress exit. Accepts a WireGuard client config
                 (file/stdin/paste) OR ss/vmess/trojan/vless/hysteria2/tuic/
                 anytls/socks/http URI. URI types use the locked mihomo TUN
                 engine (auto-installed).
  --rename-exit <old> <new>
                 Rename a configured exit safely, including references in the
                 active selection and smart-routing policy/rules when needed.
  --set-exit <name|local|smart>
                 Switch proxy egress to <name>, 'local' for direct egress, or
                 'smart' for rule-based per-domain routing (see --set-rules).
  --del-exit <name>
                 Remove a configured exit.
  --set-rules [file]
                 Install routing rules (file/stdin/paste) for the
                 'smart' exit: route domains to exits / direct / block, with
                 local lists, remote rule-set URLs, geosite/geoip.
  --show-rules   Print the current smart-routing rules.
  --add-rule <rule>
                 Add one top-priority smart rule and rebuild atomically.
  --add-ruleset <url|path> <exit|category|direct|block>
                 Add a mihomo rule-provider source and rebuild atomically.
  --import-rules <rule-list-file>
                 Convert a rule list into smart rules (categories),
                 seed the category->exit policy map, and rebuild the router.
  --set-policy <category> <exit|direct|block>
                 Map a rule category (group) to an egress target, then rebuild.
  --del-policy <category>      Remove a rule group from the policy map.
  --rename-policy <old> <new>  Rename a rule group (updates rules + map).
  --proxy-domain <domain> <exit|direct|block>
                 One-click: hijack a domain into the gateway AND route it.
  --show-policy  Print the category -> target policy map.
  --setup-tgbot  Install/enable the Telegram control bot (uses TG_BOT_TOKEN /
                 TG_ADMIN_IDS env vars, or prompts interactively).
  --setup-whatsapp
                 Install/repair the iOS WhatsApp no-SNI TCP/443 shim.
  --uninstall    Remove all installed components
  -ios          Regenerate iOS DoT profile and QR code
  -h, --help     Show this help

Environment variables (for non-interactive use):
  DOMAIN         Your own fully-qualified domain (e.g. dns.example.com).
                 When set, the interactive domain prompt is skipped.
                 You must point its A record at this host's public IP.
  REMOTE_DNS     International/proxy-side DNS upstreams, IP[:port] list
  LOCAL_DNS      Domestic ChinaList DNS upstreams, IP[:port] list
  DNS_UPSTREAMS / OVERSEAS_DNS / PRIVATE_OVERSEAS_DNS / SNIPROXY_DNS
                 Backward-compatible aliases for REMOTE_DNS
  EMAIL          Email for Let's Encrypt
  TG_BOT_TOKEN   Telegram bot token; enables the control bot when set
  TG_ADMIN_IDS   Comma-separated Telegram numeric IDs allowed to operate the bot
  MIHOMO_VERSION Override the locked mihomo version (default: ${MIHOMO_VERSION_DEFAULT})
  FIREWALL_MODE  preserve (default) | auto | managed.
                 preserve keeps the existing host firewall untouched and only
                 manages the project's own egress-marking rules; auto adds the
                 needed allow rules to UFW/firewalld/nft/iptables without
                 flushing anything; managed fully owns the INPUT firewall
                 (always allowing every detected SSH port). Hosts upgraded from
                 older releases that already managed the firewall stay managed.
  PGW_TUNING     essential (default) | performance. essential applies only the
                 sysctls the gateway needs (ip_forward, rp_filter, BBR when
                 available); performance applies the legacy aggressive tuning.
                 Hosts upgraded from older releases keep the performance profile.
EOF
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)"
        exit 1
    fi
}
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        err "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
    case "$OS" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *)
            err "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    info "Detected OS: $OS $VER (package manager: $PKG_MGR)"
}
detect_memory_profile() {
    MEM_TOTAL_MB=$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)
    if [[ -n "${LOWMEM:-}" ]]; then
        case "${LOWMEM}" in
            1|yes|true|on)  LOWMEM=1 ;;
            *)              LOWMEM=0 ;;
        esac
    elif [[ "${MEM_TOTAL_MB:-0}" -le 1300 ]]; then
        LOWMEM=1
    else
        LOWMEM=0
    fi
    if [[ "$LOWMEM" == "1" ]]; then
        MAKE_JOBS=1
        PACKET_CACHE_SIZE=20000
        warn "Low-memory mode ENABLED (RAM: ${MEM_TOTAL_MB}MB). Reducing caches, sysctl, build jobs; iOS server is on-demand; swap will be checked."
    else
        MAKE_JOBS="$(nproc 2>/dev/null || echo 2)"
        PACKET_CACHE_SIZE=500000
        info "Standard memory mode (RAM: ${MEM_TOTAL_MB}MB)."
    fi
}
swap_size_to_bytes() {
    python3 -c 'import re, sys; raw = sys.argv[1].strip().upper(); raw = raw if raw.endswith("G") else (raw + "G" if raw else raw); m = re.fullmatch(r"([0-9]+(?:\\.[0-9]+)?)G", raw); print(0 if not m else int(float(m.group(1)) * 1024 * 1024 * 1024))' "$1"
}
confirm_swap_creation() {
    local input="${SWAP_ENABLE:-}"
    if [[ -z "$input" && -t 0 ]]; then
        read -r -p "检测到低内存且当前没有 swap，是否创建 swap？输入 y 开启，其它输入跳过 [y/N]: " input || true
    fi
    input="${input^^}"
    case "$input" in
        Y|YES) return 0 ;;
        *)     return 1 ;;
    esac
}
prompt_swap_size() {
    local input="${SWAP_SIZE:-}"
    if [[ -z "$input" && -t 0 ]]; then
        read -r -p "请输入 swap 大小（如 0.5/1/2 或 0.5G/1G/2G；回车默认 1）: " input || true
    fi
    input="${input:-1}"
    input="${input^^}"
    case "$input" in
        0|N|NO|SKIP)
            printf 'SKIP'
            return 0
            ;;
    esac
    if [[ "$input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        input="${input}G"
    fi
    if [[ ! "$input" =~ ^[0-9]+(\.[0-9]+)?G$ ]]; then
        warn "无效的 swap 大小：${input}，已回退到 1G。"
        input="1G"
    fi
    printf '%s' "$input"
}
ensure_swap() {
    [[ "${LOWMEM:-0}" == "1" ]] || return 0
    if [[ "$(wc -l < /proc/swaps 2>/dev/null || echo 1)" -gt 1 ]]; then
        info "Swap already present, skipping swapfile creation."
        return 0
    fi
    [[ -e /swapfile ]] && return 0
    local swap_size swap_bytes swap_mib required_mb avail_mb
    if ! confirm_swap_creation; then
        info "Skipping swap creation by user request."
        return 0
    fi
    swap_size="$(prompt_swap_size)"
    if [[ "$swap_size" == "SKIP" ]]; then
        info "Skipping swap creation by user request."
        return 0
    fi
    swap_bytes="$(swap_size_to_bytes "$swap_size")"
    if [[ "$swap_bytes" -le 0 ]]; then
        warn "无法解析 swap 大小，已回退到 1G。"
        swap_size="1G"
        swap_bytes="$(swap_size_to_bytes "$swap_size")"
    fi
    swap_mib=$(( (swap_bytes + 1024 * 1024 - 1) / 1024 / 1024 ))
    required_mb=$(( (swap_mib * 3 + 1) / 2 ))
    avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt "$required_mb" ]]; then
        warn "Not enough free disk for a ${swap_size} swapfile (${avail_mb:-?}MB free, need ~${required_mb}MB); skipping."
        return 0
    fi
    info "Creating ${swap_size} swapfile to avoid OOM on this low-memory host..."
    if ! fallocate -l "$swap_bytes" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mib" status=none 2>/dev/null || {
            warn "Failed to allocate swapfile; continuing without swap."; rm -f /swapfile; return 0; }
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || { warn "mkswap failed; skipping swap."; rm -f /swapfile; return 0; }
    swapon /swapfile 2>/dev/null || { warn "swapon failed; skipping swap."; rm -f /swapfile; return 0; }
    if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    ok "${swap_size} swapfile active."
}
get_public_ip() {
    PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || \
                curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null || echo "")
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "")
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        err "Failed to detect public IPv4 address. Please set PUBLIC_IP manually."
        exit 1
    fi
    info "Public IP detected: $PUBLIC_IP"
}
port53_pids() {
    ss -H -lnptu 2>/dev/null | awk '$5 ~ /(^|\[|:)53$/ {print}' | grep -oP 'pid=\K[0-9]+' | sort -u || true
}
port53_owner_summary() {
    local pids pid proc unit summaries=()
    pids=$(port53_pids)
    for pid in $pids; do
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        unit=$(systemd_unit_for_pid "$pid")
        if [[ -n "$unit" ]]; then
            summaries+=("$proc (PID: $pid, unit: $unit)")
        else
            summaries+=("$proc (PID: $pid)")
        fi
    done
    (IFS=', '; echo "${summaries[*]}")
}
check_port_53() {
    info "Checking port 53 availability..."
    local pid pids proc remaining
    pids=$(port53_pids)
    if [[ -n "$pids" ]]; then
        pid=$(printf '%s\n' "$pids" | head -n1)
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        warn "Port 53 is already in use by: $(port53_owner_summary)"
        local confirm=""
        if [[ "$proc" == "dnsdist" || "$proc" == "mosdns" ]]; then
            info "Stopping the existing $proc service for DNS migration/update..."
        else
            read -r -p "Stop and disable '$proc' to free port 53? [Y/n]: " confirm
        fi
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            err "Port 53 must be free for mosdns to start. Aborting."
            exit 1
        fi
        for pid in $pids; do
            proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            stop_port53_owner "$pid" "$proc"
        done
        wait_for_port53_free 10
        remaining=$(port53_pids)
        if [[ -n "$remaining" ]]; then
            warn "Port 53 is still in use by: $(port53_owner_summary)"
            warn "Trying SIGTERM/SIGKILL on remaining port 53 owners..."
            for pid in $remaining; do
                kill "$pid" 2>/dev/null || true
            done
            wait_for_port53_free 5
        fi
        remaining=$(port53_pids)
        if [[ -n "$remaining" ]]; then
            for pid in $remaining; do
                kill -9 "$pid" 2>/dev/null || true
            done
            wait_for_port53_free 3
        fi
        remaining=$(port53_pids)
        if [[ -n "$remaining" ]]; then
            err "Failed to free port 53. Still in use by: $(port53_owner_summary)"
            err "Check with: ss -lnptu 'sport = :53' ; systemctl status <unit> ; journalctl -u <unit> -n 50"
            exit 1
        fi
        ok "Port 53 is now free"
    else
        ok "Port 53 is available"
    fi
}
wait_for_port53_free() {
    local timeout="${1:-10}" i
    for ((i=0; i<timeout; i++)); do
        [[ -z "$(port53_pids)" ]] && return 0
        sleep 1
    done
    [[ -z "$(port53_pids)" ]]
}
systemd_unit_for_pid() {
    local pid="${1:-}"
    [[ -z "$pid" || ! -r "/proc/$pid/cgroup" ]] && return 0
    grep -aoE '[^/]+\.service' "/proc/$pid/cgroup" | head -n1 || true
}
stop_port53_owner() {
    local pid="${1:-}"
    local proc="${2:-unknown}"
    local unit
    unit=$(systemd_unit_for_pid "$pid")
    if [[ -n "$unit" ]]; then
        stop_systemd_unit_and_socket "$unit"
    fi
    case "$proc" in
        systemd-resolve|systemd-resolved)
            info "Stopping systemd-resolved service to release DNS stub port 53"
            if [[ -L /etc/resolv.conf || -f /etc/resolv.conf ]]; then
                if ! grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
                    cp -a /etc/resolv.conf /etc/resolv.conf.pgw.bak 2>/dev/null || true
                    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF
                    info "Rewrote /etc/resolv.conf to public DNS servers for installer stability"
                fi
            fi
            stop_systemd_unit_and_socket systemd-resolved.service
            ;;
        mosdns)
            stop_systemd_unit_and_socket mosdns.service
            ;;
        dnsdist)
            stop_systemd_unit_and_socket dnsdist.service
            ;;
        dnsmasq)
            stop_systemd_unit_and_socket dnsmasq.service
            ;;
        named)
            stop_systemd_unit_and_socket named.service
            stop_systemd_unit_and_socket bind9.service
            ;;
    esac
}
stop_systemd_unit_and_socket() {
    local unit="${1:-}"
    [[ -z "$unit" ]] && return 0
    local socket="${unit%.service}.socket"
    info "Stopping systemd unit owning port 53: $unit"
    systemctl stop "$socket" 2>/dev/null || true
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" "$socket" 2>/dev/null || true
}
install_deps() {
    info "Installing system dependencies..."
    local pcre_dev_pkg="libpcre3-dev"
    if [[ "${OS:-}" == "debian" && "${VER%%.*}" -ge 13 ]]; then
        pcre_dev_pkg="libpcre2-dev"
    fi
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            if ! apt-get update -qq; then
                warn "apt update failed; trying a direct public DNS path for Debian mirrors..."
                if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
                    sed -i 's/^URIs: .*/URIs: http:\/\/deb.debian.org\/debian/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
                fi
                if [[ -f /etc/apt/sources.list ]]; then
                    sed -i 's|^[[:space:]]*deb[[:space:]]\+mirror+file:/etc/apt/mirrors/.*|deb http://deb.debian.org/debian trixie main|g' /etc/apt/sources.list 2>/dev/null || true
                fi
                apt-get update -qq
            fi
            apt-get install -y -qq \
                build-essential git wget curl ca-certificates \
                libev-dev "${pcre_dev_pkg}" libudns-dev libssl-dev \
                autoconf automake libtool pkg-config \
                certbot python3-certbot-dns-cloudflare \
                python3 python3-pip jq libcap2-bin \
                nftables qrencode wireguard-tools || true
            ;;
        dnf|yum)
            $PKG_MGR install -y -q \
                gcc gcc-c++ make git wget curl ca-certificates \
                libev-devel pcre-devel openssl-devel \
                autoconf automake libtool pkgconfig \
                certbot python3-certbot-dns-cloudflare \
                python3 python3-pip jq libcap-ng-utils \
                nftables qrencode wireguard-tools || true
            ;;
    esac
    if ! command -v go >/dev/null 2>&1; then
        info "Installing Go compiler..."
        GO_VER="1.22.4"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GO_ARCH="amd64" ;;
            aarch64|arm64) GO_ARCH="arm64" ;;
            *) GO_ARCH="amd64" ;;
        esac
        wget -q "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        # shellcheck disable=SC2016 # Write a literal profile snippet for future shells.
        printf '%s\n' 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    fi
    ok "Go version: $(go version)"
    if command -v certbot >/dev/null 2>&1; then
        if ! certbot --version >/dev/null 2>&1; then
            warn "Certbot has compatibility issues with the current Python version. Attempting to fix..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
        fi
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        err "Required package 'certbot' was not installed successfully."
        err "Please check your package manager output above."
        exit 1
    fi
}
ensure_mosdns_user() {
    if ! id mosdns >/dev/null 2>&1; then
        useradd --system --home-dir /etc/mosdns --shell /usr/sbin/nologin mosdns
    fi
}
install_mosdns_binary() {
    local version="${MOSDNS_VERSION:-$MOSDNS_VERSION_DEFAULT}" arch asset url tmpdir
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) err "Unsupported mosdns architecture: $(uname -m)"; exit 1 ;;
    esac
    if command -v mosdns >/dev/null 2>&1 && mosdns version 2>/dev/null | grep -q "v${version}"; then
        info "mosdns v${version} already installed"
        return 0
    fi
    info "Installing mosdns v${version}..."
    asset="mosdns-linux-${arch}.zip"
    url="https://github.com/IrineSistiana/mosdns/releases/download/v${version}/${asset}"
    tmpdir=$(mktemp -d /tmp/mosdns.XXXXXX)
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "${tmpdir}/${asset}"
    python3 - "${tmpdir}/${asset}" "$tmpdir" <<'PYEOF'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    member = next((name for name in archive.namelist() if name.rstrip("/").endswith("mosdns")), None)
    if member is None:
        raise SystemExit("mosdns binary missing from release archive")
    with archive.open(member) as source, open(sys.argv[2] + "/mosdns", "wb") as target:
        target.write(source.read())
PYEOF
    install -m 0755 "${tmpdir}/mosdns" /usr/local/bin/mosdns
    rm -rf "$tmpdir"
    mosdns version >/dev/null
    ok "mosdns v${version} installed"
}
is_valid_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]
}
generate_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        if ! is_valid_domain "$DOMAIN"; then
            err "Invalid DOMAIN: '$DOMAIN'. Provide a fully-qualified domain like dns.example.com"
            exit 1
        fi
        info "Using pre-configured domain: $DOMAIN"
        mkdir -p "$CONF_DIR"
        echo "$DOMAIN" > "${CONF_DIR}/.domain"
        return
    fi
    if [[ ! -t 0 ]]; then
        err "No domain provided. Set the DOMAIN environment variable (e.g. DOMAIN=dns.example.com) for non-interactive installs."
        exit 1
    fi
    echo ""
    echo "=================================================="
    echo "  请输入你自己的域名"
    echo "=================================================="
    echo "  示例: dns.example.com 或 example.com"
    echo "  该域名需要你能管理其 DNS（添加一条 A 记录指向本机）"
    echo "=================================================="
    echo ""
    local input=""
    while true; do
        read -r -p "请输入域名: " input
        input="${input## }"; input="${input%% }"
        input="${input#http://}"; input="${input#https://}"
        input="${input%/}"
        if is_valid_domain "$input"; then
            DOMAIN="$input"
            break
        fi
        warn "无效域名，请输入形如 dns.example.com 的完整域名"
    done
    info "Using domain: $DOMAIN"
    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
}
verify_domain_dns() {
    info "DNS 解析检查"
    info "=================================================="
    info "域名: $DOMAIN"
    info "需要的 A 记录值: $PUBLIC_IP"
    info "=================================================="
    info ""
    info "请在你自己的 DNS 服务商处添加（或确认已存在）一条 A 记录:"
    info "   Host:  ${DOMAIN%%.*}  (若是裸域则填 @ 或留空)"
    info "   Type:  A"
    info "   Value: $PUBLIC_IP"
    info "   TTL:   尽量低 (如 60-300)，便于快速生效"
    info ""
    if [[ -t 0 ]]; then
        local confirm=""
        read -r -p "完成配置后按 Enter 继续（或输入 'skip' 跳过解析验证）: " confirm
        if [[ "$confirm" == "skip" ]]; then
            warn "跳过域名解析验证，请确保 A 记录已正确配置"
            mkdir -p "$CONF_DIR"
            echo "$DOMAIN" > "${CONF_DIR}/.domain"
            return
        fi
    fi
    info "等待 DNS 解析生效（最多 120 秒）..."
    local waited=0 resolved=""
    while [[ $waited -lt 120 ]]; do
        resolved=$(resolve_domain_a_records "$DOMAIN" | paste -sd',' - || true)
        if domain_resolves_to_public_ip "$DOMAIN" "$PUBLIC_IP"; then
            ok "DNS 解析验证通过: $DOMAIN -> $PUBLIC_IP"
            mkdir -p "$CONF_DIR"
            echo "$DOMAIN" > "${CONF_DIR}/.domain"
            return
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo ""
    warn "DNS 解析未在 120 秒内生效（当前解析: ${resolved:-无}）。"
    warn "将继续安装；如后续 Let's Encrypt 证书申请失败，请确认 $DOMAIN 的 A 记录已指向 $PUBLIC_IP。"
    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
}
install_cert() {
    local certbot_cmd certbot_cmd_force
    ensure_mosdns_user
    CERTBOT_LAST_OUTPUT=""
    install_certbot_firewall_hooks
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)
    certbot_cmd_force=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)
    local cb_cmd=()
    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        info "Let's Encrypt certificate already exists for $DOMAIN, forcing renewal..."
        cb_cmd=("${certbot_cmd_force[@]}")
    else
        info "申请 Let's Encrypt 证书 for $DOMAIN..."
        cb_cmd=("${certbot_cmd[@]}")
    fi
    run_certbot() {
        prepare_certbot_standalone
        trap cleanup_certbot_standalone RETURN
        local out retry_out rc
        if out="$("${cb_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
        CERTBOT_LAST_OUTPUT="$out"
        printf '%s\n' "$out"
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        if grep -q "AttributeError" <<<"$out"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
            info "Retrying certificate request..."
            if retry_out="$("${cb_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
            CERTBOT_LAST_OUTPUT="$retry_out"
            printf '%s\n' "$retry_out"
            return $rc
        fi
        return 1
    }
    if ! run_certbot; then
        err "证书申请失败。请检查:"
        err "  1. 域名 $DOMAIN 是否正确解析到本机 ($PUBLIC_IP)"
        err "  2. 端口 80 是否被占用"
        err "  3. 防火墙是否放行 80"
        err "  4. 是否触发了 Let's Encrypt 速率限制 (同一域名 7 天内限 5 次)"
        if [[ -n "${CERTBOT_LAST_OUTPUT:-}" ]]; then
            err "certbot 最后输出:"
            printf '%s\n' "$CERTBOT_LAST_OUTPUT" | tail -n 30 >&2
        fi
        exit 1
    fi
    info "Copying certificates to /etc/mosdns/certs/ ..."
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/mosdns/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/mosdns/certs/privkey.pem
        chown -R mosdns:mosdns /etc/mosdns/certs/
        chmod 600 /etc/mosdns/certs/*.pem
        ok "Certificates copied to /etc/mosdns/certs/"
    else
        warn "Could not find certificate live directory: $cert_live_dir"
    fi
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    if [[ -f "${LIB_DIR}/renew-hook.sh" ]]; then
        cp "${LIB_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
        ok "证书已就绪，自动续期 Hook 已部署"
    else
        warn "renew-hook.sh not found in ${LIB_DIR}; keeping existing renewal hook"
        ok "证书已就绪"
    fi
}
install_sniproxy() {
    ensure_proxy_user
    if ! command -v sniproxy >/dev/null 2>&1; then
        info "Compiling sniproxy (TCP SNI proxy)..."
        mkdir -p "$SRC_DIR"
        cd "$SRC_DIR"
        if [[ ! -d sniproxy ]]; then
            git clone --depth=1 https://github.com/dlundquist/sniproxy.git
        fi
        cd sniproxy
        DEBEMAIL="root@localhost" DEBFULLNAME="root" ./autogen.sh >/dev/null
        ./configure --prefix=/usr/local --sysconfdir=/etc --enable-dns >/dev/null
        make -j"${MAKE_JOBS:-$(nproc)}" >/dev/null
        make install >/dev/null
    else
        info "sniproxy already installed"
    fi
    if [[ -f "${LIB_DIR}/sniproxy.conf" ]]; then
        local sniproxy_nameservers
        sniproxy_nameservers=$(render_sniproxy_dns_nameservers "$REMOTE_DNS")
        python3 - "${LIB_DIR}/sniproxy.conf" "$sniproxy_nameservers" /etc/sniproxy.conf <<'PYEOF'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__SNIPROXY_NAMESERVERS__", sys.argv[2])
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
    else
        err "sniproxy.conf not found in ${LIB_DIR}"
        exit 1
    fi
    cat > /etc/systemd/system/sniproxy.service <<'EOF'
[Unit]
Description=sniproxy (TCP SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/sniproxy -c /etc/sniproxy.conf -f
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sniproxy
    ok "sniproxy installed"
}
install_whatsapp_shim() {
    local shim_dns self_ips
    info "Installing iOS WhatsApp no-SNI shim..."
    [[ -f "${LIB_DIR}/wa-shim.py" ]] || { err "wa-shim.py not found in ${LIB_DIR}"; return 1; }
    mkdir -p "${BASE_DIR}/bin" "${CONF_DIR}"
    install -m 0755 "${LIB_DIR}/wa-shim.py" "${BASE_DIR}/bin/wa-shim.py"
    mkdir -p /etc/mosdns
    touch /etc/mosdns/gfwlist-extra-local.txt
    for domain in whatsapp.net whatsapp.com; do
        grep -qxF "$domain" /etc/mosdns/gfwlist-extra-local.txt || echo "$domain" >> /etc/mosdns/gfwlist-extra-local.txt
    done
    shim_dns="${REMOTE_DNS:-$(cat "${CONF_DIR}/.remote_dns" 2>/dev/null || printf '%s ' "${DEFAULT_REMOTE_DNS[@]}")}"
    self_ips="${PUBLIC_IP:-},127.0.0.1,::1,"
    self_ips+="$(hostname -I 2>/dev/null | tr ' ' ',' | tr -d '\n')"
    cat > "${CONF_DIR}/wa-shim.env" <<EOF
WA_SHIM_LISTEN=0.0.0.0
WA_SHIM_PORT=443
WA_SHIM_BACKEND=127.0.0.1:8443
WA_SHIM_WA_HOST=g.whatsapp.net
WA_SHIM_RESOLVER=$(first_plain_dns "$shim_dns"),8.8.8.8
WA_SHIM_SELF_IPS=${self_ips}
WA_SHIM_ALLOW_CIDR=172.22.0.0/16,127.0.0.0/8
EOF
    chmod 600 "${CONF_DIR}/wa-shim.env"
    cat > /etc/systemd/system/wa-shim.service <<EOF
[Unit]
Description=5GPN-X iOS WhatsApp no-SNI shim
After=network-online.target sniproxy.service
Wants=network-online.target
Requires=sniproxy.service

[Service]
Type=simple
EnvironmentFile=${CONF_DIR}/wa-shim.env
ExecStart=/usr/bin/python3 ${BASE_DIR}/bin/wa-shim.py
Restart=always
RestartSec=2
User=${EXIT_USER}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wa-shim.service 2>/dev/null || true
    ok "WhatsApp no-SNI shim installed (public :443 -> sniproxy 127.0.0.1:8443)"
}
install_quic_proxy() {
    ensure_proxy_user
    if [[ ! -x "${BASE_DIR}/bin/quic-proxy" ]]; then
        info "Compiling quic-proxy (UDP/QUIC SNI proxy)..."
        mkdir -p "${BASE_DIR}/bin"
        mkdir -p "${SRC_DIR}"
        cp "${LIB_DIR}/quic-proxy.go" "${SRC_DIR}/quic-proxy.go"
        cd "${SRC_DIR}"
        export PATH=$PATH:/usr/local/go/bin
        go build -ldflags="-s -w" -o "${BASE_DIR}/bin/quic-proxy" quic-proxy.go
    else
        info "quic-proxy already compiled"
    fi
    cat > /etc/systemd/system/quic-proxy.service <<'EOF'
[Unit]
Description=quic-proxy (UDP/QUIC SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/opt/proxy-gateway/bin/quic-proxy -l 0.0.0.0:443
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=pxout
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable quic-proxy
    ok "quic-proxy installed"
}
install_mosdns() {
    info "Configuring mosdns..."
    ensure_mosdns_user
    install_mosdns_binary
    mkdir -p /etc/mosdns
    cp "${LIB_DIR}/mosdns.yaml.template" /etc/mosdns/config.yaml.template
    cp "${LIB_DIR}/update-rules.sh" /usr/local/bin/update-mosdns-rules.sh
    chmod +x /usr/local/bin/update-mosdns-rules.sh
    echo "$DOMAIN" > /etc/mosdns/.domain
    echo "$PUBLIC_IP" > /etc/mosdns/.public_ip
    echo "$REMOTE_DNS" > /etc/mosdns/.remote_dns
    echo "$LOCAL_DNS" > /etc/mosdns/.local_dns
    echo "$REMOTE_DNS" > /etc/mosdns/.overseas_dns
    echo "$REMOTE_DNS" > /etc/mosdns/.overseas_private_dns
    echo "$REMOTE_DNS" > /etc/mosdns/.overseas_public_dns
    echo "$REMOTE_DNS" > /etc/mosdns/.sniproxy_dns
    echo "${PACKET_CACHE_SIZE:-500000}" > /etc/mosdns/.cache_size
    touch /etc/mosdns/gfwlist.txt /etc/mosdns/chinalist.txt /etc/mosdns/gfwlist-extra-local.txt
    chown -R mosdns:mosdns /etc/mosdns
    chmod 0750 /etc/mosdns /etc/mosdns/certs
    cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns smart DNS and DNS-over-TLS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=always
RestartSec=3
User=mosdns
Group=mosdns
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/mosdns
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl disable --now dnsdist.service update-dnsdist-rules.timer china-dns-race-proxy.service 2>/dev/null || true
    rm -rf /etc/systemd/system/dnsdist.service.d /etc/systemd/system/china-dns-race-proxy.service.d
    rm -f /etc/systemd/system/update-dnsdist-rules.{service,timer} \
        /etc/systemd/system/china-dns-race-proxy.service \
        /usr/local/bin/update-dnsdist-rules.sh \
        /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh \
        "${BASE_DIR}/bin/china-dns-race-proxy"
    systemctl daemon-reload
    systemctl enable mosdns
    ok "mosdns configured"
}
init_rules() {
    info "Initializing GFWList and ChinaList..."
    /usr/local/bin/update-mosdns-rules.sh || warn "Rule update failed, will retry later"
}
generate_ios_profile() {
    info "Generating iOS DoT configuration profile..."
    mkdir -p "$WWW_DIR"
    local profile_path="${WWW_DIR}/ios-dot.mobileconfig"
    local profile_url="http://${DOMAIN}:${IOS_PROFILE_PORT}/ios-dot.mobileconfig"
    cat > "$profile_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>DNSSettings</key>
            <dict>
                <key>DNSProtocol</key>
                <string>TLS</string>
                <key>ServerName</key>
                <string>${DOMAIN}</string>
                <key>ServerAddresses</key>
                <array>
                    <string>${PUBLIC_IP}</string>
                </array>
            </dict>
            <key>OnDemandRules</key>
            <array>
                <dict>
                    <key>Action</key>
                    <string>Connect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>Cellular</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>WiFi</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Use ${DOMAIN} DNS over TLS only on cellular networks.</string>
            <key>PayloadDisplayName</key>
            <string>Proxy Gateway Cellular DoT</string>
            <key>PayloadIdentifier</key>
            <string>com.proxy-gateway.${DOMAIN}.dnssettings</string>
            <key>PayloadType</key>
            <string>com.apple.dnsSettings.managed</string>
            <key>PayloadUUID</key>
            <string>$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs a DNS over TLS profile for cellular networks only.</string>
    <key>PayloadDisplayName</key>
    <string>Proxy Gateway Cellular DoT</string>
    <key>PayloadIdentifier</key>
    <string>com.proxy-gateway.${DOMAIN}</string>
    <key>PayloadOrganization</key>
    <string>Proxy Gateway</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF
    cat > "${WWW_DIR}/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Proxy Gateway iOS DoT</title>
</head>
<body>
  <h1>Proxy Gateway iOS DoT</h1>
  <p><a href="/ios-dot.mobileconfig">下载 iOS 蜂窝网络 DoT 描述文件</a></p>
</body>
</html>
EOF
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    mkdir -p "${BASE_DIR}/bin"
    if [[ -f "${LIB_DIR}/ios-http.py" ]]; then
        install -m 0755 "${LIB_DIR}/ios-http.py" "${BASE_DIR}/bin/ios-http.py"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^proxy-gateway-ios-profile\.service'; then
        systemctl disable --now proxy-gateway-ios-profile.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/proxy-gateway-ios-profile.service
    cat > /etc/systemd/system/proxy-gateway-ios-profile.socket <<EOF
[Unit]
Description=Proxy Gateway iOS profile HTTP socket

[Socket]
ListenStream=0.0.0.0:${IOS_PROFILE_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
EOF
    cat > /etc/systemd/system/proxy-gateway-ios-profile@.service <<EOF
[Unit]
Description=Proxy Gateway iOS profile responder (per-connection)

[Service]
Type=simple
ExecStart=${py} ${BASE_DIR}/bin/ios-http.py
Environment=WWW_DIR=${WWW_DIR}
StandardInput=socket
StandardOutput=socket
StandardError=journal
User=root
EOF
    systemctl daemon-reload
    systemctl enable --now proxy-gateway-ios-profile.socket
    echo "$profile_url" > "${WWW_DIR}/ios-profile-url.txt"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$profile_url" | tee "${WWW_DIR}/ios-dot.qr.txt"
    else
        warn "qrencode is not installed; QR code skipped. Profile URL: $profile_url"
    fi
    ok "iOS profile ready: $profile_url"
}
# Host firewall & kernel tuning helpers live in lib/host-setup.sh to keep this
# script below the 128 KiB single-argument limit of `bash -c "$(curl ...)"`.
if [[ -f "${LIB_DIR}/host-setup.sh" ]]; then
    # shellcheck source=lib/host-setup.sh
    . "${LIB_DIR}/host-setup.sh"
else
    err "lib/host-setup.sh not found next to this script; run from a full git clone or the documented installer."
    exit 1
fi
prepare_certbot_standalone() {
    CERT_STOPPED_SNIPROXY=0
    CERT_STOPPED_WA_SHIM=0
    if systemctl is-active --quiet wa-shim 2>/dev/null; then
        info "Stopping wa-shim temporarily during certificate maintenance..."
        systemctl stop wa-shim
        CERT_STOPPED_WA_SHIM=1
    fi
    if systemctl is-active --quiet sniproxy 2>/dev/null; then
        info "Stopping sniproxy temporarily so certbot can bind TCP/80..."
        systemctl stop sniproxy
        CERT_STOPPED_SNIPROXY=1
    fi
    open_cert_http_port
}
cleanup_certbot_standalone() {
    local rc=$?
    restore_reverse_proxy_firewall
    if [[ "${CERT_STOPPED_SNIPROXY:-0}" == "1" ]]; then
        info "Starting sniproxy after certbot..."
        systemctl start sniproxy || warn "sniproxy failed to restart after certbot; run: systemctl status sniproxy"
    fi
    if [[ "${CERT_STOPPED_WA_SHIM:-0}" == "1" ]]; then
        systemctl start wa-shim || warn "wa-shim failed to restart after certbot"
    fi
    return $rc
}
install_certbot_firewall_hooks() {
    mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
    cat > /usr/local/bin/proxy-gateway-open-cert-http.sh <<'EOF'
#!/bin/bash
set -e
systemctl stop sniproxy 2>/dev/null || true
systemctl stop wa-shim 2>/dev/null || true
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept comment '"proxy-gateway-cert-http"' 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
fi
EOF
    cat > /usr/local/bin/proxy-gateway-restore-firewall.sh <<'EOF'
#!/bin/bash
set -e
# Delete only the tagged temporary rule. Reloading /etc/nftables.conf here
# would be wrong when the firewall is user-managed (FIREWALL_MODE=preserve).
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    while h="$(nft --handle list chain inet filter input 2>/dev/null | awk '/proxy-gateway-cert-http/ { print $NF; exit }')" && [ -n "$h" ]; do
        nft delete rule inet filter input handle "$h" 2>/dev/null || break
    done
fi
if command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do :; done
fi
systemctl start sniproxy 2>/dev/null || true
systemctl start wa-shim 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/proxy-gateway-open-cert-http.sh /usr/local/bin/proxy-gateway-restore-firewall.sh
    cp /usr/local/bin/proxy-gateway-open-cert-http.sh /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh
    cp /usr/local/bin/proxy-gateway-restore-firewall.sh /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
}
ensure_proxy_user() {
    if id -u "${EXIT_USER}" >/dev/null 2>&1; then
        return 0
    fi
    useradd --system --no-create-home --shell /usr/sbin/nologin "${EXIT_USER}" 2>/dev/null \
        || useradd -r -s /sbin/nologin "${EXIT_USER}" 2>/dev/null \
        || true
    id -u "${EXIT_USER}" >/dev/null 2>&1 || warn "Could not create egress user ${EXIT_USER}"
}
exit_conf_path()    { echo "${WG_DIR}/pgw-${1}.conf"; }       # wireguard config
exit_iface() {
    local name="$1"
    if [[ "$name" =~ ^[A-Za-z0-9_-]{1,11}$ ]]; then
        echo "pgw-${name}"
    else
        printf 'pgw-%s\n' "$(printf '%s' "$name" | sha256sum | cut -c1-11)"
    fi
}
exit_mihomo_unit() { systemd-escape --template=proxy-gateway-mihomo@.service "$1"; }
exit_type_file()    { echo "${EXITS_DIR}/${1}.type"; }
exit_mihomo_conf()  { echo "${EXITS_DIR}/${1}.yaml"; }
exit_type() {
    local name="$1" tf; tf="$(exit_type_file "$name")"
    if [[ -f "$tf" ]]; then cat "$tf"; return; fi
    [[ -f "$(exit_conf_path "$name")" ]] && { echo wireguard; return; }
    echo ""
}
exit_exists() {
    [[ -f "$(exit_type_file "$1")" || -f "$(exit_conf_path "$1")" ]]
}
ensure_mihomo_exit_iface() {
    local name="$1" yaml iface
    yaml="$(exit_mihomo_conf "$name")"
    [[ -f "$yaml" ]] || return 0
    iface="$(exit_iface "$name")"
    python3 - "$yaml" "$iface" <<'PY'
import json, os, sys, tempfile

path, device = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    config = json.load(f)
if config.setdefault("tun", {}).get("device") == device:
    raise SystemExit(0)
config["tun"]["device"] = device
fd, tmp = tempfile.mkstemp(prefix=".exit-iface-", dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}
list_exit_names() {
    shopt -s nullglob
    local f n; local -A seen=()
    for f in "${EXITS_DIR}"/*.type; do n="$(basename "$f" .type)"; seen["$n"]=1; done
    for f in "${WG_DIR}"/pgw-*.conf; do
        [[ -L "$f" ]] && continue    # runtime iface aliases for Unicode names
        n="$(basename "$f" .conf)"; seen["${n#pgw-}"]=1
    done
    shopt -u nullglob
    if [[ ${#seen[@]} -gt 0 ]]; then
        printf '%s\n' "${!seen[@]}" | sort
    fi
    return 0
}
ensure_mihomo() {
    [[ -x "${MIHOMO_BIN}" ]] && return 0
    info "Installing locked mihomo ${MIHOMO_VERSION_DEFAULT} (TUN engine for URI exits)..."
    local ver arch tmp url
    ver="${MIHOMO_VERSION:-${MIHOMO_VERSION_DEFAULT}}"
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l) arch=armv7 ;;
        *) err "Unsupported architecture for mihomo: $(uname -m)"; return 1 ;;
    esac
    url="https://github.com/MetaCubeX/mihomo/releases/download/v${ver}/mihomo-linux-${arch}-v${ver}.gz"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 90 "$url" -o "$tmp/mihomo.gz"; then
        rm -rf "$tmp"; err "Failed to download mihomo ${ver}. Set MIHOMO_VERSION=<ver> and retry. URL: $url"; return 1
    fi
    if ! gzip -dc "$tmp/mihomo.gz" > "$tmp/mihomo"; then
        rm -rf "$tmp"; err "Failed to extract mihomo archive"; return 1
    fi
    mkdir -p "${BASE_DIR}/bin"
    install -m 0755 "$tmp/mihomo" "${MIHOMO_BIN}"
    rm -rf "$tmp"
    ok "mihomo ${ver} installed: ${MIHOMO_BIN}"
}
install_mihomo_unit() {
    cat > /etc/systemd/system/proxy-gateway-mihomo@.service <<EOF
[Unit]
Description=Proxy Gateway mihomo exit (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${CONF_DIR}/mihomo/%I -f ${EXITS_DIR}/%I.yaml
# Recreating the TUN drops the table-100 route; re-apply it after (re)start.
ExecStartPost=-/usr/local/bin/proxy-gateway-apply-exit.sh
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535
Environment=SKIP_SYSTEM_IPV6_CHECK=1
Environment=GOGC=50
Environment=GOMEMLIMIT=128MiB

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p "${CONF_DIR}/mihomo"
    systemctl stop 'proxy-gateway-singbox@*.service' 2>/dev/null || true
    rm -f /etc/systemd/system/proxy-gateway-singbox@.service
    rm -f "${BASE_DIR}/bin/sing-box" "${BASE_DIR}/bin/singbox-exit-config.py" \
        "${BASE_DIR}/bin/singbox-router-config.py"
    systemctl daemon-reload
}
migrate_singbox_exits() {
    shopt -s nullglob
    local old=0 current_removed=0 f name backup="${EXITS_DIR}/singbox-backup"
    local current="local"
    [[ -f "${CONF_DIR}/current-exit" ]] && current="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    for f in "${EXITS_DIR}"/*.json; do
        old=1
        name="$(basename "$f" .json)"
        [[ "$name" == "$current" ]] && current_removed=1
        mkdir -p "$backup"
        mv "$f" "${backup}/${name}.json"
        if [[ -f "$(exit_type_file "$name")" ]]; then
            cp -a "$(exit_type_file "$name")" "${backup}/${name}.type"
            rm -f "$(exit_type_file "$name")"
        fi
    done
    shopt -u nullglob
    [[ $old -eq 1 ]] || return 0
    systemctl stop 'proxy-gateway-singbox@*.service' 2>/dev/null || true
    if [[ $current_removed -eq 1 ]]; then
        echo local > "${CONF_DIR}/current-exit"
        ip route flush table "${EXIT_TABLE}" 2>/dev/null || true
        ip rule del fwmark "${EXIT_MARK}" table "${EXIT_TABLE}" priority "${EXIT_RULE_PRIO}" 2>/dev/null || true
    fi
    warn "Legacy sing-box exits were backed up to ${backup}."
    warn "Re-add URI exits from their original share links; smart rules can then be rebuilt with --set-rules."
}
exit_up() {
    local name="$1" t iface conf runtime_conf; t="$(exit_type "$name")"
    case "$t" in
        wireguard)
            command -v wg-quick >/dev/null 2>&1 || { err "wg-quick not installed"; return 1; }
            iface="$(exit_iface "$name")"
            conf="$(exit_conf_path "$name")"
            runtime_conf="${WG_DIR}/${iface}.conf"
            [[ "$conf" == "$runtime_conf" ]] || ln -sf "$conf" "$runtime_conf"
            wg-quick up "$iface" ;;
        shadowsocks|vmess|trojan|vless|hysteria|hysteria2|tuic|anytls|shadowtls|socks|http|router)
            ensure_mihomo || return 1
            ensure_mihomo_exit_iface "$name" || return 1
            install_mihomo_unit
            systemctl start "$(exit_mihomo_unit "$name")" ;;
        *) err "Unknown type for exit '$name'"; return 1 ;;
    esac
}
exit_down() {
    local name="$1" t iface conf runtime_conf; t="$(exit_type "$name")"
    case "$t" in
        wireguard)
            iface="$(exit_iface "$name")"
            conf="$(exit_conf_path "$name")"
            runtime_conf="${WG_DIR}/${iface}.conf"
            wg-quick down "$iface" 2>/dev/null || true
            [[ "$conf" == "$runtime_conf" ]] || rm -f "$runtime_conf" ;;
        shadowsocks|vmess|trojan|vless|hysteria|hysteria2|tuic|anytls|shadowtls|socks|http|router) systemctl stop "$(exit_mihomo_unit "$name")" 2>/dev/null || true ;;
    esac
}
exit_server() {
    local jf; jf="$(exit_mihomo_conf "$1")"
    [[ -f "$jf" ]] || return 0
    python3 - "$jf" <<'PY' 2>/dev/null
import json, sys
try:
    o = json.load(open(sys.argv[1]))["proxies"][0]
    if o.get("server"):
        print(o["server"], o.get("port", ""))
except Exception:
    pass
PY
}
exit_reachable() {
    local host="$1" port="$2"
    [[ -z "$host" || -z "$port" ]] && return 0
    timeout 4 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}
preflight_exit() {
    local name="$1" t hp host port tgt
    t="$(exit_type "$name")"
    if [[ "$t" =~ ^(shadowsocks|vmess|trojan|vless|hysteria|hysteria2|tuic|anytls|shadowtls|socks|http)$ ]]; then
        hp="$(exit_server "$name")"; host="${hp%% *}"; port="${hp##* }"
        if ! exit_reachable "$host" "$port"; then
            warn "Exit '$name' upstream ${host}:${port} is UNREACHABLE — traffic via it will fail."
        fi
    elif [[ "$t" == "router" ]]; then
        while IFS= read -r tgt; do
            case "$tgt" in direct|block|"") continue ;; esac
            hp="$(exit_server "$tgt")"; host="${hp%% *}"; port="${hp##* }"
            if ! exit_reachable "$host" "$port"; then
                warn "Smart target '$tgt' (${host}:${port}) is UNREACHABLE — rules using it will blackhole."
            fi
        done < <(awk -F= 'NF==2{print $2}' "${POLICY_MAP}" 2>/dev/null | sort -u)
    fi
}
check_exits() {
    local n hp host port state
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        [[ "$(exit_type "$n")" == "router" ]] && continue   # router targets listed individually
        hp="$(exit_server "$n")"; host="${hp%% *}"; port="${hp##* }"
        if [[ -z "$host" ]]; then
            state="n/a"
        elif exit_reachable "$host" "$port"; then
            state="UP"
        else
            state="DOWN"
        fi
        printf '  %-12s %-22s %s\n' "$n" "${host:+${host}:${port}}" "$state"
    done < <(list_exit_names)
}
exit_wait_device() {
    local iface i; iface="$(exit_iface "$1")"
    for i in $(seq 1 50); do
        ip link show up "$iface" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}
apply_current_exit() {
    /usr/local/bin/proxy-gateway-apply-exit.sh
}
install_apply_exit_helper() {
    cat > /usr/local/bin/proxy-gateway-apply-exit.sh <<EOF
#!/bin/bash
# Re-apply the currently selected proxy-gateway egress exit.
set -e
MARK="${EXIT_MARK}"
TABLE="${EXIT_TABLE}"
STATE="${CONF_DIR}/current-exit"
EXITS_DIR="${EXITS_DIR}"
WG_DIR="${WG_DIR}"
EOF
    cat >> /usr/local/bin/proxy-gateway-apply-exit.sh <<'EOF'

# Ensure the egress-marking nftables table exists; it may have been wiped by a
# host firewall reload (flush ruleset) since the last apply.
if command -v nft >/dev/null 2>&1 && [[ -f /etc/proxy-gateway/pgw-exit.nft ]]; then
    nft -f /etc/proxy-gateway/pgw-exit.nft 2>/dev/null || true
fi

# Marked traffic consults the dedicated table; an empty table falls through to
# the main table, i.e. direct egress ("local").
ip rule add fwmark "${MARK}" table "${TABLE}" 2>/dev/null || true

exit_iface() {
    local name="$1"
    if [[ "$name" =~ ^[A-Za-z0-9_-]{1,11}$ ]]; then
        echo "pgw-${name}"
    else
        printf 'pgw-%s\n' "$(printf '%s' "$name" | sha256sum | cut -c1-11)"
    fi
}
mihomo_unit() { systemd-escape --template=proxy-gateway-mihomo@.service "$1"; }

current="local"
[[ -f "${STATE}" ]] && current="$(cat "${STATE}" 2>/dev/null || echo local)"

if [[ -z "${current}" || "${current}" == "local" ]]; then
    ip route flush table "${TABLE}" 2>/dev/null || true
    exit 0
fi

iface="$(exit_iface "${current}")"
etype="wireguard"
[[ -f "${EXITS_DIR}/${current}.type" ]] && etype="$(cat "${EXITS_DIR}/${current}.type")"

if ! ip link show "${iface}" >/dev/null 2>&1; then
    case "${etype}" in
        wireguard)
            conf="${WG_DIR}/pgw-${current}.conf"
            runtime_conf="${WG_DIR}/${iface}.conf"
            [[ "${conf}" == "${runtime_conf}" ]] || ln -sf "${conf}" "${runtime_conf}"
            wg-quick up "${iface}" 2>/dev/null || { echo "[!] exit '${current}' (wireguard) failed to start"; exit 1; } ;;
        shadowsocks|vmess|trojan|vless|hysteria|hysteria2|tuic|anytls|shadowtls|socks|http|router) systemctl start "$(mihomo_unit "${current}")" 2>/dev/null || { echo "[!] exit '${current}' (${etype}) failed to start"; exit 1; } ;;
    esac
fi

for _ in $(seq 1 50); do ip link show up "${iface}" >/dev/null 2>&1 && break; sleep 0.1; done
ip link show up "${iface}" >/dev/null 2>&1 || { echo "[!] exit '${current}' (${etype}) device is not up"; exit 1; }
ip route replace default dev "${iface}" table "${TABLE}"
echo "[OK] egress exit active: ${current} (${etype}, dev ${iface})"
EOF
    chmod +x /usr/local/bin/proxy-gateway-apply-exit.sh
}
setup_exit_switching() {
    info "Setting up switchable egress (exit) routing..."
    ensure_proxy_user
    mkdir -p "${WG_DIR}"; chmod 700 "${WG_DIR}"
    mkdir -p "${EXITS_DIR}"; chmod 700 "${EXITS_DIR}"
    mkdir -p "${CONF_DIR}"
    [[ -f "${CONF_DIR}/current-exit" ]] || echo "local" > "${CONF_DIR}/current-exit"
    mkdir -p "${BASE_DIR}/bin"
    [[ -f "${LIB_DIR}/mihomo-exit-config.py" ]] && \
        install -m 0755 "${LIB_DIR}/mihomo-exit-config.py" "${MIHOMO_CFG_GEN}"
    [[ -f "${LIB_DIR}/mihomo-router-config.py" ]] && \
        install -m 0755 "${LIB_DIR}/mihomo-router-config.py" "${MIHOMO_ROUTER_GEN}"
    [[ -f "${LIB_DIR}/rules-import.py" ]] && \
        install -m 0755 "${LIB_DIR}/rules-import.py" "${RULES_IMPORT}"
    mkdir -p "$(dirname "${RULES_DEFAULT}")"
    [[ -f "${LIB_DIR}/rules-default.conf" ]] && \
        install -m 0644 "${LIB_DIR}/rules-default.conf" "${RULES_DEFAULT}"
    local existing_exit
    while IFS= read -r existing_exit; do
        ensure_mihomo_exit_iface "$existing_exit"
    done < <(list_exit_names)
    install_mihomo_unit
    migrate_singbox_exits
    install_apply_exit_helper
    cat > /etc/systemd/system/proxy-gateway-exit.service <<'EOF'
[Unit]
Description=Proxy Gateway egress exit selector
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/proxy-gateway-apply-exit.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable proxy-gateway-exit.service 2>/dev/null || true
    /usr/local/bin/proxy-gateway-apply-exit.sh >/dev/null 2>&1 || true
    ok "Egress exit routing ready (default: local / direct)"
}
list_exits() {
    local cur="local"
    [[ -f "${CONF_DIR}/current-exit" ]] && cur="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    echo "=========================================="
    echo "      Egress Exits"
    echo "=========================================="
    printf '  %-12s %-11s %s%s\n' "local" "direct" "from this server" "$([[ "$cur" == "local" ]] && echo ' *')"
    local n t detail link
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        t="$(exit_type "$n")"
        case "$t" in
            wireguard)
                detail="$(grep -i '^[[:space:]]*Endpoint' "$(exit_conf_path "$n")" 2>/dev/null | head -n1 | sed 's/.*=[[:space:]]*//')" ;;
            shadowsocks|vmess|trojan|vless|hysteria|hysteria2|tuic|anytls|shadowtls|socks|http)
                detail="$(grep -oE '"server": *"[^"]+"|"port": *[0-9]+' "$(exit_mihomo_conf "$n")" 2>/dev/null | head -n2 | sed 's/.*: *//; s/"//g' | paste -sd: -)" ;;
            router)
                detail="rules:$(grep -cvE '^[[:space:]]*(#|;|$)' "${RULES_FILE}" 2>/dev/null || echo 0)" ;;
            *) detail="?" ;;
        esac
        link="down"; ip link show "$(exit_iface "$n")" >/dev/null 2>&1 && link="up"
        printf '  %-12s %-11s %s link=%s%s\n' "$n" "${t:-?}" "${detail:-?}" "$link" "$([[ "$cur" == "$n" ]] && echo ' *')"
    done < <(list_exit_names)
    echo "=========================================="
    echo "  ( * = active )  switch with: $0 --set-exit <name|local>"
}
add_exit() {
    local name="${1:-}" src="${2:-}"
    [[ -z "$name" ]] && { err "Usage: $0 --add-exit <name> [wg.conf | proxy URI]"; exit 1; }
    python3 - "$name" <<'PYNAME' || { err "Exit name must be 1-16 letters/digits/Chinese characters/_/-"; exit 1; }
import re, sys
name = sys.argv[1]
if name in ("local", "smart") or not re.match(r"^[\w\-\u4e00-\u9fff]{1,16}$", name, re.UNICODE):
    raise SystemExit(1)
PYNAME
    [[ "$name" == "local" || "$name" == "smart" ]] && { err "'$name' is a reserved exit name (smart = rule-based router; use --set-rules)"; exit 1; }
    exit_exists "$name" && { err "Exit '$name' already exists"; exit 1; }
    mkdir -p "${WG_DIR}"; chmod 700 "${WG_DIR}"
    mkdir -p "${EXITS_DIR}"; chmod 700 "${EXITS_DIR}"
    local tmp; tmp="$(mktemp)"
    if [[ -n "$src" && -f "$src" ]]; then
        cat "$src" > "$tmp"
    elif [[ -n "$src" ]]; then
        printf '%s\n' "$src" > "$tmp"
    elif [[ ! -t 0 ]]; then
        cat > "$tmp"
    else
        echo "Paste a WireGuard config OR a supported proxy URI for '$name', end with Ctrl-D:"
        cat > "$tmp"
    fi
    local uri type px_user px_pass px_rdns
    uri="$(grep -iE '^[[:space:]]*(ss|vmess|trojan|vless|hysteria2|hy2|tuic|anytls|socks5h|socks5|socks|http|https)://' "$tmp" | head -n1 | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [[ -n "$uri" ]]; then
        local uri_lc; uri_lc="$(printf '%s' "$uri" | tr '[:upper:]' '[:lower:]')"
        case "$uri_lc" in
            ss://*)                 type=shadowsocks ;;
            vmess://*)              type=vmess ;;
            trojan://*)             type=trojan ;;
            vless://*)              type=vless ;;
            hysteria2://*|hy2://*)  type=hysteria2 ;;
            tuic://*)               type=tuic ;;
            anytls://*)             type=anytls ;;
            socks5h://*|socks5://*|socks://*) type=socks ;;
            http://*|https://*)     type=http ;;
        esac
        px_user="$(grep -iE '^[[:space:]]*(user|username)[[:space:]]*[:=]' "$tmp" | head -n1 | sed -E 's/^[[:space:]]*[^:=]+[:=][[:space:]]*//' | tr -d '\r' || true)"
        px_pass="$(grep -iE '^[[:space:]]*(pass|password)[[:space:]]*[:=]' "$tmp" | head -n1 | sed -E 's/^[[:space:]]*[^:=]+[:=][[:space:]]*//' | tr -d '\r' || true)"
        px_rdns="$(grep -iE '^[[:space:]]*remote-?dns[[:space:]]*[:=]' "$tmp" | head -n1 | sed -E 's/^[[:space:]]*[^:=]+[:=][[:space:]]*//' | tr -d '\r' || true)"
        rm -f "$tmp"
        [[ -f "${MIHOMO_CFG_GEN}" ]] || { err "Config generator missing: ${MIHOMO_CFG_GEN}"; exit 1; }
        ensure_mihomo || exit 1
        local yaml gen_err
        yaml="$(exit_mihomo_conf "$name")"
        if ! gen_err="$(PGW_USER="$px_user" PGW_PASS="$px_pass" PGW_REMOTE_DNS="$px_rdns" python3 "${MIHOMO_CFG_GEN}" "$name" "$uri" 2>&1 >"${yaml}.tmp")"; then
            err "Failed to parse URI: ${gen_err}"; rm -f "${yaml}.tmp"; exit 1
        fi
        install_mihomo_unit
        mkdir -p "${CONF_DIR}/mihomo/${name}"
        if ! "${MIHOMO_BIN}" -d "${CONF_DIR}/mihomo/${name}" -t -f "${yaml}.tmp" >/dev/null 2>&1; then
            err "mihomo rejected the generated config:"; "${MIHOMO_BIN}" -d "${CONF_DIR}/mihomo/${name}" -t -f "${yaml}.tmp" 2>&1 | sed 's/^/    /' >&2
            rm -f "${yaml}.tmp"; exit 1
        fi
        install -m 600 "${yaml}.tmp" "${yaml}"; rm -f "${yaml}.tmp"
        printf '%s\n' "$uri" > "${EXITS_DIR}/${name}.uri"
        chmod 600 "${EXITS_DIR}/${name}.uri"
        echo "$type" > "$(exit_type_file "$name")"
        ok "Exit '$name' added (type: $type)"
        info "Activate it with: $0 --set-exit $name"
        return
    fi
    grep -qi '^\[Interface\]' "$tmp" || { err "Not a URI and not a WireGuard config (no proxy URI or [Interface])"; rm -f "$tmp"; exit 1; }
    grep -qi '^\[Peer\]'      "$tmp" || { err "Invalid WireGuard config (missing [Peer])"; rm -f "$tmp"; exit 1; }
    command -v wg-quick >/dev/null 2>&1 || { err "wireguard-tools (wg-quick) is not installed"; rm -f "$tmp"; exit 1; }
    if grep -qi '^[[:space:]]*Table[[:space:]]*=' "$tmp"; then
        sed -i 's/^[[:space:]]*[Tt]able[[:space:]]*=.*/Table = off/' "$tmp"
    else
        sed -i '0,/^\[Interface\]/s//[Interface]\nTable = off/' "$tmp"
    fi
    install -m 600 "$tmp" "$(exit_conf_path "$name")"
    rm -f "$tmp"
    echo wireguard > "$(exit_type_file "$name")"
    ok "Exit '$name' added (type: wireguard)"
    info "Activate it with: $0 --set-exit $name"
}
del_exit() {
    local name="${1:-}"
    [[ -z "$name" ]] && { err "Usage: $0 --del-exit <name>"; exit 1; }
    [[ "$name" == "local" ]] && { err "'local' cannot be removed"; exit 1; }
    exit_exists "$name" || { err "Unknown exit '$name'"; exit 1; }
    local cur="local"
    [[ -f "${CONF_DIR}/current-exit" ]] && cur="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    if [[ "$cur" == "$name" ]]; then
        warn "Exit '$name' is active; switching to 'local' first"
        set_exit local
    fi
    exit_down "$name"
    rm -f "$(exit_conf_path "$name")" "$(exit_mihomo_conf "$name")" \
        "$(exit_type_file "$name")" "${EXITS_DIR}/${name}.uri"
    rm -rf "${CONF_DIR}/mihomo/${name}"
    ok "Exit '$name' removed"
}
rename_exit() {
    local old="${1:-}" new="${2:-}"
    local cur="local" old_active=0 rules_ref=0 policy_ref=0 smart_touched=0 backup_dir=""
    local old_wg old_yaml old_type old_uri old_runtime new_wg new_yaml new_type new_uri new_runtime
    local current_smart=0
    [[ -n "$old" && -n "$new" ]] || { err "Usage: $0 --rename-exit <old> <new>"; exit 1; }
    [[ "$old" == "local" || "$old" == "smart" ]] && { err "'$old' cannot be renamed"; exit 1; }
    [[ "$new" == "local" || "$new" == "smart" ]] && { err "'$new' is a reserved exit name"; exit 1; }
    exit_exists "$old" || { err "Unknown exit '$old'"; exit 1; }
    python3 - "$new" <<'PYNAME' || { err "Exit name must be 1-16 letters/digits/Chinese characters/_/-"; exit 1; }
import re, sys
name = sys.argv[1]
if name in ("local", "smart") or not re.match(r"^[\w\-\u4e00-\u9fff]{1,16}$", name, re.UNICODE):
    raise SystemExit(1)
PYNAME
    exit_exists "$new" && { err "Exit '$new' already exists"; exit 1; }
    mkdir -p "${EXITS_DIR}" "${WG_DIR}" "${CONF_DIR}/mihomo"
    [[ -f "${CONF_DIR}/current-exit" ]] && cur="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    [[ "$cur" == "$old" ]] && old_active=1
    [[ "$cur" == "smart" ]] && current_smart=1
    if [[ -f "${POLICY_MAP}" ]] && awk -F= -v c="$old" '$1==c{found=1} END{exit(found?0:1)}' "${POLICY_MAP}"; then
        err "Cannot safely rename exit '$old': category '$old' already exists in ${POLICY_MAP}"
        exit 1
    fi
    if [[ -f "${RULES_FILE}" ]] && awk -F, -v o="$old" '
        /^[[:space:]]*(#|;|$)/ { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); if ($NF == o) { found=1; exit } }
        END { exit(found?0:1) }
    ' "${RULES_FILE}"; then
        rules_ref=1
        smart_touched=1
    fi
    if [[ -f "${POLICY_MAP}" ]] && awk -F= -v o="$old" '
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 == o) { found=1; exit } }
        END { exit(found?0:1) }
    ' "${POLICY_MAP}"; then
        policy_ref=1
        smart_touched=1
    fi
    old_wg="$(exit_conf_path "$old")"
    old_yaml="$(exit_mihomo_conf "$old")"
    old_type="$(exit_type_file "$old")"
    old_uri="${EXITS_DIR}/${old}.uri"
    old_runtime="${CONF_DIR}/mihomo/${old}"
    new_wg="$(exit_conf_path "$new")"
    new_yaml="$(exit_mihomo_conf "$new")"
    new_type="$(exit_type_file "$new")"
    new_uri="${EXITS_DIR}/${new}.uri"
    new_runtime="${CONF_DIR}/mihomo/${new}"
    backup_dir="$(mktemp -d)"
    [[ -f "$old_wg" ]] && cp -a "$old_wg" "${backup_dir}/old.wg"
    [[ -f "$old_yaml" ]] && cp -a "$old_yaml" "${backup_dir}/old.yaml"
    [[ -f "$old_type" ]] && cp -a "$old_type" "${backup_dir}/old.type"
    [[ -f "$old_uri" ]] && cp -a "$old_uri" "${backup_dir}/old.uri"
    [[ -d "$old_runtime" ]] && cp -a "$old_runtime" "${backup_dir}/old.runtime"
    [[ -f "${RULES_FILE}" ]] && cp -a "${RULES_FILE}" "${backup_dir}/rules.conf"
    [[ -f "${POLICY_MAP}" ]] && cp -a "${POLICY_MAP}" "${backup_dir}/policy-map.conf"
    rollback_rename_exit() {
        local reason="$1"
        local smart_ready=1
        (set_exit local) >/dev/null 2>&1 || true
        rm -f "$new_wg" "$new_yaml" "$new_type" "$new_uri"
        rm -rf "$new_runtime"
        [[ -f "${backup_dir}/old.wg" ]] && cp -a "${backup_dir}/old.wg" "$old_wg"
        [[ -f "${backup_dir}/old.yaml" ]] && cp -a "${backup_dir}/old.yaml" "$old_yaml"
        [[ -f "${backup_dir}/old.type" ]] && cp -a "${backup_dir}/old.type" "$old_type"
        [[ -f "${backup_dir}/old.uri" ]] && cp -a "${backup_dir}/old.uri" "$old_uri"
        if [[ -d "${backup_dir}/old.runtime" ]]; then
            rm -rf "$old_runtime"
            cp -a "${backup_dir}/old.runtime" "$old_runtime"
        fi
        if [[ -f "${backup_dir}/rules.conf" ]]; then
            install -m 644 "${backup_dir}/rules.conf" "${RULES_FILE}"
        elif [[ $rules_ref -eq 1 ]]; then
            rm -f "${RULES_FILE}"
        fi
        if [[ -f "${backup_dir}/policy-map.conf" ]]; then
            install -m 644 "${backup_dir}/policy-map.conf" "${POLICY_MAP}"
        elif [[ $policy_ref -eq 1 ]]; then
            rm -f "${POLICY_MAP}"
        fi
        if [[ $smart_touched -eq 1 ]]; then
            (regen_smart) >/dev/null 2>&1 || smart_ready=0
        fi
        if [[ $old_active -eq 1 ]]; then
            (set_exit "$old") >/dev/null 2>&1 || true
        elif [[ $current_smart -eq 1 ]]; then
            if [[ $smart_ready -eq 1 ]] && (set_exit smart) >/dev/null 2>&1; then
                :
            else
                printf '%s\n' local > "${CONF_DIR}/current-exit"
                reason="${reason}; restored files but failed to reactivate smart, left on local"
            fi
        else
            printf '%s\n' "$cur" > "${CONF_DIR}/current-exit"
        fi
        rm -rf "$backup_dir"
        err "$reason"
        exit 1
    }
    if [[ $old_active -eq 1 ]]; then
        if ! (set_exit local) >/dev/null 2>&1; then
            rm -rf "$backup_dir"
            err "Failed to switch active exit '$old' to local before rename"
            exit 1
        fi
    fi
    [[ -f "$old_type" ]] && mv "$old_type" "$new_type"
    [[ -f "$old_wg" ]] && mv "$old_wg" "$new_wg"
    if [[ -f "$old_yaml" ]]; then
        python3 - "$old_yaml" "$new_yaml" "$new" <<'PYYAML' \
            || rollback_rename_exit "Failed to rewrite mihomo device for renamed exit '$old'"
import hashlib, json, os, re, sys, tempfile

src, dst, name = sys.argv[1:4]
with open(src, encoding="utf-8") as f:
    config = json.load(f)
if re.fullmatch(r"[A-Za-z0-9_-]{1,11}", name):
    device = "pgw-" + name
else:
    device = "pgw-" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:11]
config.setdefault("tun", {})["device"] = device
directory = os.path.dirname(dst)
fd, tmp = tempfile.mkstemp(prefix=".rename-exit-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, dst)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYYAML
        rm -f "$old_yaml"
    fi
    [[ -f "$old_uri" ]] && mv "$old_uri" "$new_uri"
    [[ -d "$old_runtime" ]] && mv "$old_runtime" "$new_runtime"
    if [[ $rules_ref -eq 1 ]]; then
        awk -F, -v o="$old" -v n="$new" '
            BEGIN { OFS="," }
            /^[[:space:]]*(#|;|$)/ { print; next }
            { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); if ($NF == o) $NF = n; print }
        ' "${RULES_FILE}" > "${RULES_FILE}.tmp" || rollback_rename_exit "Failed to rewrite rules for renamed exit '$old'"
        install -m 644 "${RULES_FILE}.tmp" "${RULES_FILE}" \
            || rollback_rename_exit "Failed to install rewritten rules for renamed exit '$old'"
        rm -f "${RULES_FILE}.tmp"
    fi
    if [[ $policy_ref -eq 1 ]]; then
        awk -F= -v o="$old" -v n="$new" '
            BEGIN { OFS="=" }
            { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 == o) $2 = n; print }
        ' "${POLICY_MAP}" > "${POLICY_MAP}.tmp" || rollback_rename_exit "Failed to rewrite policy map for renamed exit '$old'"
        install -m 644 "${POLICY_MAP}.tmp" "${POLICY_MAP}" \
            || rollback_rename_exit "Failed to install rewritten policy map for renamed exit '$old'"
        rm -f "${POLICY_MAP}.tmp"
    fi
    if [[ $smart_touched -eq 1 ]]; then
        if ! (regen_smart) >/dev/null 2>&1; then
            rollback_rename_exit "Rename rejected; previous exit restored"
        fi
    fi
    if [[ $old_active -eq 1 ]]; then
        if ! (set_exit "$new") >/dev/null 2>&1; then
            rollback_rename_exit "Renamed exit but failed to activate '$new'; previous exit restored"
        fi
    fi
    rm -rf "$backup_dir"
    ok "Exit '$old' renamed to '$new'"
}
set_exit() {
    local name="${1:-}"
    [[ -z "$name" ]] && { err "Usage: $0 --set-exit <name|local>"; exit 1; }
    ensure_proxy_user
    [[ -x /usr/local/bin/proxy-gateway-apply-exit.sh ]] || setup_exit_switching >/dev/null
    ip rule add fwmark "${EXIT_MARK}" table "${EXIT_TABLE}" 2>/dev/null || true
    local prev="local"
    [[ -f "${CONF_DIR}/current-exit" ]] && prev="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    if [[ "$name" == "local" ]]; then
        ip route flush table "${EXIT_TABLE}" 2>/dev/null || true
        echo "local" > "${CONF_DIR}/current-exit"
        [[ "$prev" != "local" && "$prev" != "$name" ]] && exit_down "$prev"
        ok "Egress switched to: local (direct from this server)"
        return
    fi
    if ! exit_exists "$name"; then
        if [[ "$name" == "smart" ]]; then
            # smart is not a traditional exit; it is generated by regen_smart
            # from the rules file. Rebuild it now if rules exist.
            if [[ -f "${RULES_FILE}" ]]; then
                info "Rebuilding smart router config before switching..."
                regen_smart || { err "Failed to rebuild smart config"; exit 1; }
            else
                err "No routing rules configured. Add rules first: $0 --set-rules <file>"
                exit 1
            fi
        else
            err "Unknown exit '$name'. Add it first: $0 --add-exit $name <conf|uri>"
            exit 1
        fi
    fi
    local iface; iface="$(exit_iface "$name")"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        exit_up "$name" || { err "Failed to bring up exit '$name'"; exit 1; }
    fi
    exit_wait_device "$name" || { err "Device $iface did not appear; check the exit's service/logs"; exit 1; }
    ip route replace default dev "$iface" table "${EXIT_TABLE}"
    echo "$name" > "${CONF_DIR}/current-exit"
    [[ "$prev" != "local" && "$prev" != "$name" ]] && exit_down "$prev"
    ok "Egress switched to: $name ($(exit_type "$name"), dev $iface)"
    preflight_exit "$name"
    info "Verify the public exit IP with:"
    info "  curl --interface ${iface} -4 -s https://api.ipify.org; echo"
}
regen_smart() {
    [[ -f "${RULES_FILE}" ]] || { err "No rules yet. Use --set-rules or --import-rules first."; exit 1; }
    [[ -f "${MIHOMO_ROUTER_GEN}" ]] || { err "Router generator missing: ${MIHOMO_ROUTER_GEN}"; exit 1; }
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"; chmod 700 "${EXITS_DIR}"
    [[ -x /usr/local/bin/proxy-gateway-apply-exit.sh ]] || setup_exit_switching >/dev/null
    ensure_mihomo || exit 1
    install_mihomo_unit
    info "Building smart mihomo config and rule providers..."
    local eff; eff="$(mktemp)"
    [[ -f "${RULES_DEFAULT}" ]] && cat "${RULES_DEFAULT}" >> "$eff"
    cat "${RULES_FILE}" >> "$eff"
    local yaml gen_err; yaml="$(exit_mihomo_conf smart)"
    if ! gen_err="$(EXITS_DIR="${EXITS_DIR}" WG_DIR="${WG_DIR}" PGW_RULESET_CACHE="${RULESET_CACHE}" \
                    PGW_POLICY_MAP="${POLICY_MAP}" \
                    python3 "${MIHOMO_ROUTER_GEN}" "$eff" 2>&1 >"${yaml}.tmp")"; then
        err "Rules error: ${gen_err}"; rm -f "${yaml}.tmp" "$eff"; exit 1
    fi
    rm -f "$eff"
    mkdir -p "${CONF_DIR}/mihomo/smart"
    if ! "${MIHOMO_BIN}" -d "${CONF_DIR}/mihomo/smart" -t -f "${yaml}.tmp" >/dev/null 2>&1; then
        err "mihomo rejected the generated router config:"
        "${MIHOMO_BIN}" -d "${CONF_DIR}/mihomo/smart" -t -f "${yaml}.tmp" 2>&1 | sed 's/^/    /' >&2
        rm -f "${yaml}.tmp"; exit 1
    fi
    local cur="local" type_file backup_dir had_yaml=0 had_type=0
    [[ -f "${CONF_DIR}/current-exit" ]] && cur="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    type_file="$(exit_type_file smart)"
    backup_dir="$(mktemp -d)"
    if [[ -f "$yaml" ]]; then
        cp -a "$yaml" "${backup_dir}/smart.yaml"
        had_yaml=1
    fi
    if [[ -f "$type_file" ]]; then
        cp -a "$type_file" "${backup_dir}/smart.type"
        had_type=1
    fi
    install -m 600 "${yaml}.tmp" "${yaml}"; rm -f "${yaml}.tmp"
    echo router > "$type_file"
    if [[ "$cur" == "smart" ]]; then
        local apply_ok=1
        systemctl restart "proxy-gateway-mihomo@smart.service" >/dev/null 2>&1 || apply_ok=0
        [[ $apply_ok -eq 1 ]] && systemctl is-active --quiet "proxy-gateway-mihomo@smart.service" || apply_ok=0
        [[ $apply_ok -eq 1 ]] && exit_wait_device smart || apply_ok=0
        [[ $apply_ok -eq 1 ]] && apply_current_exit >/dev/null 2>&1 || apply_ok=0
        if [[ $apply_ok -ne 1 ]]; then
            systemctl stop "proxy-gateway-mihomo@smart.service" >/dev/null 2>&1 || true
            if [[ $had_yaml -eq 1 ]]; then
                install -m 600 "${backup_dir}/smart.yaml" "$yaml"
            else
                rm -f "$yaml"
            fi
            if [[ $had_type -eq 1 ]]; then
                install -m 600 "${backup_dir}/smart.type" "$type_file"
            else
                rm -f "$type_file"
            fi
            local rollback_ok=1
            if [[ $had_yaml -eq 1 ]]; then
                systemctl restart "proxy-gateway-mihomo@smart.service" >/dev/null 2>&1 || rollback_ok=0
                [[ $rollback_ok -eq 1 ]] && systemctl is-active --quiet "proxy-gateway-mihomo@smart.service" || rollback_ok=0
                [[ $rollback_ok -eq 1 ]] && exit_wait_device smart || rollback_ok=0
                [[ $rollback_ok -eq 1 ]] && apply_current_exit >/dev/null 2>&1 || rollback_ok=0
            fi
            rm -rf "$backup_dir"
            if [[ $rollback_ok -eq 1 && $had_yaml -eq 1 ]]; then
                err "New smart config failed to start; previous working config restored"
            else
                err "New smart config failed to start; rollback could not reactivate the previous config"
            fi
            return 1
        fi
        ok "Reloaded and verified the active smart router."
    else
        info "Activate smart routing with: $0 --set-exit smart"
    fi
    rm -rf "$backup_dir"
    local n; n="$(grep -cvE '^[[:space:]]*(#|;|$)' "${RULES_FILE}" 2>/dev/null || echo 0)"
    ok "Smart router rebuilt (${n} rules)."
}
set_rules() {
    local src="${1:-}"
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"
    local tmp; tmp="$(mktemp)"
    if [[ -n "$src" && -f "$src" ]]; then
        cat "$src" > "$tmp"
    elif [[ -n "$src" ]]; then
        err "Rules file not found: $src"; rm -f "$tmp"; exit 1
    elif [[ ! -t 0 ]]; then
        cat > "$tmp"
    else
        echo "Paste routing rules for the 'smart' exit, end with Ctrl-D:"
        cat > "$tmp"
    fi
    local old old_policy; old="$(mktemp)"; old_policy="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old"
    else
        : > "$old"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        cp -a "${POLICY_MAP}" "$old_policy"
    else
        : > "$old_policy"
    fi
    install -m 644 "$tmp" "${RULES_FILE}"; rm -f "$tmp"
    init_policy_map
    if ! (regen_smart); then
        install -m 644 "$old" "${RULES_FILE}"
        install -m 644 "$old_policy" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old" "$old_policy"
        err "Rules rejected; previous rules restored"
        exit 1
    fi
    rm -f "$old" "$old_policy"
}
add_rule() {
    local rule="${1:-}" old tmp
    [[ -n "$rule" ]] || { err "Usage: $0 --add-rule <TYPE,value,policy>"; exit 1; }
    [[ "$rule" != *$'\n'* && "$rule" != *$'\r'* ]] || { err "A rule must be one line"; exit 1; }
    mkdir -p "$(dirname "${RULES_FILE}")"
    old="$(mktemp)"; tmp="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old"
    else
        : > "$old"
    fi
    { printf '%s\n' "$rule"; cat "$old"; } > "$tmp"
    install -m 644 "$tmp" "${RULES_FILE}"
    if ! (regen_smart); then
        install -m 644 "$old" "${RULES_FILE}"
        init_policy_map
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old" "$tmp"
        err "Rule rejected; previous rules restored"
        exit 1
    fi
    rm -f "$old" "$tmp"
}
add_ruleset() {
    local source="${1:-}" policy="${2:-}"
    [[ -n "$source" && -n "$policy" ]] || { err "Usage: $0 --add-ruleset <url|path> <exit|category|direct|block>"; exit 1; }
    case "$source" in
        http://*|https://*) ;;
        /*) [[ -f "$source" ]] || { err "Rule-set file not found: $source"; exit 1; } ;;
        *) err "Rule-set source must be an http(s) URL or absolute local path"; exit 1 ;;
    esac
    add_rule "RULE-SET,${source},${policy}"
}
import_rules() {
    local src="${1:-}"
    [[ -n "$src" && -f "$src" ]] || { err "Usage: $0 --import-rules <rule-list-file>"; exit 1; }
    [[ -f "${RULES_IMPORT}" ]] || { err "rule converter missing: ${RULES_IMPORT}"; exit 1; }
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"
    local keep="${PGW_KEEP_CATEGORIES:-}"
    [[ -z "$keep" && -f "${KEEP_FILE}" ]] && keep="$(cat "${KEEP_FILE}" 2>/dev/null)"
    if [[ -n "$keep" ]]; then
        mkdir -p "$(dirname "${KEEP_FILE}")"; printf '%s' "$keep" > "${KEEP_FILE}"
        info "Simplifying categories — keeping: ${keep} (others -> Proxy/direct/block)"
    fi
    local direct="${PGW_DIRECT_CATEGORIES:-}"
    [[ -z "$direct" && -f "${DIRECT_FILE}" ]] && direct="$(cat "${DIRECT_FILE}" 2>/dev/null)"
    if [[ -n "$direct" ]]; then
        mkdir -p "$(dirname "${DIRECT_FILE}")"; printf '%s' "$direct" > "${DIRECT_FILE}"
        info "Forcing to direct: ${direct}"
    fi
    local old_rules old_policy
    old_rules="$(mktemp)"; old_policy="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old_rules"
    else
        : > "$old_rules"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        cp -a "${POLICY_MAP}" "$old_policy"
    else
        : > "$old_policy"
    fi
    info "Converting rule list..."
    PGW_KEEP_CATEGORIES="$keep" PGW_DIRECT_CATEGORIES="$direct" python3 "${RULES_IMPORT}" "$src" \
        2>/tmp/pgw-import.err >"${RULES_FILE}.tmp" || true
    if [[ ! -s "${RULES_FILE}.tmp" ]]; then
        err "Conversion produced no rules:"; sed 's/^/    /' /tmp/pgw-import.err >&2; rm -f "${RULES_FILE}.tmp" "$old_rules" "$old_policy"; exit 1
    fi
    install -m 644 "${RULES_FILE}.tmp" "${RULES_FILE}"; rm -f "${RULES_FILE}.tmp"
    grep -E '^(converted|CATEGORIES)' /tmp/pgw-import.err | sed 's/^/[INFO] /'
    init_policy_map
    info "Categories were seeded in ${POLICY_MAP} (edit on the bot or with --set-policy)."
    if ! (regen_smart); then
        install -m 644 "$old_rules" "${RULES_FILE}"
        install -m 644 "$old_policy" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old_rules" "$old_policy"
        err "Imported rules rejected; previous rules and policy restored"
        exit 1
    fi
    rm -f "$old_rules" "$old_policy"
}
init_policy_map() {
    mkdir -p "$(dirname "${POLICY_MAP}")"
    touch "${POLICY_MAP}"
    local def; def="$(list_exit_names | head -n1)"; [[ -z "$def" ]] && def="direct"
    local cat low target existing tmp; tmp="$(mktemp)"
    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        low="$(printf '%s' "$cat" | tr '[:upper:]' '[:lower:]')"
        case "$low" in direct|dir|block|reject|direct-out) continue ;; esac
        existing="$(awk -F= -v c="$cat" '$1==c{print $2; exit}' "${POLICY_MAP}")"
        if [[ -n "$existing" ]]; then
            target="$existing"
        else
            case "$low" in
                *reject*|*advert*|*hijack*|*privacy*|*广告*) target="block" ;;
                *) target="$def" ;;
            esac
        fi
        printf '%s=%s\n' "$cat" "$target" >> "$tmp"
    done < <(cat "${RULES_DEFAULT}" "${RULES_FILE}" 2>/dev/null | grep -vE '^[[:space:]]*(#|;|$)' | awk -F, '{print $NF}' | sort -u)
    sort -u "$tmp" > "${POLICY_MAP}"; rm -f "$tmp"
}
set_policy() {
    local cat="${1:-}" target="${2:-}" old
    [[ -z "$cat" || -z "$target" ]] && { err "Usage: $0 --set-policy <category> <exit|direct|block>"; exit 1; }
    case "$target" in
        direct|block) ;;
        *) exit_exists "$target" || { err "Unknown target '$target' (use an exit name, direct, or block)"; exit 1; } ;;
    esac
    mkdir -p "$(dirname "${POLICY_MAP}")"; touch "${POLICY_MAP}"
    old="$(mktemp)"; cp -a "${POLICY_MAP}" "$old"
    grep -vF "${cat}=" "${POLICY_MAP}" > "${POLICY_MAP}.tmp" 2>/dev/null || true
    mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    printf '%s=%s\n' "$cat" "$target" >> "${POLICY_MAP}"
    if ! (regen_smart); then
        install -m 644 "$old" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old"
        err "Policy rejected; previous policy restored"
        exit 1
    fi
    rm -f "$old"
    ok "Mapped category '$cat' -> $target"
}
show_policy() {
    if [[ -s "${POLICY_MAP}" ]]; then
        sort "${POLICY_MAP}"
    else
        info "No policy map yet. Import rules first: $0 --import-rules <file>"
    fi
}
del_policy() {
    local cat="${1:-}"
    [[ -z "$cat" ]] && { err "Usage: $0 --del-policy <category>"; exit 1; }
    [[ -f "${POLICY_MAP}" ]] || { err "No policy map yet."; exit 1; }
    awk -F= -v c="$cat" '$1!=c' "${POLICY_MAP}" > "${POLICY_MAP}.tmp" && mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    ok "Removed rule group '$cat'"
    regen_smart
}
rename_policy() {
    local old="${1:-}" new="${2:-}" old_rules old_map
    [[ -z "$old" || -z "$new" ]] && { err "Usage: $0 --rename-policy <old> <new>"; exit 1; }
    [[ "$new" =~ ^[A-Za-z0-9_-]+$ || "$new" =~ [^[:ascii:]] ]] || { err "Invalid new name"; exit 1; }
    old_rules="$(mktemp)"; old_map="$(mktemp)"
    if [[ -f "${RULES_FILE}" ]]; then
        cp -a "${RULES_FILE}" "$old_rules"
    else
        : > "$old_rules"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        cp -a "${POLICY_MAP}" "$old_map"
    else
        : > "$old_map"
    fi
    if [[ -f "${POLICY_MAP}" ]]; then
        awk -F= -v o="$old" -v n="$new" 'BEGIN{OFS="="} $1==o{$1=n} {print}' "${POLICY_MAP}" > "${POLICY_MAP}.tmp" \
            && mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    fi
    if [[ -f "${RULES_FILE}" ]]; then
        awk -v o="$old" -v n="$new" '
            /^[[:space:]]*(#|;|$)/ { print; next }
            { k=split($0,a,","); if(a[k]==o){ a[k]=n; line=a[1]; for(i=2;i<=k;i++) line=line","a[i]; print line } else print $0 }
        ' "${RULES_FILE}" > "${RULES_FILE}.tmp" && mv "${RULES_FILE}.tmp" "${RULES_FILE}"
    fi
    if ! (regen_smart); then
        install -m 644 "$old_rules" "${RULES_FILE}"
        install -m 644 "$old_map" "${POLICY_MAP}"
        (regen_smart) >/dev/null 2>&1 || true
        rm -f "$old_rules" "$old_map"
        err "Rename rejected; previous rules and policy restored"
        exit 1
    fi
    rm -f "$old_rules" "$old_map"
    ok "Renamed rule group '$old' -> '$new'"
}
proxy_domain() {
    local domain="${1:-}" target="${2:-}"
    [[ -z "$domain" || -z "$target" ]] && { err "Usage: $0 --proxy-domain <domain> <exit|direct|block>"; exit 1; }
    [[ "$domain" =~ ^[a-z0-9.-]+$ && "$domain" == *.* ]] || { err "Invalid domain"; exit 1; }
    case "$target" in
        direct|block) ;;
        *) exit_exists "$target" || { err "Unknown target '$target' (exit name / direct / block)"; exit 1; } ;;
    esac
    mkdir -p "${EXITS_DIR}"; touch "${RULES_FILE}"
    local esc="${domain//./\\.}" rule="DOMAIN-SUFFIX,${domain},${target}"
    grep -vE "^DOMAIN-SUFFIX,${esc}," "${RULES_FILE}" > "${RULES_FILE}.tmp" 2>/dev/null || true
    { echo "$rule"; cat "${RULES_FILE}.tmp"; } > "${RULES_FILE}"; rm -f "${RULES_FILE}.tmp"
    local extra="/etc/mosdns/gfwlist-extra-local.txt"
    mkdir -p /etc/mosdns; touch "$extra"
    if [[ "$target" == "direct" ]]; then
        grep -vxF "$domain" "$extra" > "$extra.tmp" 2>/dev/null || true; mv "$extra.tmp" "$extra"
    else
        grep -qxF "$domain" "$extra" || echo "$domain" >> "$extra"
    fi
    /usr/local/bin/update-mosdns-rules.sh >/dev/null
    ok "Domain '${domain}' -> ${target}  (hijack: $([[ "$target" == direct ]] && echo off || echo on))"
    regen_smart
}
show_rules() {
    if [[ -f "${RULES_FILE}" ]]; then
        cat "${RULES_FILE}"
    else
        info "No routing rules set. Add them with: $0 --set-rules <file>"
    fi
}
setup_tgbot() {
    local token="${TG_BOT_TOKEN:-}"
    local ids="${TG_ADMIN_IDS:-}"
    if [[ -z "$token" && -t 0 ]]; then
        echo ""
        info "可选：配置 Telegram 控制 Bot（直接在 Telegram 上运维）"
        read -r -p "Telegram Bot Token (留空跳过): " token
    fi
    if [[ -z "$token" ]]; then
        info "未提供 Telegram Bot Token，跳过 tgbot。以后可运行: $0 --setup-tgbot"
        return 0
    fi
    if [[ -z "$ids" && -t 0 ]]; then
        read -r -p "授权的 Telegram 数字 ID（逗号分隔，可留空，稍后用 /id 获取再填）: " ids
    fi
    ids="$(printf '%s' "$ids" | tr ', ' '\n' | grep -E '^[0-9]+$' | paste -sd ',' - 2>/dev/null || true)"
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    info "Installing Telegram control bot..."
    mkdir -p "${BASE_DIR}/bin"
    if [[ ! -f "${LIB_DIR}/tgbot.py" ]]; then
        err "tgbot.py not found in ${LIB_DIR}"
        return 1
    fi
    install -m 0755 "${LIB_DIR}/tgbot.py" "${BASE_DIR}/bin/tgbot.py"
    install -m 0755 "${SCRIPT_PATH}" "${BASE_DIR}/bin/proxy-gateway-ctl"
    mkdir -p "${CONF_DIR}"
    cat > "${CONF_DIR}/tgbot.env" <<EOF
TG_BOT_TOKEN=${token}
TG_ADMIN_IDS=${ids}
MGMT=${BASE_DIR}/bin/proxy-gateway-ctl
EOF
    chmod 600 "${CONF_DIR}/tgbot.env"
    cat > /etc/systemd/system/proxy-gateway-tgbot.service <<EOF
[Unit]
Description=Proxy Gateway Telegram control bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONF_DIR}/tgbot.env
ExecStart=${py} ${BASE_DIR}/bin/tgbot.py
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now proxy-gateway-tgbot.service
    if [[ -z "$ids" ]]; then
        warn "尚未设置授权 ID。给 Bot 发送 /id 获取数字 ID，填入 ${CONF_DIR}/tgbot.env 的 TG_ADMIN_IDS，然后:"
        warn "  systemctl restart proxy-gateway-tgbot"
    fi
    ok "Telegram bot 已安装。在 Telegram 给你的 Bot 发送 /start 开始操作。"
}
apply_lowmem_go_limits() {
    local d
    for svc in quic-proxy mosdns; do
        d="/etc/systemd/system/${svc}.service.d"
        if [[ "${LOWMEM:-0}" == "1" ]]; then
            mkdir -p "$d"
            cat > "$d/lowmem.conf" <<'EOF'
[Service]
Environment=GOGC=50 GOMEMLIMIT=64MiB
EOF
        else
            rm -f "$d/lowmem.conf" 2>/dev/null || true
        fi
    done
    systemctl daemon-reload
}
start_services() {
    info "Starting services..."
    systemctl restart mosdns || { err "mosdns failed to start"; journalctl -u mosdns --no-pager -n 20; exit 1; }
    systemctl restart sniproxy || { err "sniproxy failed to start"; journalctl -u sniproxy --no-pager -n 20; exit 1; }
    systemctl restart wa-shim || { err "wa-shim failed to start"; journalctl -u wa-shim --no-pager -n 20; exit 1; }
    systemctl restart quic-proxy || { err "quic-proxy failed to start"; journalctl -u quic-proxy --no-pager -n 20; exit 1; }
    ok "All services started"
}
setup_schedules() {
    info "Setting up automatic updates..."
    cat > /etc/systemd/system/update-mosdns-rules.timer <<'EOF'
[Unit]
Description=Weekly mosdns rules update

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/update-mosdns-rules.service <<'EOF'
[Unit]
Description=Update mosdns GFWList/ChinaList rules

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-mosdns-rules.sh
EOF
    systemctl daemon-reload
    systemctl enable --now update-mosdns-rules.timer
    install_certbot_firewall_hooks
    systemctl enable --now certbot.timer 2>/dev/null || true
    ok "Schedules configured (rules: weekly, cert: auto)"
}
show_status() {
    echo "=========================================="
    echo "      Proxy Gateway Status"
    echo "=========================================="
    for svc in mosdns sniproxy wa-shim quic-proxy; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        if [[ "$status" == "active" ]]; then
            echo -e "$svc: ${GREEN}running${NC}"
        else
            echo -e "$svc: ${RED}$status${NC}"
        fi
    done
    ios_status=$(systemctl is-active proxy-gateway-ios-profile.socket 2>/dev/null || echo "unknown")
    if [[ "$ios_status" == "active" ]]; then
        echo -e "proxy-gateway-ios-profile.socket: ${GREEN}listening${NC}"
    else
        echo -e "proxy-gateway-ios-profile.socket: ${RED}$ios_status${NC}"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^proxy-gateway-tgbot\.service'; then
        tg_status=$(systemctl is-active proxy-gateway-tgbot 2>/dev/null || echo "unknown")
        echo -e "proxy-gateway-tgbot: $([[ "$tg_status" == active ]] && echo "${GREEN}running${NC}" || echo "${RED}$tg_status${NC}")"
    fi
    echo ""
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        echo "Domain: $(cat "${CONF_DIR}/.domain")"
    fi
    echo "Public IP: ${PUBLIC_IP:-N/A}"
    local cur_exit="local"
    [[ -f "${CONF_DIR}/current-exit" ]] && cur_exit="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    echo "Egress exit: ${cur_exit}"
    if [[ -f /etc/mosdns/.cache_size ]]; then
        local cs; cs="$(cat /etc/mosdns/.cache_size 2>/dev/null || echo '?')"
        echo "Mem profile: $([[ "$cs" -le 50000 ]] 2>/dev/null && echo low-memory || echo standard) (mosdns cache=${cs})"
    fi
    echo "=========================================="
}
do_uninstall() {
    warn "This will remove sniproxy, quic-proxy, mosdns configs, and rules."
    read -r -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled"; exit 0; }
    set_exit local 2>/dev/null || true
    ip rule del fwmark "${EXIT_MARK}" table "${EXIT_TABLE}" 2>/dev/null || true
    ip route flush table "${EXIT_TABLE}" 2>/dev/null || true
    shopt -s nullglob
    for f in "${WG_DIR}"/pgw-*.conf; do
        wg-quick down "$(basename "$f" .conf)" 2>/dev/null || true
    done
    for f in "${EXITS_DIR}"/*.type; do
        systemctl stop "$(exit_mihomo_unit "$(basename "$f" .type)")" 2>/dev/null || true
        systemctl stop "proxy-gateway-singbox@$(basename "$f" .type).service" 2>/dev/null || true
    done
    shopt -u nullglob
    systemctl stop mosdns dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy proxy-gateway-ios-profile.socket proxy-gateway-ios-profile proxy-gateway-exit proxy-gateway-tgbot 2>/dev/null || true
    systemctl disable mosdns dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy proxy-gateway-ios-profile.socket proxy-gateway-ios-profile proxy-gateway-exit proxy-gateway-tgbot 2>/dev/null || true
    rm -f /etc/systemd/system/{mosdns,sniproxy,wa-shim,quic-proxy,china-dns-race-proxy,proxy-gateway-ios-profile,update-mosdns-rules,proxy-gateway-exit,proxy-gateway-tgbot}.*
    rm -f /etc/systemd/system/proxy-gateway-ios-profile@.service \
        /etc/systemd/system/proxy-gateway-mihomo@.service \
        /etc/systemd/system/proxy-gateway-singbox@.service
    rm -rf /etc/systemd/system/quic-proxy.service.d /etc/systemd/system/mosdns.service.d \
        /etc/systemd/system/dnsdist.service.d /etc/systemd/system/china-dns-race-proxy.service.d
    systemctl daemon-reload
    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/mosdns /etc/dnsdist /usr/local/bin/update-mosdns-rules.sh
    rm -f /usr/local/bin/update-dnsdist-rules.sh /usr/local/bin/mosdns
    rm -f /usr/local/sbin/sniproxy
    rm -f /usr/local/bin/proxy-gateway-apply-exit.sh
    rm -f "${WG_DIR}"/pgw-*.conf
    # Repair the host firewall BEFORE removing /etc/proxy-gateway, otherwise a
    # managed /etc/nftables.conf would keep a dangling include and fail to load
    # on reboot (leaving the host with no firewall). Also clears auto-mode
    # persistence and the managed marker.
    firewall_cleanup_on_uninstall
    rm -rf /etc/proxy-gateway
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    rm -f /etc/sysctl.d/99-proxy-gateway.conf
    rm -f /etc/profile.d/go.sh
    if [[ -f /etc/nftables.conf.pgw-backup ]]; then
        warn "Pre-install firewall backup kept at /etc/nftables.conf.pgw-backup (restore manually if wanted)."
    fi
    userdel "${EXIT_USER}" 2>/dev/null || true
    userdel mosdns 2>/dev/null || true
    warn "SSL certificates in /etc/letsencrypt/live/ are kept. Remove manually if needed."
    if [[ -e /swapfile ]]; then
        warn "Swapfile /swapfile is kept. To remove: swapoff /swapfile && rm -f /swapfile && sed -i '/^\\/swapfile /d' /etc/fstab"
    fi
    ok "Uninstall completed"
}
force_renew_cert() {
    ensure_mosdns_user
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot renew."
        exit 1
    fi
    get_public_ip
    certbot_diagnostics "$DOMAIN"
    if ! command -v certbot >/dev/null 2>&1; then
        err "certbot 不存在，无法签发/续期证书。请重新运行安装脚本安装依赖。"
        exit 1
    fi
    local certbot_cmd=()
    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
            --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
            --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
            --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)
    else
        certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
            --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
            --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)
    fi
    prepare_certbot_standalone
    trap cleanup_certbot_standalone RETURN
    local out retry_out rc
    if out="$("${certbot_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
    printf '%s\n' "$out"
    if [[ $rc -ne 0 ]]; then
        if grep -q "AttributeError" <<<"$out"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
            info "Retrying certificate renewal..."
            if retry_out="$("${certbot_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
            printf '%s\n' "$retry_out"
            if [[ $rc -ne 0 ]]; then
                err "证书续期/签发失败。certbot 最后输出:"
                if [[ -n "$retry_out" ]]; then
                    printf '%s\n' "$retry_out" | tail -n 30 >&2
                else
                    err "certbot 没有输出；请检查端口 80 是否被其他服务占用，以及防火墙是否允许外部访问 80。"
                fi
                exit 1
            fi
        else
            err "证书续期/签发失败。certbot 最后输出:"
            if [[ -n "$out" ]]; then
                printf '%s\n' "$out" | tail -n 30 >&2
            else
                err "certbot 没有输出；请检查端口 80 是否被其他服务占用，以及防火墙是否允许外部访问 80。"
            fi
            exit 1
        fi
    fi
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/mosdns/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/mosdns/certs/privkey.pem
        chown -R mosdns:mosdns /etc/mosdns/certs/
        chmod 600 /etc/mosdns/certs/*.pem
    fi
    if systemctl is-active --quiet mosdns; then
        systemctl restart mosdns && ok "Certificate renewed and mosdns reloaded"
    else
        systemctl start mosdns && ok "Certificate renewed and mosdns started"
    fi
}
regenerate_ios_profile() {
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    elif [[ -f /etc/mosdns/.domain ]]; then
        DOMAIN=$(cat /etc/mosdns/.domain)
    fi
    if [[ -f /etc/mosdns/.public_ip ]]; then
        PUBLIC_IP=$(cat /etc/mosdns/.public_ip)
    else
        get_public_ip
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot generate iOS profile."
        exit 1
    fi
    generate_ios_profile
}
set_dot_domain() {
    local new_domain="${1:-}" resolved="" old_conf_domain="" old_mosdns_domain="" old_cert_basename=""
    [[ -n "$new_domain" ]] || { err "Usage: $0 --set-dot-domain <domain>"; exit 1; }
    if ! is_valid_domain "$new_domain"; then
        err "Invalid domain: '$new_domain'. Provide a fully-qualified domain like dns.example.com"
        exit 1
    fi
    get_public_ip
    info "DNS 解析检查"
    info "域名: $new_domain"
    info "需要的 A 记录值: $PUBLIC_IP"
    resolved=$(resolve_domain_a_records "$new_domain" | paste -sd',' - || true)
    if ! domain_resolves_to_public_ip "$new_domain" "$PUBLIC_IP"; then
        err "$new_domain 当前解析到 ${resolved:-无}，不是本机 $PUBLIC_IP"
        err "请先把 A 记录指向本机公网 IP 后重试。"
        exit 1
    fi
    old_conf_domain=$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)
    old_mosdns_domain=$(cat /etc/mosdns/.domain 2>/dev/null || true)
    old_cert_basename=$(cat "${CONF_DIR}/.cert_basename" 2>/dev/null || true)
    DOMAIN="$new_domain"
    install_cert
    mkdir -p "$CONF_DIR" /etc/mosdns
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
    echo "$DOMAIN" > /etc/mosdns/.domain
    rm -f "${CONF_DIR}/.cert_basename"
    if [[ -f /usr/local/bin/update-mosdns-rules.sh ]]; then
        if ! /usr/local/bin/update-mosdns-rules.sh; then
            restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
            restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
            restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
            /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
            err "mosdns config update failed; DoT domain rolled back"
            exit 1
        fi
    elif ! systemctl restart mosdns; then
        restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
        restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
        restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
        err "mosdns restart failed; DoT domain rolled back"
        exit 1
    fi
    regenerate_ios_profile || warn "iOS profile regeneration failed"
    ok "DoT domain updated: $DOMAIN"
}
force_set_dot_domain() {
    local new_domain="${1:-}" resolved="" old_conf_domain="" old_mosdns_domain="" old_cert_basename=""
    [[ -n "$new_domain" ]] || { err "Usage: $0 --set-dot-domain-force <domain>"; exit 1; }
    if ! is_valid_domain "$new_domain"; then
        err "Invalid domain: '$new_domain'. Provide a fully-qualified domain like dns.example.com"
        exit 1
    fi
    get_public_ip
    resolved=$(resolve_domain_a_records "$new_domain" | paste -sd',' - || true)
    if ! domain_resolves_to_public_ip "$new_domain" "$PUBLIC_IP"; then
        warn "$new_domain 当前解析到 ${resolved:-无}，不是本机 $PUBLIC_IP；按强制模式继续。"
    fi
    old_conf_domain=$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)
    old_mosdns_domain=$(cat /etc/mosdns/.domain 2>/dev/null || true)
    old_cert_basename=$(cat "${CONF_DIR}/.cert_basename" 2>/dev/null || true)
    DOMAIN="$new_domain"
    mkdir -p "$CONF_DIR" /etc/mosdns
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
    echo "$DOMAIN" > /etc/mosdns/.domain
    rm -f "${CONF_DIR}/.cert_basename"
    if [[ -f /usr/local/bin/update-mosdns-rules.sh ]]; then
        if ! /usr/local/bin/update-mosdns-rules.sh; then
            restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
            restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
            restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
            /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
            err "mosdns config update failed; DoT domain rolled back"
            exit 1
        fi
    elif ! systemctl restart mosdns; then
        restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
        restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
        restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
        err "mosdns restart failed; DoT domain rolled back"
        exit 1
    fi
    regenerate_ios_profile || warn "iOS profile regeneration failed"
    warn "DoT domain forcibly updated without issuing a new certificate. Run --renew-cert after fixing certbot/port 80 issues."
    ok "DoT domain forcibly updated: $DOMAIN"
}
set_custom_dns() {
    local remote_dns local_dns backup_dir sniproxy_backup=""
    [[ -n "${1:-}" ]] || { err "Usage: $0 --set-dns <remote-dns> [local-dns]"; exit 1; }
    remote_dns=$(normalize_dns_upstreams "$1")
    local_dns=$(normalize_dns_upstreams "${2:-$(cat /etc/mosdns/.local_dns 2>/dev/null || printf '%s' "${DEFAULT_LOCAL_DNS[*]}")}")
    mkdir -p "$CONF_DIR" /etc/mosdns
    backup_dir=$(mktemp -d)
    for f in \
        "${CONF_DIR}/.remote_dns" \
        "${CONF_DIR}/.local_dns" \
        "${CONF_DIR}/.overseas_dns" \
        "${CONF_DIR}/.overseas_private_dns" \
        "${CONF_DIR}/.overseas_public_dns" \
        "${CONF_DIR}/.sniproxy_dns" \
        "${CONF_DIR}/wa-shim.env" \
        /etc/mosdns/.remote_dns \
        /etc/mosdns/.local_dns \
        /etc/mosdns/.overseas_dns \
        /etc/mosdns/.overseas_private_dns \
        /etc/mosdns/.overseas_public_dns \
        /etc/mosdns/.sniproxy_dns; do
        [[ -f "$f" ]] && cp -a "$f" "${backup_dir}/${f//\//__}"
    done
    if [[ -f /etc/sniproxy.conf ]]; then
        sniproxy_backup="${backup_dir}/sniproxy.conf"
        cp -a /etc/sniproxy.conf "$sniproxy_backup"
    fi
    restore_dns_backup() {
        local f b
        for f in \
            "${CONF_DIR}/.remote_dns" \
            "${CONF_DIR}/.local_dns" \
            "${CONF_DIR}/.overseas_dns" \
            "${CONF_DIR}/.overseas_private_dns" \
            "${CONF_DIR}/.overseas_public_dns" \
            "${CONF_DIR}/.sniproxy_dns" \
            "${CONF_DIR}/wa-shim.env" \
            /etc/mosdns/.remote_dns \
            /etc/mosdns/.local_dns \
            /etc/mosdns/.overseas_dns \
            /etc/mosdns/.overseas_private_dns \
            /etc/mosdns/.overseas_public_dns \
            /etc/mosdns/.sniproxy_dns; do
            b="${backup_dir}/${f//\//__}"
            if [[ -f "$b" ]]; then
                cp -a "$b" "$f"
            else
                rm -f "$f"
            fi
        done
        if [[ -n "$sniproxy_backup" && -f "$sniproxy_backup" ]]; then
            cp -a "$sniproxy_backup" /etc/sniproxy.conf
        fi
    }
    echo "$remote_dns" > "${CONF_DIR}/.remote_dns"
    echo "$local_dns" > "${CONF_DIR}/.local_dns"
    echo "$remote_dns" > "${CONF_DIR}/.overseas_dns"
    echo "$remote_dns" > "${CONF_DIR}/.overseas_private_dns"
    echo "$remote_dns" > "${CONF_DIR}/.overseas_public_dns"
    echo "$remote_dns" > "${CONF_DIR}/.sniproxy_dns"
    echo "$remote_dns" > /etc/mosdns/.remote_dns
    echo "$local_dns" > /etc/mosdns/.local_dns
    echo "$remote_dns" > /etc/mosdns/.overseas_dns
    echo "$remote_dns" > /etc/mosdns/.overseas_private_dns
    echo "$remote_dns" > /etc/mosdns/.overseas_public_dns
    echo "$remote_dns" > /etc/mosdns/.sniproxy_dns
    if [[ -f "${CONF_DIR}/wa-shim.env" ]]; then
        sed -i -E "s#^WA_SHIM_RESOLVER=.*#WA_SHIM_RESOLVER=$(first_plain_dns "$remote_dns"),8.8.8.8#" "${CONF_DIR}/wa-shim.env"
    fi
    if ! rewrite_sniproxy_dns "$remote_dns"; then
        restore_dns_backup
        rm -rf "$backup_dir"
        err "sniproxy config update failed; DNS upstreams rolled back"
        exit 1
    fi
    if [[ -f /usr/local/bin/update-mosdns-rules.sh ]]; then
        if ! /usr/local/bin/update-mosdns-rules.sh; then
            restore_dns_backup
            /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
            rm -rf "$backup_dir"
            err "mosdns config update failed; DNS upstreams rolled back"
            exit 1
        fi
    else
        if ! systemctl restart mosdns; then
            restore_dns_backup
            rm -rf "$backup_dir"
            err "mosdns restart failed; DNS upstreams rolled back"
            exit 1
        fi
    fi
    systemctl restart sniproxy 2>/dev/null || true
    systemctl restart wa-shim 2>/dev/null || true
    rm -rf "$backup_dir"
    ok "DNS upstreams updated"
    echo "Remote DNS: $remote_dns"
    echo "Local DNS: $local_dns"
}
main_install() {
    check_root
    detect_os
    detect_memory_profile
    ensure_swap
    get_public_ip
    echo ""
    echo "=========================================="
    echo "  高性能反代系统一键部署"
    echo "=========================================="
    echo ""
    install_deps
    check_port_53
    generate_domain
    verify_domain_dns
    ensure_mosdns_user
    install_cert
    configure_dns_upstreams
    install_sniproxy
    install_whatsapp_shim
    install_quic_proxy
    install_mosdns
    init_rules
    system_tuning
    setup_firewall
    setup_exit_switching
    generate_ios_profile
    apply_lowmem_go_limits
    start_services
    setup_schedules
    setup_tgbot
    echo ""
    echo "=========================================="
    echo "         部署完成！"
    echo "=========================================="
    echo ""
    echo "DoT 地址:  tls://${DOMAIN}:853"
    echo "TCP 代理:  ${PUBLIC_IP}:80, ${PUBLIC_IP}:443 (sniproxy)"
    echo "UDP 代理:  ${PUBLIC_IP}:443 (quic-proxy)"
    echo "DNS 查询:  ${PUBLIC_IP}:53"
    echo "iOS 描述文件: http://${DOMAIN}:${IOS_PROFILE_PORT}/ios-dot.mobileconfig"
    echo ""
    echo "客户端配置示例 (Android 私人 DNS):"
    echo "  ${DOMAIN}"
    echo "iOS 扫码安装:"
    if [[ -f "${WWW_DIR}/ios-dot.qr.txt" ]]; then
        cat "${WWW_DIR}/ios-dot.qr.txt"
    fi
    echo ""
    echo "出口 (Exit): local (直出，当前服务器公网 IP)"
    echo ""
    echo "管理命令:"
    echo "  $0 --status"
    echo "  $0 --update-rules"
    echo "  $0 --renew-cert"
    echo "  $0 -ios"
    echo "  $0 --list-exits"
    echo "  $0 --add-exit <name> <wg.conf|proxy-uri>"
    echo "  $0 --rename-exit <old> <new>"
    echo "  $0 --set-exit <name|local|smart>"
    echo "  $0 --setup-tgbot                 # 配置/启用 Telegram 控制 Bot"
    echo "  $0 --uninstall"
    echo "=========================================="
}
case "${1:-}" in
    --status)
        get_public_ip 2>/dev/null || true
        show_status
        ;;
    --update-rules)
        /usr/local/bin/update-mosdns-rules.sh
        ;;
    --renew-cert)
        force_renew_cert
        ;;
    --set-dot-domain)
        check_root
        set_dot_domain "${2:-}"
        ;;
    --set-dot-domain-force)
        check_root
        force_set_dot_domain "${2:-}"
        ;;
    --set-dns)
        check_root
        set_custom_dns "${2:-}" "${3:-}" "${4:-}"
        ;;
    --setup-whatsapp)
        check_root
        get_public_ip
        ensure_proxy_user
        install_whatsapp_shim
        systemctl restart sniproxy wa-shim
        ;;
    --list-exits)
        list_exits
        ;;
    --add-exit)
        check_root
        add_exit "${2:-}" "${3:-}"
        ;;
    --rename-exit)
        check_root
        rename_exit "${2:-}" "${3:-}"
        ;;
    --del-exit)
        check_root
        del_exit "${2:-}"
        ;;
    --set-exit)
        check_root
        set_exit "${2:-}"
        ;;
    --set-rules)
        check_root
        set_rules "${2:-}"
        ;;
    --add-rule)
        check_root
        add_rule "${2:-}"
        ;;
    --add-ruleset)
        check_root
        add_ruleset "${2:-}" "${3:-}"
        ;;
    --import-rules)
        check_root
        import_rules "${2:-}"
        ;;
    --set-policy)
        check_root
        set_policy "${2:-}" "${3:-}"
        ;;
    --del-policy)
        check_root
        del_policy "${2:-}"
        ;;
    --rename-policy)
        check_root
        rename_policy "${2:-}" "${3:-}"
        ;;
    --proxy-domain)
        check_root
        proxy_domain "${2:-}" "${3:-}"
        ;;
    --show-policy)
        show_policy
        ;;
    --check-exits)
        check_exits
        ;;
    --show-rules)
        show_rules
        ;;
    --setup-tgbot)
        check_root
        setup_tgbot
        ;;
    --uninstall)
        do_uninstall
        ;;
    -ios)
        regenerate_ios_profile
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        main_install
        ;;
esac
