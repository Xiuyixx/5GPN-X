#!/usr/bin/env bash
# 5GPN-X module: cert
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

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

is_valid_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]
}

generate_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        DOMAIN="${DOMAIN,,}"  # normalize to lowercase (certbot always lowercases)
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
            DOMAIN="${DOMAIN,,}"  # normalize to lowercase
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
        --pre-hook /usr/local/bin/5gpn-open-cert-http.sh \
        --post-hook /usr/local/bin/5gpn-restore-firewall.sh)
    certbot_cmd_force=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/5gpn-open-cert-http.sh \
        --post-hook /usr/local/bin/5gpn-restore-firewall.sh)
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
    cat > /usr/local/bin/5gpn-open-cert-http.sh <<'EOF'
#!/bin/bash
set -e
systemctl stop sniproxy 2>/dev/null || true
systemctl stop wa-shim 2>/dev/null || true
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept comment '"5gpn-cert-http"' 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment 5gpn-cert-http -j ACCEPT 2>/dev/null || true
fi
EOF
    cat > /usr/local/bin/5gpn-restore-firewall.sh <<'EOF'
#!/bin/bash
set -e
# Delete only the tagged temporary rule. Reloading /etc/nftables.conf here
# would be wrong when the firewall is user-managed (FIREWALL_MODE=preserve).
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    while h="$(nft --handle list chain inet filter input 2>/dev/null | awk '/5gpn-cert-http/ { print $NF; exit }')" && [ -n "$h" ]; do
        nft delete rule inet filter input handle "$h" 2>/dev/null || break
    done
fi
if command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment 5gpn-cert-http -j ACCEPT 2>/dev/null; do :; done
fi
systemctl start sniproxy 2>/dev/null || true
systemctl start wa-shim 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/5gpn-open-cert-http.sh /usr/local/bin/5gpn-restore-firewall.sh
    cp /usr/local/bin/5gpn-open-cert-http.sh /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open-http.sh
    cp /usr/local/bin/5gpn-restore-firewall.sh /etc/letsencrypt/renewal-hooks/post/90-5gpn-restore-firewall.sh
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-5gpn-restore-firewall.sh
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
            --pre-hook /usr/local/bin/5gpn-open-cert-http.sh \
            --post-hook /usr/local/bin/5gpn-restore-firewall.sh)
    else
        certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
            --pre-hook /usr/local/bin/5gpn-open-cert-http.sh \
            --post-hook /usr/local/bin/5gpn-restore-firewall.sh)
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

