#!/usr/bin/env bash
# 5GPN-X module: common
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash
# SC2034: MAKE_JOBS / PACKET_CACHE_SIZE are assigned here and consumed in
# lib/services.sh; per-file shellcheck cannot see that cross-module use that the
# original single-file install.sh made obvious. Behaviour is unchanged.
# shellcheck disable=SC2034

info()  { printf '%b  %s%b\n' "${DIM:-}" "$*" "${NC:-}"; }

ok()    { printf '%b✓%b %s\n' "${GREEN:-}" "${NC:-}" "$*"; }

warn()  { printf '%b!%b %s\n' "${YELLOW:-}" "${NC:-}" "$*"; }

err()   { printf '%b✗%b %s\n' "${RED:-}" "${NC:-}" "$*" >&2; }

init_install_log() {
    INSTALL_LOG="${INSTALL_LOG:-/var/log/5gpn-install.log}"
    mkdir -p "$(dirname "$INSTALL_LOG")"
    : > "$INSTALL_LOG"
    chmod 0600 "$INSTALL_LOG"
    printf '[%s] 5GPN-X installation started\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$INSTALL_LOG"
}

run_install_step() {
    local label="$1" rc last_error had_errexit=0
    shift
    if [[ -t 1 ]]; then
        printf '  ... %s' "$label"
    fi
    [[ $- == *e* ]] && had_errexit=1
    set +e
    (set -e; "$@") >>"$INSTALL_LOG" 2>&1
    rc=$?
    [[ "$had_errexit" -eq 0 ]] || set -e
    if [[ "$rc" -eq 0 ]]; then
        if [[ -t 1 ]]; then
            printf '\r\033[2K'
        fi
        printf '  %b✓%b %s\n' "${GREEN:-}" "${NC:-}" "$label"
        return 0
    fi
    if [[ -t 1 ]]; then
        printf '\r\033[2K'
    fi
    printf '  %b✗%b %s\n' "${RED:-}" "${NC:-}" "$label" >&2
    last_error="$(tail -n 80 "$INSTALL_LOG" 2>/dev/null | \
        sed $'s/\033\\[[0-9;]*m//g' | \
        grep -Ei '(error|failed|failure|cannot|missing|invalid|失败|错误|无法|不存在)' | tail -n 1 || true)"
    [[ -n "$last_error" ]] && printf '      %s\n' "$last_error" >&2
    printf '      详细日志: %s\n' "$INSTALL_LOG" >&2
    return "$rc"
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

collect_swap_preferences() {
    [[ "${LOWMEM:-0}" == "1" ]] || return 0
    [[ "$(wc -l < /proc/swaps 2>/dev/null || echo 1)" -le 1 ]] || return 0
    [[ ! -e /swapfile ]] || return 0
    if [[ -z "${SWAP_ENABLE:-}" && -t 0 ]]; then
        read -r -p "检测到低内存且没有 swap，创建 swap？[y/N]: " SWAP_ENABLE || true
    fi
    if [[ "${SWAP_ENABLE^^}" =~ ^(Y|YES)$ && -z "${SWAP_SIZE:-}" && -t 0 ]]; then
        read -r -p "Swap 大小 [1G]: " SWAP_SIZE || true
        SWAP_SIZE="${SWAP_SIZE:-1G}"
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

systemd_unit_for_pid() {
    local pid="${1:-}"
    [[ -z "$pid" || ! -r "/proc/$pid/cgroup" ]] && return 0
    grep -aoE '[^/]+\.service' "/proc/$pid/cgroup" | head -n1 || true
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

ensure_proxy_user() {
    if id -u "${EXIT_USER}" >/dev/null 2>&1; then
        return 0
    fi
    useradd --system --no-create-home --shell /usr/sbin/nologin "${EXIT_USER}" 2>/dev/null \
        || useradd -r -s /sbin/nologin "${EXIT_USER}" 2>/dev/null \
        || true
    id -u "${EXIT_USER}" >/dev/null 2>&1 || warn "Could not create egress user ${EXIT_USER}"
}

ensure_mosdns_user() {
    if ! id mosdns >/dev/null 2>&1; then
        useradd --system --home-dir /etc/mosdns --shell /usr/sbin/nologin mosdns
    fi
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

port53_pids() {
    ss -H -lnptu 2>/dev/null | awk '$5 ~ /(^|\[|:)53$/ {print}' | grep -oP 'pid=\K[0-9]+' | sort -u || true
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

wait_for_port53_free() {
    local timeout="${1:-10}" i
    for ((i=0; i<timeout; i++)); do
        [[ -z "$(port53_pids)" ]] && return 0
        sleep 1
    done
    [[ -z "$(port53_pids)" ]]
}
