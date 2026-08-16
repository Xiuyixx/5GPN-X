#!/usr/bin/env bash
# 5GPN-X module: exits
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash
# SC2034: loop index `i` in exit_wait_device is a `seq` counter kept verbatim
# from the original single-file install.sh; behaviour is unchanged.
# shellcheck disable=SC2034

exit_conf_path()    { echo "${WG_DIR}/pgw-${1}.conf"; }       # wireguard config

exit_iface() {
    local name="$1"
    if [[ "$name" =~ ^[A-Za-z0-9_-]{1,11}$ ]]; then
        echo "pgw-${name}"
    else
        printf 'pgw-%s\n' "$(printf '%s' "$name" | sha256sum | cut -c1-11)"
    fi
}

exit_mihomo_unit() { systemd-escape --template=5gpn-mihomo@.service "$1"; }

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
    cat > /etc/systemd/system/5gpn-mihomo@.service <<EOF
[Unit]
Description=Proxy Gateway mihomo exit (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${CONF_DIR}/mihomo/%I -f ${EXITS_DIR}/%I.yaml
# Recreating the TUN drops the table-100 route; re-apply it after (re)start.
ExecStartPost=-/usr/local/bin/5gpn-apply-exit.sh
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
    systemctl stop '5gpn-singbox@*.service' 2>/dev/null || true
    rm -f /etc/systemd/system/5gpn-singbox@.service
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
    systemctl stop '5gpn-singbox@*.service' 2>/dev/null || true
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
    /usr/local/bin/5gpn-apply-exit.sh
}

install_apply_exit_helper() {
    cat > /usr/local/bin/5gpn-apply-exit.sh <<EOF
#!/bin/bash
# Re-apply the currently selected 5gpn egress exit.
set -e
MARK="${EXIT_MARK}"
TABLE="${EXIT_TABLE}"
STATE="${CONF_DIR}/current-exit"
EXITS_DIR="${EXITS_DIR}"
WG_DIR="${WG_DIR}"
EOF
    cat >> /usr/local/bin/5gpn-apply-exit.sh <<'EOF'

# Ensure the egress-marking nftables table exists; it may have been wiped by a
# host firewall reload (flush ruleset) since the last apply.
if command -v nft >/dev/null 2>&1 && [[ -f /etc/5gpn/pgw-exit.nft ]]; then
    nft -f /etc/5gpn/pgw-exit.nft 2>/dev/null || true
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
mihomo_unit() { systemd-escape --template=5gpn-mihomo@.service "$1"; }

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
    chmod +x /usr/local/bin/5gpn-apply-exit.sh
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
    cat > /etc/systemd/system/5gpn-exit.service <<'EOF'
[Unit]
Description=Proxy Gateway egress exit selector
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/5gpn-apply-exit.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable 5gpn-exit.service 2>/dev/null || true
    /usr/local/bin/5gpn-apply-exit.sh >/dev/null 2>&1 || true
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
    [[ -x /usr/local/bin/5gpn-apply-exit.sh ]] || setup_exit_switching >/dev/null
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

