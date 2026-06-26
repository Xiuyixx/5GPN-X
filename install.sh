#!/usr/bin/env bash
#
# install.sh - High-performance transparent proxy + Smart DNS (DoT) one-click installer
# Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12, CentOS 7/8/9 Stream,
#           Rocky Linux 8/9, AlmaLinux 8/9, RHEL 8/9, Fedora 39+
#

set -euo pipefail

# =============================================================================
# Configurable defaults
# =============================================================================
REPO_URL="https://github.com/Xiuyixx/5GPN-X.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
BASE_DIR="/opt/proxy-gateway"
CONF_DIR="${BASE_DIR}/etc"
LOG_DIR="${BASE_DIR}/log"
SRC_DIR="${BASE_DIR}/src"
WWW_DIR="${BASE_DIR}/www"
IOS_PROFILE_PORT=8111
# Switchable egress ("exit") routing. Proxy outbound traffic runs as EXIT_USER
# and is marked, then policy-routed into the selected WireGuard tunnel.
EXIT_USER="pxout"
EXIT_MARK="0x1"
EXIT_TABLE="100"
WG_DIR="/etc/wireguard"
# Exit types: wireguard (wg-quick) | socks | shadowsocks (sing-box tun2socks).
EXITS_DIR="/etc/proxy-gateway/exits"
RULES_FILE="/etc/proxy-gateway/rules.conf"
POLICY_MAP="/etc/proxy-gateway/policy-map.conf"
KEEP_FILE="/etc/proxy-gateway/keep-categories"
DIRECT_FILE="/etc/proxy-gateway/direct-categories"
RULES_DEFAULT="/etc/proxy-gateway/rules-default.conf"
RULESET_CACHE="/etc/proxy-gateway/rulesets"
SINGBOX_BIN="/opt/proxy-gateway/bin/sing-box"
SINGBOX_CFG_GEN="/opt/proxy-gateway/bin/singbox-exit-config.py"
SINGBOX_ROUTER_GEN="/opt/proxy-gateway/bin/singbox-router-config.py"
RULES_IMPORT="/opt/proxy-gateway/bin/rules-import.py"
SINGBOX_VERSION_DEFAULT="1.10.7"
GFWLIST_URL="https://github.com/gfwlist/gfwlist/raw/master/gfwlist.txt"
CHINALIST_URL="https://github.com/felixonmars/dnsmasq-china-list/raw/master/accelerated-domains.china.conf"
DEFAULT_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_PUBLIC_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8")

bootstrap_from_repo_if_needed() {
    local required=(
        install.sh renew-hook.sh sniproxy.conf quic-proxy.go china-dns-race-proxy.go
        dnsdist.conf.template update-rules.sh ios-http.py tgbot.py rules-import.py
        singbox-exit-config.py singbox-router-config.py rules-default.conf
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

    err "无法自动获取完整源码树。请用 git clone 后再运行 install.sh。"
    exit 1
}

bootstrap_from_repo_if_needed "$@"

# =============================================================================
# Colors
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

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
            warn "Skipping invalid overseas DNS address: $item"
            continue
        fi
        name="${prefix}${order}"
        printf 'newServer({address="%s:53", pool="%s", name="%s", order=%d, useClientSubnet=true})\n' "$item" "$pool" "$name" "$order"
        order=$((order + 1))
    done
}

render_sniproxy_dns_nameservers() {
    local input="${1:-}"
    local dns_list=()
    local item

    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_OVERSEAS_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi

    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid sniproxy DNS address: $item"
            continue
        fi
        printf '    nameserver %s\n' "$item"
    done
}

configure_overseas_dns() {
    local legacy="${OVERSEAS_DNS:-}"
    local private_selected="${PRIVATE_OVERSEAS_DNS:-$legacy}"
    local public_selected="${PUBLIC_OVERSEAS_DNS:-}"
    local sniproxy_selected="${SNIPROXY_DNS:-}"

    if [[ -z "$private_selected" && -t 0 ]]; then
        echo ""
        read -r -p "Private overseas DNS upstreams [1.1.1.1,8.8.8.8,9.9.9.9]: " private_selected
    fi
    if [[ -z "$public_selected" && -t 0 ]]; then
        read -r -p "Public overseas DNS upstreams [1.1.1.1,8.8.8.8]: " public_selected
    fi
    if [[ -z "$sniproxy_selected" && -t 0 ]]; then
        read -r -p "sniproxy resolver upstreams [same as private overseas DNS]: " sniproxy_selected
    fi

    if [[ -z "$private_selected" ]]; then
        private_selected="${DEFAULT_OVERSEAS_DNS[*]}"
    fi
    if [[ -z "$public_selected" ]]; then
        public_selected="${DEFAULT_PUBLIC_OVERSEAS_DNS[*]}"
    fi
    if [[ -z "$sniproxy_selected" ]]; then
        sniproxy_selected="$private_selected"
    fi

    OVERSEAS_DNS="$private_selected"
    PRIVATE_OVERSEAS_DNS="$private_selected"
    PUBLIC_OVERSEAS_DNS="$public_selected"
    SNIPROXY_DNS="$sniproxy_selected"

    mkdir -p "$CONF_DIR"
    echo "$PRIVATE_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_dns"
    echo "$PRIVATE_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_private_dns"
    echo "$PUBLIC_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_public_dns"
    echo "$SNIPROXY_DNS" > "${CONF_DIR}/.sniproxy_dns"
    info "Private overseas DNS upstreams: $PRIVATE_OVERSEAS_DNS"
    info "Public overseas DNS upstreams: $PUBLIC_OVERSEAS_DNS"
    info "sniproxy resolver upstreams: $SNIPROXY_DNS"
}

# =============================================================================
# Command-line dispatch
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  (none)         Full interactive installation
  --status       Show service status
  --update-rules Update GFWList/ChinaList and reload dnsdist
  --renew-cert   Force renew certificates and reload services
  --list-exits   List configured egress exits and which one is active
  --check-exits  Test reachability of each exit's upstream node (UP/DOWN)
  --add-exit <name> [wg.conf | socks5://... | ss://...]
                 Register an egress exit. Accepts a WireGuard client config
                 (file/stdin/paste) OR a SOCKS5 / Shadowsocks(2022) URI. The
                 socks/ss types use a sing-box TUN engine (auto-installed).
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
  --uninstall    Remove all installed components
  -ios          Regenerate iOS DoT profile and QR code
  -h, --help     Show this help

Environment variables (for non-interactive use):
  DOMAIN         Your own fully-qualified domain (e.g. dns.example.com).
                 When set, the interactive domain prompt is skipped.
                 You must point its A record at this host's public IP.
  OVERSEAS_DNS   Backward-compatible alias for PRIVATE_OVERSEAS_DNS
  PRIVATE_OVERSEAS_DNS  Overseas upstream DNS for 172.22.0.0/16 DoT clients
  PUBLIC_OVERSEAS_DNS   Overseas upstream DNS for non-private DoT clients
  SNIPROXY_DNS   Resolver upstream DNS for TCP sniproxy backends
  EMAIL          Email for Let's Encrypt
  TG_BOT_TOKEN   Telegram bot token; enables the control bot when set
  TG_ADMIN_IDS   Comma-separated Telegram numeric IDs allowed to operate the bot
EOF
}

# =============================================================================
# Basic checks
# =============================================================================
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

# Detect the available RAM and decide whether to use the low-memory profile.
# Sets globals: MEM_TOTAL_MB, LOWMEM (0/1), MAKE_JOBS, PACKET_CACHE_SIZE.
# Honors an explicit override: LOWMEM=1 / LOWMEM=0 in the environment.
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
        warn "Low-memory mode ENABLED (RAM: ${MEM_TOTAL_MB}MB). Reducing caches, sysctl, build jobs; iOS server is on-demand; swap will be ensured."
    else
        MAKE_JOBS="$(nproc 2>/dev/null || echo 2)"
        PACKET_CACHE_SIZE=500000
        info "Standard memory mode (RAM: ${MEM_TOTAL_MB}MB)."
    fi
}

# On low-memory hosts, make sure some swap exists before we compile / run.
swap_size_to_bytes() {
    python3 -c 'import re, sys; raw = sys.argv[1].strip().upper(); raw = raw if raw.endswith("G") else (raw + "G" if raw else raw); m = re.fullmatch(r"([0-9]+(?:\\.[0-9]+)?)G", raw); print(0 if not m else int(float(m.group(1)) * 1024 * 1024 * 1024))' "$1"
}

prompt_swap_size() {
    local input="${SWAP_SIZE:-}"
    if [[ -z "$input" && -t 0 ]]; then
        read -r -p "请输入 swap 大小（如 0.5/1/2 或 0.5G/1G/2G；输入 0/n/skip 可跳过，回车默认 1）: " input || true
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
    # /proc/swaps has a header line; >1 line means swap is already active.
    if [[ "$(wc -l < /proc/swaps 2>/dev/null || echo 1)" -gt 1 ]]; then
        info "Swap already present, skipping swapfile creation."
        return 0
    fi
    [[ -e /swapfile ]] && return 0

    local swap_size swap_bytes swap_mib required_mb avail_mb
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

        read -r -p "Stop and disable '$proc' to free port 53? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            err "Port 53 must be free for dnsdist to start. Aborting."
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
            # Preserve DNS after disabling the local stub resolver; otherwise
            # apt/curl/certbot may lose name resolution on Debian 13.
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

# =============================================================================
# Dependencies
# =============================================================================
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
                dnsdist certbot python3-certbot-dns-cloudflare \
                python3 python3-pip jq libcap2-bin \
                nftables qrencode wireguard-tools || true
            ;;
        dnf|yum)
            $PKG_MGR install -y -q \
                gcc gcc-c++ make git wget curl ca-certificates \
                libev-devel pcre-devel openssl-devel \
                autoconf automake libtool pkgconfig \
                dnsdist certbot python3-certbot-dns-cloudflare \
                python3 python3-pip jq libcap-ng-utils \
                nftables qrencode wireguard-tools || true
            ;;
    esac

    # Ensure Go is installed (for quic-proxy compilation)
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
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    fi

    ok "Go version: $(go version)"

    # Fix certbot compatibility on newer Python versions (e.g. 3.12+)
    if command -v certbot >/dev/null 2>&1; then
        if ! certbot --version >/dev/null 2>&1; then
            warn "Certbot has compatibility issues with the current Python version. Attempting to fix..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
        fi
    fi

    # Verify critical binaries
    for bin in dnsdist certbot; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            err "Required package '$bin' was not installed successfully."
            err "Please check your package manager output above."
            exit 1
        fi
    done
}

# =============================================================================
# Domain configuration (operator-supplied domain)
# =============================================================================
# Validate a domain name (FQDN). Returns 0 if valid.
is_valid_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]
}

generate_domain() {
    # Domain may be supplied non-interactively via the DOMAIN env var.
    if [[ -n "${DOMAIN:-}" ]]; then
        if ! is_valid_domain "$DOMAIN"; then
            err "Invalid DOMAIN: '$DOMAIN'. Provide a fully-qualified domain like dns.example.com"
            exit 1
        fi
        info "Using pre-configured domain: $DOMAIN"
        DOMAIN_PRECONFIGURED=1
        mkdir -p "$CONF_DIR"
        echo "$DOMAIN" > "${CONF_DIR}/.domain"
        return
    fi

    # Interactive: prompt the operator for their own domain.
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

    # Interactive confirm (only when attached to a TTY).
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
        resolved=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || echo "")
        if [[ "$resolved" == "$PUBLIC_IP" ]]; then
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

# =============================================================================
# Let's Encrypt Certificate
# =============================================================================
install_cert() {
    local certbot_cmd certbot_cmd_force
    install_certbot_firewall_hooks

    # Normal issuance (first time) - no force-renewal to avoid rate limits
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)
    # Reinstall / explicit renew - force renewal
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
        open_cert_http_port
        trap restore_reverse_proxy_firewall RETURN
        # Run certbot ONCE and capture output, so we never re-issue just to probe
        # the error (that wastes Let's Encrypt rate-limit attempts). The `if`
        # keeps the failing run from tripping `set -e` before we can handle it.
        local out rc
        if out="$("${cb_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
        printf '%s\n' "$out"
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        # Retry once only on the known Python (3.12+) compatibility error.
        if grep -q "AttributeError" <<<"$out"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
            info "Retrying certificate request..."
            "${cb_cmd[@]}"
            return $?
        fi
        return 1
    }

    if ! run_certbot; then
        err "证书申请失败。请检查:"
        err "  1. 域名 $DOMAIN 是否正确解析到本机 ($PUBLIC_IP)"
        err "  2. 端口 80 是否被占用"
        err "  3. 防火墙是否放行 80"
        err "  4. 是否触发了 Let's Encrypt 速率限制 (同一域名 7 天内限 5 次)"
        exit 1
    fi

    # Copy certificates to dnsdist-readable location
    info "Copying certificates to /etc/dnsdist/certs/ ..."
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/dnsdist/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/dnsdist/certs/privkey.pem
        chown -R _dnsdist:_dnsdist /etc/dnsdist/certs/
        chmod 640 /etc/dnsdist/certs/*.pem
        ok "Certificates copied to /etc/dnsdist/certs/"
    else
        warn "Could not find certificate live directory: $cert_live_dir"
    fi

    # Deploy renewal hook (also handles cert copy on renewal)
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cp "${SCRIPT_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh
    ok "证书已就绪，自动续期 Hook 已部署"
}

# =============================================================================
# sniproxy (TCP)
# =============================================================================
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

    if [[ -f "${SCRIPT_DIR}/sniproxy.conf" ]]; then
        local sniproxy_nameservers
        sniproxy_nameservers=$(render_sniproxy_dns_nameservers "$SNIPROXY_DNS")
        python3 - "${SCRIPT_DIR}/sniproxy.conf" "$sniproxy_nameservers" /etc/sniproxy.conf <<'PYEOF'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__SNIPROXY_NAMESERVERS__", sys.argv[2])
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
    else
        err "sniproxy.conf not found in ${SCRIPT_DIR}"
        exit 1
    fi

    # systemd service
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

# =============================================================================
# quic-proxy (UDP / QUIC SNI proxy)
# =============================================================================
install_quic_proxy() {
    ensure_proxy_user
    if [[ ! -x "${BASE_DIR}/bin/quic-proxy" ]]; then
        info "Compiling quic-proxy (UDP/QUIC SNI proxy)..."
        mkdir -p "${BASE_DIR}/bin"
        mkdir -p "${SRC_DIR}"
        cp "${SCRIPT_DIR}/quic-proxy.go" "${SRC_DIR}/quic-proxy.go"
        cd "${SRC_DIR}"

        export PATH=$PATH:/usr/local/go/bin
        go build -ldflags="-s -w" -o "${BASE_DIR}/bin/quic-proxy" quic-proxy.go
    else
        info "quic-proxy already compiled"
    fi

    # systemd service
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

# =============================================================================
# China DNS race proxy (UDP DNS upstream racing for ChinaList)
# =============================================================================
install_china_dns_race_proxy() {
    info "Compiling china-dns-race-proxy..."
    mkdir -p "${BASE_DIR}/bin"
    mkdir -p "${SRC_DIR}"
    cp "${SCRIPT_DIR}/china-dns-race-proxy.go" "${SRC_DIR}/china-dns-race-proxy.go"
    cd "${SRC_DIR}"

    export PATH=$PATH:/usr/local/go/bin
    go build -ldflags="-s -w" -o "${BASE_DIR}/bin/china-dns-race-proxy" china-dns-race-proxy.go

    cat > /etc/systemd/system/china-dns-race-proxy.service <<'EOF'
[Unit]
Description=China DNS race proxy
After=network.target
Before=dnsdist.service

[Service]
Type=simple
ExecStart=/opt/proxy-gateway/bin/china-dns-race-proxy -l 127.0.0.1:5301
Restart=on-failure
RestartSec=3
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable china-dns-race-proxy
    ok "china-dns-race-proxy installed"
}

# =============================================================================
# dnsdist (DoT + Smart DNS)
# =============================================================================
install_dnsdist() {
    info "Configuring dnsdist..."

    mkdir -p /etc/dnsdist
    cp "${SCRIPT_DIR}/dnsdist.conf.template" /etc/dnsdist/dnsdist.conf.template
    cp "${SCRIPT_DIR}/update-rules.sh" /usr/local/bin/update-dnsdist-rules.sh
    chmod +x /usr/local/bin/update-dnsdist-rules.sh

    # Save domain and IP for template generation
    echo "$DOMAIN" > /etc/dnsdist/.domain
    echo "$PUBLIC_IP" > /etc/dnsdist/.public_ip
    echo "$PRIVATE_OVERSEAS_DNS" > /etc/dnsdist/.overseas_dns
    echo "$PRIVATE_OVERSEAS_DNS" > /etc/dnsdist/.overseas_private_dns
    echo "$PUBLIC_OVERSEAS_DNS" > /etc/dnsdist/.overseas_public_dns
    echo "$SNIPROXY_DNS" > /etc/dnsdist/.sniproxy_dns
    # Persist the packet-cache size so weekly rule updates keep the same value.
    echo "${PACKET_CACHE_SIZE:-500000}" > /etc/dnsdist/.cache_size
    local overseas_private_servers overseas_public_servers
    overseas_private_servers=$(render_overseas_dns_servers "$PRIVATE_OVERSEAS_DNS" "overseas_private" "overseas_private")
    overseas_public_servers=$(render_overseas_dns_servers "$PUBLIC_OVERSEAS_DNS" "overseas_public" "overseas_public")

    # Determine actual certificate directory name
    local cert_basename="${DOMAIN}"
    if [[ -f "${CONF_DIR}/.cert_basename" ]]; then
        cert_basename=$(cat "${CONF_DIR}/.cert_basename")
    fi

    # Generate initial config (empty rules, will be populated by update-rules.sh)
    python3 - /etc/dnsdist/dnsdist.conf.template "${PUBLIC_IP}" "${cert_basename}" "$overseas_private_servers" "$overseas_public_servers" "${PACKET_CACHE_SIZE:-500000}" /etc/dnsdist/dnsdist.conf <<'PYEOF'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__GFWLIST_RULES__", "-- (rules will be loaded by update-rules.sh)")
content = content.replace("__CHINALIST_RULES__", "-- (rules will be loaded by update-rules.sh)")
content = content.replace("__SERVER_IP__", sys.argv[2])
content = content.replace("__DOMAIN__", sys.argv[3])
content = content.replace("__OVERSEAS_PRIVATE_DNS_SERVERS__", sys.argv[4])
content = content.replace("__OVERSEAS_PUBLIC_DNS_SERVERS__", sys.argv[5])
content = content.replace("__PACKET_CACHE_SIZE__", sys.argv[6])
with open(sys.argv[7], "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

    # systemd override for dnsdist (ensure it reads our config + supports reload)
    mkdir -p /etc/systemd/system/dnsdist.service.d
    cat > /etc/systemd/system/dnsdist.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dnsdist --supervised -C /etc/dnsdist/dnsdist.conf
# dnsdist has no signal-based config reload — SIGHUP makes it EXIT. Disable the
# HUP reload (so a stray `systemctl reload` can't kill it) and apply config via
# restart instead. Restart=always also recovers from OOM on small hosts.
ExecReload=
Restart=always
RestartSec=3
LimitNOFILE=65535
EOF

    systemctl daemon-reload
    systemctl enable dnsdist
    ok "dnsdist configured"
}

# =============================================================================
# Rules initialization
# =============================================================================
init_rules() {
    info "Initializing GFWList and ChinaList..."
    /usr/local/bin/update-dnsdist-rules.sh || warn "Rule update failed, will retry later"
}

# =============================================================================
# iOS DoT profile
# =============================================================================
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

    # Socket-activated (inetd-style) static responder: zero idle processes, a
    # short-lived python only spawns when a phone actually fetches the profile.
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    mkdir -p "${BASE_DIR}/bin"
    if [[ -f "${SCRIPT_DIR}/ios-http.py" ]]; then
        install -m 0755 "${SCRIPT_DIR}/ios-http.py" "${BASE_DIR}/bin/ios-http.py"
    fi

    # Drop any previous always-on unit from earlier installs.
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

# =============================================================================
# System tuning
# =============================================================================
system_tuning() {
    info "Applying kernel and system tuning..."

    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d
    echo nf_conntrack > /etc/modules-load.d/proxy-gateway-net.conf

    # Scale the heavy limits to the host. The huge defaults size large kernel
    # hash tables and are wasteful (even risky) on small VPSes.
    local sy_file_max sy_nr_open sy_netdev sy_somaxconn sy_conntrack_max
    local sy_tcp_syn sy_tcp_orphans sy_buf_max sy_swappiness
    if [[ "${LOWMEM:-0}" == "1" ]]; then
        sy_file_max=1048576;  sy_nr_open=1048576; sy_netdev=16384
        sy_somaxconn=4096;    sy_conntrack_max=131072
        sy_tcp_syn=8192;      sy_tcp_orphans=8192
        sy_buf_max=16777216;  sy_swappiness=60
    else
        sy_file_max=10240000; sy_nr_open=2097152;  sy_netdev=65536
        sy_somaxconn=10240000; sy_conntrack_max=10240000
        sy_tcp_syn=65536;     sy_tcp_orphans=10240
        sy_buf_max=134217728; sy_swappiness=0
    fi

    cat > /etc/sysctl.d/99-proxy-gateway.conf <<EOF
# Proxy Gateway Optimizations (profile: $([[ "${LOWMEM:-0}" == "1" ]] && echo low-memory || echo standard))
fs.file-max=${sy_file_max}
fs.nr_open=${sy_nr_open}
net.core.default_qdisc=fq
net.core.netdev_max_backlog=${sy_netdev}
net.core.somaxconn=${sy_somaxconn}
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.ip_default_ttl=128
net.ipv4.ip_forward=1
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_fastopen=1027
net.ipv4.tcp_fastopen_blackhole_timeout_sec=0
net.ipv4.tcp_fin_timeout=2
net.ipv4.tcp_keepalive_intvl=5
net.ipv4.tcp_keepalive_probes=2
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_max_orphans=${sy_tcp_orphans}
net.ipv4.tcp_max_syn_backlog=${sy_tcp_syn}
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_retries1=2
net.ipv4.tcp_retries2=2
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_rmem=8192 65536 ${sy_buf_max}
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_wmem=8192 131072 ${sy_buf_max}
net.netfilter.nf_conntrack_generic_timeout=10
net.netfilter.nf_conntrack_icmp_timeout=2
net.netfilter.nf_conntrack_max=${sy_conntrack_max}
net.netfilter.nf_conntrack_tcp_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_close=2
net.netfilter.nf_conntrack_tcp_timeout_close_wait=2
net.netfilter.nf_conntrack_tcp_timeout_established=30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=2
net.netfilter.nf_conntrack_tcp_timeout_last_ack=2
net.netfilter.nf_conntrack_tcp_timeout_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=2
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=2
net.netfilter.nf_conntrack_tcp_timeout_time_wait=2
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=2
net.netfilter.nf_conntrack_udp_timeout=2
net.netfilter.nf_conntrack_udp_timeout_stream=30
vm.swappiness=${sy_swappiness}
EOF

    local mem_pages
    mem_pages=$(awk '/MemTotal/ { printf "%d", ($2 * 1024) / 4096 }' /proc/meminfo 2>/dev/null || echo "")
    if [[ -n "$mem_pages" && "$mem_pages" -gt 0 ]]; then
        {
            echo "net.ipv4.tcp_mem=$((mem_pages / 100 * 12)) $((mem_pages / 100 * 50)) $((mem_pages / 100 * 70))"
        } >> /etc/sysctl.d/99-proxy-gateway.conf
    fi

    # /etc/sysctl.conf is applied AFTER /etc/sysctl.d/* on Debian/systemd, so a
    # stray vm.swappiness there (common in VPS images) would silently override
    # our drop-in. Neutralize it so our value actually takes effect.
    if grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E 's/^([[:space:]]*vm\.swappiness[[:space:]]*=)/# disabled by proxy-gateway (see 99-proxy-gateway.conf): \1/' /etc/sysctl.conf
    fi

    sysctl --system >/dev/null

    # PAM limits (avoid duplicate entries)
    if ! grep -q "proxy-gateway-limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# proxy-gateway-limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/disable-transparent-huge-pages.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -w /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true'
ExecStart=/bin/sh -c 'test -w /sys/kernel/mm/transparent_hugepage/defrag && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'

[Install]
WantedBy=basic.target
EOF

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-proxy-gateway.conf <<'EOF'
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF

    systemctl daemon-reload
    systemctl enable --now disable-transparent-huge-pages.service 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true

    ok "System tuning applied"
}

# =============================================================================
# Firewall (nftables preferred, fallback to iptables)
# =============================================================================
setup_firewall() {
    info "Configuring firewall..."
    # The nft ruleset matches "skuid pxout"; the user must exist or the whole
    # ruleset fails to load. (No-op if already created.)
    ensure_proxy_user

    # Allowed inbound TCP ports; add the control-API port if it has been set up.
    local api_port="" tcp_ports="22, 53, 853, 8111" tcp_ports_ipt="22,53,853,8111"
    [[ -f "${CONF_DIR}/.api_port" ]] && api_port="$(tr -dc '0-9' < "${CONF_DIR}/.api_port" 2>/dev/null)"
    if [[ -n "$api_port" ]]; then
        tcp_ports="${tcp_ports}, ${api_port}"; tcp_ports_ipt="${tcp_ports_ipt},${api_port}"
    fi

    if command -v nft >/dev/null 2>&1; then
        # nftables
        cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { __TCP_PORTS__ } accept
        udp dport 53 accept
        ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept
        ip saddr 172.22.0.0/16 udp dport 443 accept
        # ICMP for basic network health
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# Switchable egress: mark proxy ("pxout") outbound so policy routing can send it
# into a WireGuard tunnel; clamp MSS on tunnel interfaces. Kept in the main
# ruleset so it survives the "flush ruleset" above on every firewall reload.
# Traffic to the client network and any private/loopback range is NOT marked,
# so proxy replies to 172.22.0.0/16 still take the normal route (not the tunnel).
table inet pgw_exit {
    chain mark_out {
        type route hook output priority -150; policy accept;
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } return
        meta l4proto { tcp, udp } th dport 53 return
        meta skuid "pxout" meta mark set 0x1
    }
    chain clamp {
        type filter hook postrouting priority mangle; policy accept;
        oifname "pgw-*" tcp flags syn tcp option maxseg size set rt mtu
    }
}
EOF
        sed -i "s/__TCP_PORTS__/${tcp_ports}/" /etc/nftables.conf
        chmod +x /etc/nftables.conf
        nft -f /etc/nftables.conf 2>/dev/null || true
        systemctl enable nftables 2>/dev/null || true
    else
        # iptables fallback
        iptables -F INPUT
        iptables -P INPUT DROP
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp -m multiport --dports ${tcp_ports_ipt} -j ACCEPT
        iptables -A INPUT -p udp --dport 53 -j ACCEPT
        iptables -A INPUT -s 172.22.0.0/16 -p tcp -m multiport --dports 80,443 -j ACCEPT
        iptables -A INPUT -s 172.22.0.0/16 -p udp --dport 443 -j ACCEPT
        iptables -A INPUT -p icmp -j ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT

        # Switchable egress: mark proxy ("pxout") outbound for policy routing.
        # Rebuild our rules in a fixed order: private/client destinations RETURN
        # (stay on the normal route) before the catch-all MARK.
        if id -u "${EXIT_USER}" >/dev/null 2>&1; then
            local pn
            while iptables -t mangle -D OUTPUT -m owner --uid-owner "${EXIT_USER}" -j MARK --set-mark "${EXIT_MARK}" 2>/dev/null; do :; done
            for pn in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
                while iptables -t mangle -D OUTPUT -m owner --uid-owner "${EXIT_USER}" -d "$pn" -j RETURN 2>/dev/null; do :; done
                iptables -t mangle -A OUTPUT -m owner --uid-owner "${EXIT_USER}" -d "$pn" -j RETURN 2>/dev/null || true
            done
            # DNS (port 53) resolves directly, never through the exit (many SOCKS
            # exits don't relay UDP, which would otherwise break name resolution).
            local pp
            for pp in udp tcp; do
                while iptables -t mangle -D OUTPUT -m owner --uid-owner "${EXIT_USER}" -p "$pp" --dport 53 -j RETURN 2>/dev/null; do :; done
                iptables -t mangle -A OUTPUT -m owner --uid-owner "${EXIT_USER}" -p "$pp" --dport 53 -j RETURN 2>/dev/null || true
            done
            iptables -t mangle -A OUTPUT -m owner --uid-owner "${EXIT_USER}" -j MARK --set-mark "${EXIT_MARK}" 2>/dev/null || true
            iptables -t mangle -C POSTROUTING -o "pgw+" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
                iptables -t mangle -A POSTROUTING -o "pgw+" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        fi

        # Save rules
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
    fi

    ok "Firewall configured (reverse proxy whitelist: 172.22.0.0/16)"
}

open_cert_http_port() {
    info "Temporarily opening TCP/80 for Let's Encrypt HTTP-01..."

    if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
        nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
    fi
}

restore_reverse_proxy_firewall() {
    info "Restoring reverse proxy firewall whitelist..."
    setup_firewall >/dev/null 2>&1 || true
}

install_certbot_firewall_hooks() {
    mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

    cat > /usr/local/bin/proxy-gateway-open-cert-http.sh <<'EOF'
#!/bin/bash
set -e
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
fi
EOF
    cat > /usr/local/bin/proxy-gateway-restore-firewall.sh <<'EOF'
#!/bin/bash
set -e
if command -v nft >/dev/null 2>&1 && [[ -f /etc/nftables.conf ]]; then
    nft -f /etc/nftables.conf 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do :; done
fi
EOF
    chmod +x /usr/local/bin/proxy-gateway-open-cert-http.sh /usr/local/bin/proxy-gateway-restore-firewall.sh
    cp /usr/local/bin/proxy-gateway-open-cert-http.sh /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh
    cp /usr/local/bin/proxy-gateway-restore-firewall.sh /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
}

# =============================================================================
# Switchable egress ("exit") management
# =============================================================================
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
exit_iface()        { echo "pgw-${1}"; }                      # device name (wg or TUN)
exit_type_file()    { echo "${EXITS_DIR}/${1}.type"; }
exit_singbox_conf() { echo "${EXITS_DIR}/${1}.json"; }

# An exit's type: explicit .type file wins; else inferred from a wg config.
exit_type() {
    local name="$1" tf; tf="$(exit_type_file "$name")"
    if [[ -f "$tf" ]]; then cat "$tf"; return; fi
    [[ -f "$(exit_conf_path "$name")" ]] && { echo wireguard; return; }
    echo ""
}

exit_exists() {
    [[ -f "$(exit_type_file "$1")" || -f "$(exit_conf_path "$1")" ]]
}

# All configured exit names (excluding 'local'), one per line, sorted unique.
list_exit_names() {
    shopt -s nullglob
    local f n; local -A seen=()
    for f in "${EXITS_DIR}"/*.type; do n="$(basename "$f" .type)"; seen["$n"]=1; done
    for f in "${WG_DIR}"/pgw-*.conf; do n="$(basename "$f" .conf)"; seen["${n#pgw-}"]=1; done
    shopt -u nullglob
    # Must return 0 even when empty (callers use it under set -e / pipefail).
    if [[ ${#seen[@]} -gt 0 ]]; then
        printf '%s\n' "${!seen[@]}" | sort
    fi
    return 0
}

# Download sing-box on first need (only for socks/shadowsocks exits).
ensure_singbox() {
    [[ -x "${SINGBOX_BIN}" ]] && return 0
    info "Installing sing-box (tun2socks engine for socks/shadowsocks exits)..."
    local ver arch tmp url
    ver="${SINGBOX_VERSION:-}"
    if [[ -z "$ver" ]]; then
        ver="$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases 2>/dev/null \
               | grep -oE '"tag_name": *"v1\.10\.[0-9]+"' | head -n1 | grep -oE '1\.10\.[0-9]+' || true)"
    fi
    [[ -z "$ver" ]] && ver="${SINGBOX_VERSION_DEFAULT}"
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) arch=amd64 ;;
    esac
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 90 "$url" -o "$tmp/sb.tar.gz"; then
        rm -rf "$tmp"; err "Failed to download sing-box ${ver}. Set SINGBOX_VERSION=<ver> and retry. URL: $url"; return 1
    fi
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; err "Failed to extract sing-box archive"; return 1; }
    mkdir -p "${BASE_DIR}/bin"
    if ! install -m 0755 "$tmp"/sing-box-*/sing-box "${SINGBOX_BIN}" 2>/dev/null; then
        rm -rf "$tmp"; err "sing-box binary not found in archive"; return 1
    fi
    rm -rf "$tmp"
    ok "sing-box ${ver} installed: ${SINGBOX_BIN}"
}

# systemd template that runs sing-box for one socks/shadowsocks exit.
install_singbox_unit() {
    cat > /etc/systemd/system/proxy-gateway-singbox@.service <<EOF
[Unit]
Description=Proxy Gateway sing-box exit (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${EXITS_DIR}/%i.json
# Recreating the TUN drops the table-100 route; re-apply it after (re)start.
ExecStartPost=-/usr/local/bin/proxy-gateway-apply-exit.sh
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# Bring an exit's device up / down by type.
exit_up() {
    local name="$1" t; t="$(exit_type "$name")"
    case "$t" in
        wireguard)
            command -v wg-quick >/dev/null 2>&1 || { err "wg-quick not installed"; return 1; }
            wg-quick up "pgw-${name}" ;;
        socks|shadowsocks|router)
            ensure_singbox || return 1
            install_singbox_unit
            systemctl restart "proxy-gateway-singbox@${name}.service" ;;
        *) err "Unknown type for exit '$name'"; return 1 ;;
    esac
}

exit_down() {
    local name="$1" t; t="$(exit_type "$name")"
    case "$t" in
        wireguard)        wg-quick down "pgw-${name}" 2>/dev/null || true ;;
        socks|shadowsocks|router) systemctl stop "proxy-gateway-singbox@${name}.service" 2>/dev/null || true ;;
    esac
}

# "host port" of a socks/ss exit's upstream server (empty for wireguard/router).
exit_server() {
    local jf; jf="$(exit_singbox_conf "$1")"
    [[ -f "$jf" ]] || return 0
    python3 - "$jf" <<'PY' 2>/dev/null
import json, sys
try:
    o = json.load(open(sys.argv[1]))["outbounds"][0]
    if o.get("server"):
        print(o["server"], o.get("server_port", ""))
except Exception:
    pass
PY
}

# TCP-reachability of a host:port (0 = reachable). Unknown host = assume ok.
exit_reachable() {
    local host="$1" port="$2"
    [[ -z "$host" || -z "$port" ]] && return 0
    timeout 4 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# Warn (don't block) when an exit's upstream node is unreachable. For the smart
# router, check every exit referenced in the policy map.
preflight_exit() {
    local name="$1" t hp host port tgt
    t="$(exit_type "$name")"
    if [[ "$t" == "socks" || "$t" == "shadowsocks" ]]; then
        hp="$(exit_server "$name")"; host="${hp%% *}"; port="${hp##* }"
        if ! exit_reachable "$host" "$port"; then
            warn "Exit '$name' upstream ${host}:${port} is UNREACHABLE — traffic via it will fail."
        fi
    elif [[ "$t" == "router" ]]; then
        for tgt in $(awk -F= 'NF==2{print $2}' "${POLICY_MAP}" 2>/dev/null | sort -u); do
            case "$tgt" in direct|block|"") continue ;; esac
            hp="$(exit_server "$tgt")"; host="${hp%% *}"; port="${hp##* }"
            if ! exit_reachable "$host" "$port"; then
                warn "Smart target '$tgt' (${host}:${port}) is UNREACHABLE — rules using it will blackhole."
            fi
        done
    fi
}

# Report reachability of every configured exit's upstream node.
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

# Wait (≤5s) for the pgw-<name> device to appear (sing-box TUN creation is async).
exit_wait_device() {
    local iface="pgw-${1}" i
    for i in $(seq 1 50); do
        ip link show "$iface" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# Boot-time / on-change re-application of the currently selected exit.
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

# Marked traffic consults the dedicated table; an empty table falls through to
# the main table, i.e. direct egress ("local").
ip rule add fwmark "${MARK}" table "${TABLE}" 2>/dev/null || true

current="local"
[[ -f "${STATE}" ]] && current="$(cat "${STATE}" 2>/dev/null || echo local)"

if [[ -z "${current}" || "${current}" == "local" ]]; then
    ip route flush table "${TABLE}" 2>/dev/null || true
    exit 0
fi

iface="pgw-${current}"
etype="wireguard"
[[ -f "${EXITS_DIR}/${current}.type" ]] && etype="$(cat "${EXITS_DIR}/${current}.type")"

if ! ip link show "${iface}" >/dev/null 2>&1; then
    case "${etype}" in
        wireguard)        wg-quick up "${iface}" 2>/dev/null || { echo "[!] exit '${current}' (wireguard) failed to start"; exit 1; } ;;
        socks|shadowsocks|router) systemctl start "proxy-gateway-singbox@${current}.service" 2>/dev/null || { echo "[!] exit '${current}' (${etype}) failed to start"; exit 1; } ;;
    esac
fi

for _ in $(seq 1 50); do ip link show "${iface}" >/dev/null 2>&1 && break; sleep 0.1; done
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

    # Install the sing-box config generators (per-exit + smart router).
    mkdir -p "${BASE_DIR}/bin"
    [[ -f "${SCRIPT_DIR}/singbox-exit-config.py" ]] && \
        install -m 0755 "${SCRIPT_DIR}/singbox-exit-config.py" "${SINGBOX_CFG_GEN}"
    [[ -f "${SCRIPT_DIR}/singbox-router-config.py" ]] && \
        install -m 0755 "${SCRIPT_DIR}/singbox-router-config.py" "${SINGBOX_ROUTER_GEN}"
    [[ -f "${SCRIPT_DIR}/rules-import.py" ]] && \
        install -m 0755 "${SCRIPT_DIR}/rules-import.py" "${RULES_IMPORT}"

    # Built-in default smart rules (e.g. speedtest) — merged ahead of user rules.
    mkdir -p "$(dirname "${RULES_DEFAULT}")"
    [[ -f "${SCRIPT_DIR}/rules-default.conf" ]] && \
        install -m 0644 "${SCRIPT_DIR}/rules-default.conf" "${RULES_DEFAULT}"

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
            socks|shadowsocks)
                detail="$(grep -oE '"server": *"[^"]+"|"server_port": *[0-9]+' "$(exit_singbox_conf "$n")" 2>/dev/null | head -n2 | sed 's/.*: *//; s/"//g' | paste -sd: -)" ;;
            router)
                detail="rules:$(grep -cvE '^[[:space:]]*(#|;|$)' "${RULES_FILE}" 2>/dev/null || echo 0)" ;;
            *) detail="?" ;;
        esac
        link="down"; ip link show "pgw-${n}" >/dev/null 2>&1 && link="up"
        printf '  %-12s %-11s %s link=%s%s\n' "$n" "${t:-?}" "${detail:-?}" "$link" "$([[ "$cur" == "$n" ]] && echo ' *')"
    done < <(list_exit_names)
    echo "=========================================="
    echo "  ( * = active )  switch with: $0 --set-exit <name|local>"
}

add_exit() {
    local name="${1:-}" src="${2:-}"
    [[ -z "$name" ]] && { err "Usage: $0 --add-exit <name> [wg.conf | socks5://... | ss://...]"; exit 1; }
    python3 - "$name" <<'PYNAME' || { err "Exit name must be 1-16 letters/digits/Chinese characters/_/-"; exit 1; }
import re, sys
name = sys.argv[1]
if name in ("local", "smart") or not re.match(r"^[\w\-\u4e00-\u9fff]{1,16}$", name, re.UNICODE):
    raise SystemExit(1)
PYNAME
    [[ "$name" == "local" || "$name" == "smart" ]] && { err "'$name' is a reserved exit name (smart = rule-based router; use --set-rules)"; exit 1; }

    mkdir -p "${WG_DIR}"; chmod 700 "${WG_DIR}"
    mkdir -p "${EXITS_DIR}"; chmod 700 "${EXITS_DIR}"

    # Read payload: file arg, a URI passed as the arg, stdin pipe, or paste.
    local tmp; tmp="$(mktemp)"
    if [[ -n "$src" && -f "$src" ]]; then
        cat "$src" > "$tmp"
    elif [[ -n "$src" ]]; then
        printf '%s\n' "$src" > "$tmp"
    elif [[ ! -t 0 ]]; then
        cat > "$tmp"
    else
        echo "Paste a WireGuard config OR a socks5://... / ss://... URI for '$name', end with Ctrl-D:"
        cat > "$tmp"
    fi

    # A proxy URI -> socks/shadowsocks exit via sing-box. Grab the WHOLE first
    # scheme line (not just a non-space token) so a single-line password can
    # contain spaces and other special chars; only CR / surrounding space trimmed.
    local uri type px_user px_pass px_rdns
    uri="$(grep -iE '^[[:space:]]*(ss|socks5h|socks5|socks)://' "$tmp" | head -n1 | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [[ -n "$uri" ]]; then
        # Classify by a lowercased copy (scheme may be upper/mixed case); the
        # original "$uri" is passed through unchanged so the password keeps its case.
        local uri_lc; uri_lc="$(printf '%s' "$uri" | tr '[:upper:]' '[:lower:]')"
        case "$uri_lc" in
            ss://*)                            type=shadowsocks ;;
            socks5h://*|socks5://*|socks://*)  type=socks ;;
        esac
        # Optional out-of-band SOCKS5 credentials on their own lines, so passwords
        # with special characters need no URL-encoding:  user: X  /  pass: Y
        px_user="$(grep -iE '^[[:space:]]*(user|username)[[:space:]]*[:=]' "$tmp" | head -n1 | sed -E 's/^[[:space:]]*[^:=]+[:=][[:space:]]*//' | tr -d '\r' || true)"
        px_pass="$(grep -iE '^[[:space:]]*(pass|password)[[:space:]]*[:=]' "$tmp" | head -n1 | sed -E 's/^[[:space:]]*[^:=]+[:=][[:space:]]*//' | tr -d '\r' || true)"
        # Optional explicit remote-DNS toggle (socks5h:// already implies it).
        px_rdns="$(grep -iE '^[[:space:]]*remote-?dns[[:space:]]*[:=]' "$tmp" | head -n1 | sed -E 's/^[[:space:]]*[^:=]+[:=][[:space:]]*//' | tr -d '\r' || true)"
        rm -f "$tmp"
        [[ -f "${SINGBOX_CFG_GEN}" ]] || { err "Config generator missing: ${SINGBOX_CFG_GEN}"; exit 1; }
        ensure_singbox || exit 1
        local json="$(exit_singbox_conf "$name")" gen_err
        if ! gen_err="$(PGW_USER="$px_user" PGW_PASS="$px_pass" PGW_REMOTE_DNS="$px_rdns" python3 "${SINGBOX_CFG_GEN}" "$name" "$uri" 2>&1 >"${json}.tmp")"; then
            err "Failed to parse URI: ${gen_err}"; rm -f "${json}.tmp"; exit 1
        fi
        install_singbox_unit
        if ! "${SINGBOX_BIN}" check -c "${json}.tmp" >/dev/null 2>&1; then
            err "sing-box rejected the generated config:"; "${SINGBOX_BIN}" check -c "${json}.tmp" 2>&1 | sed 's/^/    /' >&2
            rm -f "${json}.tmp"; exit 1
        fi
        install -m 600 "${json}.tmp" "${json}"; rm -f "${json}.tmp"
        echo "$type" > "$(exit_type_file "$name")"
        ok "Exit '$name' added (type: $type)"
        info "Activate it with: $0 --set-exit $name"
        return
    fi

    # Otherwise: a WireGuard config.
    grep -qi '^\[Interface\]' "$tmp" || { err "Not a URI and not a WireGuard config (no socks5://, ss://, or [Interface])"; rm -f "$tmp"; exit 1; }
    grep -qi '^\[Peer\]'      "$tmp" || { err "Invalid WireGuard config (missing [Peer])"; rm -f "$tmp"; exit 1; }
    command -v wg-quick >/dev/null 2>&1 || { err "wireguard-tools (wg-quick) is not installed"; rm -f "$tmp"; exit 1; }

    # Force "Table = off" so wg-quick never installs a global default route.
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
    rm -f "$(exit_conf_path "$name")" "$(exit_singbox_conf "$name")" "$(exit_type_file "$name")"
    ok "Exit '$name' removed"
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

    exit_exists "$name" || { err "Unknown exit '$name'. Add it first: $0 --add-exit $name <conf|uri>"; exit 1; }

    local iface; iface="$(exit_iface "$name")"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        exit_up "$name" || { err "Failed to bring up exit '$name'"; exit 1; }
    fi
    exit_wait_device "$name" || { err "Device $iface did not appear; check the exit's service/logs"; exit 1; }
    ip route replace default dev "$iface" table "${EXIT_TABLE}"
    echo "$name" > "${CONF_DIR}/current-exit"
    # Free the previously-active exit's resources (saves memory on small hosts).
    [[ "$prev" != "local" && "$prev" != "$name" ]] && exit_down "$prev"
    ok "Egress switched to: $name ($(exit_type "$name"), dev $iface)"
    preflight_exit "$name"
    info "Verify the public exit IP with:"
    info "  curl --interface ${iface} -4 -s https://api.ipify.org; echo"
}

# Regenerate the 'smart' router config from RULES_FILE + POLICY_MAP, validate it
# with sing-box, and install it (reloading if smart is the active exit).
regen_smart() {
    [[ -f "${RULES_FILE}" ]] || { err "No rules yet. Use --set-rules or --import-rules first."; exit 1; }
    [[ -f "${SINGBOX_ROUTER_GEN}" ]] || { err "Router generator missing: ${SINGBOX_ROUTER_GEN}"; exit 1; }
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"; chmod 700 "${EXITS_DIR}"
    [[ -x /usr/local/bin/proxy-gateway-apply-exit.sh ]] || setup_exit_switching >/dev/null
    ensure_singbox || exit 1
    install_singbox_unit

    info "Building smart router config (fetching/compiling rule-sets — may take a while)..."
    # Effective rules = built-in defaults (e.g. speedtest) first, then user rules.
    local eff; eff="$(mktemp)"
    [[ -f "${RULES_DEFAULT}" ]] && cat "${RULES_DEFAULT}" >> "$eff"
    cat "${RULES_FILE}" >> "$eff"
    local json gen_err; json="$(exit_singbox_conf smart)"
    if ! gen_err="$(EXITS_DIR="${EXITS_DIR}" WG_DIR="${WG_DIR}" PGW_RULESET_CACHE="${RULESET_CACHE}" \
                    PGW_POLICY_MAP="${POLICY_MAP}" SINGBOX_BIN="${SINGBOX_BIN}" \
                    python3 "${SINGBOX_ROUTER_GEN}" "$eff" 2>&1 >"${json}.tmp")"; then
        err "Rules error: ${gen_err}"; rm -f "${json}.tmp" "$eff"; exit 1
    fi
    rm -f "$eff"
    if ! "${SINGBOX_BIN}" check -c "${json}.tmp" >/dev/null 2>&1; then
        err "sing-box rejected the generated router config:"
        "${SINGBOX_BIN}" check -c "${json}.tmp" 2>&1 | sed 's/^/    /' >&2
        rm -f "${json}.tmp"; exit 1
    fi
    install -m 600 "${json}.tmp" "${json}"; rm -f "${json}.tmp"
    echo router > "$(exit_type_file smart)"

    local n; n="$(grep -cvE '^[[:space:]]*(#|;|$)' "${RULES_FILE}" 2>/dev/null || echo 0)"
    ok "Smart router rebuilt (${n} rules)."
    local cur="local"
    [[ -f "${CONF_DIR}/current-exit" ]] && cur="$(cat "${CONF_DIR}/current-exit" 2>/dev/null || echo local)"
    if [[ "$cur" == "smart" ]]; then
        systemctl restart "proxy-gateway-singbox@smart.service" 2>/dev/null || true
        /usr/local/bin/proxy-gateway-apply-exit.sh >/dev/null 2>&1 || true
        ok "Reloaded the active smart router."
    else
        info "Activate smart routing with: $0 --set-exit smart"
    fi
}

# Install/refresh hand-written rules for the 'smart' exit.
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
    install -m 644 "$tmp" "${RULES_FILE}"; rm -f "$tmp"
    init_policy_map
    regen_smart
}

# Import a full rule list: convert -> rules.conf, seed the policy map,
# then rebuild the smart router.
import_rules() {
    local src="${1:-}"
    [[ -n "$src" && -f "$src" ]] || { err "Usage: $0 --import-rules <rule-list-file>"; exit 1; }
    [[ -f "${RULES_IMPORT}" ]] || { err "rule converter missing: ${RULES_IMPORT}"; exit 1; }
    ensure_proxy_user
    mkdir -p "${EXITS_DIR}" "${RULESET_CACHE}"

    # Optional simplification: PGW_KEEP_CATEGORIES (e.g. "AI") keeps only those
    # categories distinct and collapses the rest into Proxy/direct/block. The
    # choice is remembered so future imports stay consistent.
    local keep="${PGW_KEEP_CATEGORIES:-}"
    [[ -z "$keep" && -f "${KEEP_FILE}" ]] && keep="$(cat "${KEEP_FILE}" 2>/dev/null)"
    if [[ -n "$keep" ]]; then
        mkdir -p "$(dirname "${KEEP_FILE}")"; printf '%s' "$keep" > "${KEEP_FILE}"
        info "Simplifying categories — keeping: ${keep} (others -> Proxy/direct/block)"
    fi
    # Categories forced to direct (e.g. 小红书,bilibili,iqiyi). Remembered too.
    local direct="${PGW_DIRECT_CATEGORIES:-}"
    [[ -z "$direct" && -f "${DIRECT_FILE}" ]] && direct="$(cat "${DIRECT_FILE}" 2>/dev/null)"
    if [[ -n "$direct" ]]; then
        mkdir -p "$(dirname "${DIRECT_FILE}")"; printf '%s' "$direct" > "${DIRECT_FILE}"
        info "Forcing to direct: ${direct}"
    fi

    info "Converting rule list..."
    local summary
    summary="$(PGW_KEEP_CATEGORIES="$keep" PGW_DIRECT_CATEGORIES="$direct" python3 "${RULES_IMPORT}" "$src" 2>/tmp/pgw-import.err >"${RULES_FILE}.tmp")" || true
    if [[ ! -s "${RULES_FILE}.tmp" ]]; then
        err "Conversion produced no rules:"; sed 's/^/    /' /tmp/pgw-import.err >&2; rm -f "${RULES_FILE}.tmp"; exit 1
    fi
    install -m 644 "${RULES_FILE}.tmp" "${RULES_FILE}"; rm -f "${RULES_FILE}.tmp"
    grep -E '^(converted|CATEGORIES)' /tmp/pgw-import.err | sed 's/^/[INFO] /'

    init_policy_map
    info "Categories were seeded in ${POLICY_MAP} (edit on the bot or with --set-policy)."
    regen_smart
}

# Rebuild POLICY_MAP to match the current rules: keep existing mappings for
# surviving categories, seed new ones, drop stale ones. 'direct'/'block'
# literals are NOT categories (no mapping needed).
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
    local cat="${1:-}" target="${2:-}"
    [[ -z "$cat" || -z "$target" ]] && { err "Usage: $0 --set-policy <category> <exit|direct|block>"; exit 1; }
    # Validate target.
    case "$target" in
        direct|block) ;;
        *) exit_exists "$target" || { err "Unknown target '$target' (use an exit name, direct, or block)"; exit 1; } ;;
    esac
    mkdir -p "$(dirname "${POLICY_MAP}")"; touch "${POLICY_MAP}"
    # Remove existing mapping for this category, then add the new one.
    grep -vF "${cat}=" "${POLICY_MAP}" > "${POLICY_MAP}.tmp" 2>/dev/null || true
    mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    printf '%s=%s\n' "$cat" "$target" >> "${POLICY_MAP}"
    ok "Mapped category '$cat' -> $target"
    regen_smart
}

show_policy() {
    if [[ -s "${POLICY_MAP}" ]]; then
        sort "${POLICY_MAP}"
    else
        info "No policy map yet. Import rules first: $0 --import-rules <file>"
    fi
}

# Remove a category (rule group) from the policy map. Rules still targeting it
# fall back to the router's default (direct) until re-mapped or edited.
del_policy() {
    local cat="${1:-}"
    [[ -z "$cat" ]] && { err "Usage: $0 --del-policy <category>"; exit 1; }
    [[ -f "${POLICY_MAP}" ]] || { err "No policy map yet."; exit 1; }
    awk -F= -v c="$cat" '$1!=c' "${POLICY_MAP}" > "${POLICY_MAP}.tmp" && mv "${POLICY_MAP}.tmp" "${POLICY_MAP}"
    ok "Removed rule group '$cat'"
    regen_smart
}

# Rename a category (rule group): update the policy map key AND every rule whose
# target is that category, then rebuild — all in one pass.
rename_policy() {
    local old="${1:-}" new="${2:-}"
    [[ -z "$old" || -z "$new" ]] && { err "Usage: $0 --rename-policy <old> <new>"; exit 1; }
    [[ "$new" =~ ^[A-Za-z0-9_-]+$ || "$new" =~ [^[:ascii:]] ]] || { err "Invalid new name"; exit 1; }
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
    ok "Renamed rule group '$old' -> '$new'"
    regen_smart
}

# One-click: route a single domain to a target, handling BOTH layers —
# hijack it into the gateway (GFWList) AND add a top-priority smart rule.
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
    # 1) smart rule, top priority (replace any prior rule for the same domain)
    grep -vE "^DOMAIN-SUFFIX,${esc}," "${RULES_FILE}" > "${RULES_FILE}.tmp" 2>/dev/null || true
    { echo "$rule"; cat "${RULES_FILE}.tmp"; } > "${RULES_FILE}"; rm -f "${RULES_FILE}.tmp"
    # 2) hijack layer
    local extra="/etc/dnsdist/gfwlist-extra-local.txt" lua="/etc/dnsdist/gfwlist.lua"
    mkdir -p /etc/dnsdist; touch "$extra"
    if [[ "$target" == "direct" ]]; then
        grep -vxF "$domain" "$extra" > "$extra.tmp" 2>/dev/null || true; mv "$extra.tmp" "$extra"
        [[ -f "$lua" ]] && sed -i "/newDNSName(\"${esc}\")/d" "$lua"
    else
        grep -qxF "$domain" "$extra" || echo "$domain" >> "$extra"
        if [[ -f "$lua" ]] && ! grep -q "newDNSName(\"${esc}\")" "$lua"; then
            echo "gfwList:add(newDNSName(\"${domain}\"))" >> "$lua"
        fi
    fi
    systemctl restart dnsdist 2>/dev/null || true   # dnsdist can't hot-reload; restart applies config
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

# =============================================================================
# Telegram control bot (optional)
# =============================================================================
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
    # Keep only digits and separators, then normalise to comma-separated.
    ids="$(printf '%s' "$ids" | tr ', ' '\n\n' | grep -E '^[0-9]+$' | paste -sd ',' - 2>/dev/null || true)"

    local py; py="$(command -v python3 || echo /usr/bin/python3)"

    info "Installing Telegram control bot..."
    mkdir -p "${BASE_DIR}/bin"
    if [[ ! -f "${SCRIPT_DIR}/tgbot.py" ]]; then
        err "tgbot.py not found in ${SCRIPT_DIR}"
        return 1
    fi
    install -m 0755 "${SCRIPT_DIR}/tgbot.py" "${BASE_DIR}/bin/tgbot.py"
    # Stable management entrypoint the bot shells out to.
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

# =============================================================================
# Low-memory Go runtime caps (drop-ins for the two Go proxies)
# =============================================================================
apply_lowmem_go_limits() {
    local d
    for svc in quic-proxy china-dns-race-proxy; do
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

# =============================================================================
# Start services
# =============================================================================
start_services() {
    info "Starting services..."
    systemctl restart china-dns-race-proxy || { err "china-dns-race-proxy failed to start"; journalctl -u china-dns-race-proxy --no-pager -n 20; exit 1; }
    systemctl restart dnsdist || { err "dnsdist failed to start"; journalctl -u dnsdist --no-pager -n 20; exit 1; }
    systemctl restart sniproxy || { err "sniproxy failed to start"; journalctl -u sniproxy --no-pager -n 20; exit 1; }
    systemctl restart quic-proxy || { err "quic-proxy failed to start"; journalctl -u quic-proxy --no-pager -n 20; exit 1; }
    ok "All services started"
}

# =============================================================================
# Cron / Systemd timers
# =============================================================================
setup_schedules() {
    info "Setting up automatic updates..."

    # Weekly rule update (Sunday 03:00)
    cat > /etc/systemd/system/update-dnsdist-rules.timer <<'EOF'
[Unit]
Description=Weekly dnsdist rules update

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/update-dnsdist-rules.service <<'EOF'
[Unit]
Description=Update dnsdist GFWList/ChinaList rules

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-dnsdist-rules.sh
EOF

    systemctl daemon-reload
    systemctl enable --now update-dnsdist-rules.timer

    install_certbot_firewall_hooks

    # Ensure certbot timer is enabled
    systemctl enable --now certbot.timer 2>/dev/null || true

    ok "Schedules configured (rules: weekly, cert: auto)"
}

# =============================================================================
# Status / Uninstall / Helpers
# =============================================================================
show_status() {
    echo "=========================================="
    echo "      Proxy Gateway Status"
    echo "=========================================="
    for svc in dnsdist sniproxy quic-proxy china-dns-race-proxy; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        if [[ "$status" == "active" ]]; then
            echo -e "$svc: ${GREEN}running${NC}"
        else
            echo -e "$svc: ${RED}$status${NC}"
        fi
    done
    # iOS profile is socket-activated: report the listening socket, not a daemon.
    ios_status=$(systemctl is-active proxy-gateway-ios-profile.socket 2>/dev/null || echo "unknown")
    if [[ "$ios_status" == "active" ]]; then
        echo -e "proxy-gateway-ios-profile.socket: ${GREEN}listening${NC}"
    else
        echo -e "proxy-gateway-ios-profile.socket: ${RED}$ios_status${NC}"
    fi
    # Telegram bot (optional)
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
    if [[ -f /etc/dnsdist/.cache_size ]]; then
        local cs; cs="$(cat /etc/dnsdist/.cache_size 2>/dev/null || echo '?')"
        echo "Mem profile: $([[ "$cs" -le 50000 ]] 2>/dev/null && echo low-memory || echo standard) (dnsdist cache=${cs})"
    fi
    echo "=========================================="
}

do_uninstall() {
    warn "This will remove sniproxy, quic-proxy, china-dns-race-proxy, dnsdist configs, and rules."
    read -r -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled"; exit 0; }

    # Tear down egress exit routing before removing config.
    set_exit local 2>/dev/null || true
    ip rule del fwmark "${EXIT_MARK}" table "${EXIT_TABLE}" 2>/dev/null || true
    ip route flush table "${EXIT_TABLE}" 2>/dev/null || true
    shopt -s nullglob
    for f in "${WG_DIR}"/pgw-*.conf; do
        wg-quick down "$(basename "$f" .conf)" 2>/dev/null || true
    done
    for f in "${EXITS_DIR}"/*.type; do
        systemctl stop "proxy-gateway-singbox@$(basename "$f" .type).service" 2>/dev/null || true
    done
    shopt -u nullglob

    systemctl stop dnsdist sniproxy quic-proxy china-dns-race-proxy proxy-gateway-ios-profile.socket proxy-gateway-ios-profile proxy-gateway-exit proxy-gateway-tgbot proxy-gateway-api 2>/dev/null || true
    systemctl disable dnsdist sniproxy quic-proxy china-dns-race-proxy proxy-gateway-ios-profile.socket proxy-gateway-ios-profile proxy-gateway-exit proxy-gateway-tgbot proxy-gateway-api 2>/dev/null || true
    rm -f /etc/systemd/system/{sniproxy,quic-proxy,china-dns-race-proxy,proxy-gateway-ios-profile,update-dnsdist-rules,proxy-gateway-exit,proxy-gateway-tgbot,proxy-gateway-api}.*
    rm -f /etc/systemd/system/proxy-gateway-ios-profile@.service /etc/systemd/system/proxy-gateway-singbox@.service
    rm -rf /etc/systemd/system/quic-proxy.service.d /etc/systemd/system/china-dns-race-proxy.service.d
    systemctl daemon-reload

    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/dnsdist /usr/local/bin/update-dnsdist-rules.sh
    rm -f /usr/local/sbin/sniproxy
    rm -f /usr/local/bin/proxy-gateway-apply-exit.sh
    rm -f "${WG_DIR}"/pgw-*.conf
    rm -rf /etc/proxy-gateway
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-dnsdist.sh
    rm -f /etc/sysctl.d/99-proxy-gateway.conf
    rm -f /etc/profile.d/go.sh
    userdel "${EXIT_USER}" 2>/dev/null || true

    # Optionally remove certbot certs
    warn "SSL certificates in /etc/letsencrypt/live/ are kept. Remove manually if needed."
    if [[ -e /swapfile ]]; then
        warn "Swapfile /swapfile is kept. To remove: swapoff /swapfile && rm -f /swapfile && sed -i '/^\\/swapfile /d' /etc/fstab"
    fi

    ok "Uninstall completed"
}

force_renew_cert() {
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot renew."
        exit 1
    fi

    local certbot_cmd
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)

    open_cert_http_port
    trap restore_reverse_proxy_firewall RETURN

    # Run once and capture output; only retry on the known Python error so we
    # don't burn Let's Encrypt rate-limit attempts probing for it. The `if`
    # prevents the failing run from tripping `set -e`.
    local out rc
    if out="$("${certbot_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
    printf '%s\n' "$out"
    if [[ $rc -ne 0 ]]; then
        if grep -q "AttributeError" <<<"$out"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            pip3 install --upgrade --break-system-packages certbot josepy cryptography 2>/dev/null || \
                pip3 install --upgrade certbot josepy cryptography 2>/dev/null || true
            info "Retrying certificate renewal..."
            "${certbot_cmd[@]}" || { err "Certificate renewal failed"; exit 1; }
        else
            err "Certificate renewal failed"
            exit 1
        fi
    fi

    # Re-copy certificates to dnsdist-readable location
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/dnsdist/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/dnsdist/certs/privkey.pem
        chown -R _dnsdist:_dnsdist /etc/dnsdist/certs/
        chmod 640 /etc/dnsdist/certs/*.pem
    fi

    if systemctl is-active --quiet dnsdist; then
        systemctl restart dnsdist && ok "Certificate renewed and dnsdist reloaded"
    else
        systemctl start dnsdist && ok "Certificate renewed and dnsdist started"
    fi
}

regenerate_ios_profile() {
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    elif [[ -f /etc/dnsdist/.domain ]]; then
        DOMAIN=$(cat /etc/dnsdist/.domain)
    fi

    if [[ -f /etc/dnsdist/.public_ip ]]; then
        PUBLIC_IP=$(cat /etc/dnsdist/.public_ip)
    else
        get_public_ip
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot generate iOS profile."
        exit 1
    fi

    generate_ios_profile
}

# =============================================================================
# Main installation flow
# =============================================================================
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
    install_cert
    configure_overseas_dns
    install_sniproxy
    install_quic_proxy
    install_china_dns_race_proxy
    install_dnsdist
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
    echo "  $0 --add-exit <name> <wg.conf|socks5://...|ss://...>"
    echo "  $0 --set-exit <name|local>"
    echo "  $0 --setup-tgbot                 # 配置/启用 Telegram 控制 Bot"
    echo "  $0 --uninstall"
    echo "=========================================="
}

# =============================================================================
# Entrypoint
# =============================================================================
case "${1:-}" in
    --status)
        get_public_ip 2>/dev/null || true
        show_status
        ;;
    --update-rules)
        /usr/local/bin/update-dnsdist-rules.sh
        ;;
    --renew-cert)
        force_renew_cert
        ;;
    --list-exits)
        list_exits
        ;;
    --add-exit)
        check_root
        add_exit "${2:-}" "${3:-}"
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
