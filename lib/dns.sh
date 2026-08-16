#!/usr/bin/env bash
# 5GPN-X module: dns
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

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

