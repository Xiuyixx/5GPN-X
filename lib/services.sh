#!/usr/bin/env bash
# 5GPN-X module: services
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash
# SC2164: `cd` calls extracted verbatim from the original single-file install.sh;
# behaviour is unchanged. Suppressed to keep -x lint clean.
# shellcheck disable=SC2164

install_deps() {
    info "Installing system dependencies..."
    local pcre_dev_pkg="libpcre3-dev" pkg_log package_install_ok=0 temporary_pkg_log=0
    if [[ -n "${INSTALL_LOG:-}" ]]; then
        pkg_log="$INSTALL_LOG"
    else
        pkg_log="$(mktemp /tmp/5gpn-packages.XXXXXX.log)"
        temporary_pkg_log=1
    fi
    if [[ "${OS:-}" == "debian" && "${VER%%.*}" -ge 13 ]]; then
        pcre_dev_pkg="libpcre2-dev"
    fi
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            if ! apt-get update -qq >>"$pkg_log" 2>&1; then
                warn "apt update failed; trying a direct public DNS path for Debian mirrors..."
                if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
                    sed -i 's/^URIs: .*/URIs: http:\/\/deb.debian.org\/debian/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
                fi
                if [[ -f /etc/apt/sources.list ]]; then
                    sed -i 's|^[[:space:]]*deb[[:space:]]\+mirror+file:/etc/apt/mirrors/.*|deb http://deb.debian.org/debian trixie main|g' /etc/apt/sources.list 2>/dev/null || true
                fi
                if ! apt-get update -qq >>"$pkg_log" 2>&1; then
                    err "apt update failed. Package-manager log: $pkg_log"
                    grep -Ei '(^E:|^Error:|error|failed)' "$pkg_log" | tail -n 8 | sed 's/^/  /' >&2 || true
                    return 1
                fi
            fi
            if apt-get install -y -qq \
                build-essential git wget curl ca-certificates \
                libev-dev "${pcre_dev_pkg}" libudns-dev libssl-dev \
                autoconf automake libtool pkg-config \
                certbot python3-certbot-dns-cloudflare \
                python3 python3-pip jq libcap2-bin \
                nftables qrencode wireguard-tools >>"$pkg_log" 2>&1; then
                package_install_ok=1
            else
                warn "Some system packages could not be installed; continuing with required-tool checks."
                info "Package-manager log: $pkg_log"
            fi
            ;;
        dnf|yum)
            if "$PKG_MGR" install -y -q \
                gcc gcc-c++ make git wget curl ca-certificates \
                libev-devel pcre-devel openssl-devel \
                autoconf automake libtool pkgconfig \
                certbot python3-certbot-dns-cloudflare \
                python3 python3-pip jq libcap-ng-utils \
                nftables qrencode wireguard-tools >>"$pkg_log" 2>&1; then
                package_install_ok=1
            else
                warn "Some system packages could not be installed; continuing with required-tool checks."
                info "Package-manager log: $pkg_log"
            fi
            ;;
    esac
    [[ "$package_install_ok" -eq 1 ]] && ok "System packages installed"
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
            pip3 install --upgrade --break-system-packages certbot josepy cryptography >>"$pkg_log" 2>&1 || \
                pip3 install --upgrade certbot josepy cryptography >>"$pkg_log" 2>&1 || true
        fi
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        err "Required package 'certbot' was not installed successfully."
        err "Please check the package-manager log: $pkg_log"
        exit 1
    fi
    if [[ "$package_install_ok" -eq 1 && "$temporary_pkg_log" -eq 1 ]]; then
        rm -f "$pkg_log"
    fi
    return 0
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
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "${tmpdir}/${asset}"
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

install_sniproxy() {
    ensure_proxy_user
    if ! command -v sniproxy >/dev/null 2>&1; then
        info "Compiling sniproxy (TCP SNI proxy)..."
        local build_log temporary_build_log=0
        if [[ -n "${INSTALL_LOG:-}" ]]; then
            build_log="$INSTALL_LOG"
        else
            build_log="$(mktemp /tmp/5gpn-sniproxy-build.XXXXXX.log)"
            temporary_build_log=1
        fi
        if ! (
            set -e
            mkdir -p "$SRC_DIR"
            cd "$SRC_DIR"
            if [[ ! -d sniproxy ]]; then
                git clone --quiet --depth=1 https://github.com/dlundquist/sniproxy.git
            fi
            cd sniproxy
            DEBEMAIL="root@localhost" DEBFULLNAME="root" ./autogen.sh
            ./configure --prefix=/usr/local --sysconfdir=/etc --enable-dns
            make -j"${MAKE_JOBS:-$(nproc)}"
            make install
        ) >>"$build_log" 2>&1; then
            err "sniproxy 编译失败。构建日志: $build_log"
            tail -n 20 "$build_log" | sed 's/^/  /' >&2 || true
            exit 1
        fi
        [[ "$temporary_build_log" -eq 1 ]] && rm -f "$build_log"
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
    systemctl enable --quiet sniproxy
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
        local build_log temporary_build_log=0
        if [[ -n "${INSTALL_LOG:-}" ]]; then
            build_log="$INSTALL_LOG"
        else
            build_log="$(mktemp /tmp/5gpn-quicproxy-build.XXXXXX.log)"
            temporary_build_log=1
        fi
        mkdir -p "${BASE_DIR}/bin"
        mkdir -p "${SRC_DIR}"
        cp "${LIB_DIR}/quic-proxy.go" "${SRC_DIR}/quic-proxy.go"
        export PATH=$PATH:/usr/local/go/bin
        if ! (cd "${SRC_DIR}" && go build -ldflags="-s -w" -o "${BASE_DIR}/bin/quic-proxy" quic-proxy.go) >>"$build_log" 2>&1; then
            err "quic-proxy 编译失败。构建日志: $build_log"
            tail -n 20 "$build_log" | sed 's/^/  /' >&2 || true
            exit 1
        fi
        [[ "$temporary_build_log" -eq 1 ]] && rm -f "$build_log"
    else
        info "quic-proxy already compiled"
    fi
    cat > /etc/systemd/system/quic-proxy.service <<'EOF'
[Unit]
Description=quic-proxy (UDP/QUIC SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/opt/5gpn/bin/quic-proxy -l 0.0.0.0:443
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
    systemctl enable --quiet quic-proxy
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
    systemctl enable --quiet mosdns
    ok "mosdns configured"
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
            <string>com.5gpn.${DOMAIN}.dnssettings</string>
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
    <string>com.5gpn.${DOMAIN}</string>
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
    if systemctl list-unit-files 2>/dev/null | grep -q '^5gpn-ios-profile\.service'; then
        systemctl disable --now 5gpn-ios-profile.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/5gpn-ios-profile.service
    cat > /etc/systemd/system/5gpn-ios-profile.socket <<EOF
[Unit]
Description=Proxy Gateway iOS profile HTTP socket

[Socket]
ListenStream=0.0.0.0:${IOS_PROFILE_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
EOF
    cat > /etc/systemd/system/5gpn-ios-profile@.service <<EOF
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
    systemctl enable --quiet --now 5gpn-ios-profile.socket
    echo "$profile_url" > "${WWW_DIR}/ios-profile-url.txt"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$profile_url" > "${WWW_DIR}/ios-dot.qr.txt"
    else
        warn "qrencode is not installed; QR code skipped. Profile URL: $profile_url"
    fi
    ok "iOS profile ready: $profile_url"
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

collect_tgbot_settings() {
    local token="${TG_BOT_TOKEN:-}"
    local ids="${TG_ADMIN_IDS:-}"
    if [[ -z "$token" && -t 0 ]]; then
        echo ""
        info "可选：配置 Telegram 控制 Bot（直接在 Telegram 上运维）"
        read -r -p "Telegram Bot Token (留空跳过): " token
    fi
    if [[ -z "$token" ]]; then
        TG_BOT_TOKEN=""
        TG_ADMIN_IDS=""
        TG_BOT_SETTINGS_COLLECTED=1
        return 0
    fi
    if [[ -z "$ids" && -t 0 ]]; then
        read -r -p "授权的 Telegram 数字 ID（逗号分隔，可留空，稍后用 /id 获取再填）: " ids
    fi
    ids="$(printf '%s' "$ids" | tr ', ' '\n' | grep -E '^[0-9]+$' | paste -sd ',' - 2>/dev/null || true)"
    TG_BOT_TOKEN="$token"
    TG_ADMIN_IDS="$ids"
    TG_BOT_SETTINGS_COLLECTED=1
}

setup_tgbot() {
    [[ "${TG_BOT_SETTINGS_COLLECTED:-0}" == "1" ]] || collect_tgbot_settings
    local token="${TG_BOT_TOKEN:-}"
    local ids="${TG_ADMIN_IDS:-}"
    if [[ -z "$token" ]]; then
        info "未提供 Telegram Bot Token，跳过 tgbot。以后可运行: $0 --setup-tgbot"
        return 0
    fi
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    info "Installing Telegram control bot..."
    mkdir -p "${BASE_DIR}/bin"
    if [[ ! -f "${LIB_DIR}/tgbot.py" ]]; then
        err "tgbot.py not found in ${LIB_DIR}"
        return 1
    fi
    install -m 0755 "${LIB_DIR}/tgbot.py" "${BASE_DIR}/bin/tgbot.py"
    install -m 0755 "${SCRIPT_PATH}" "${BASE_DIR}/bin/5gpn-ctl"
    mkdir -p "${CONF_DIR}"
    cat > "${CONF_DIR}/tgbot.env" <<EOF
TG_BOT_TOKEN=${token}
TG_ADMIN_IDS=${ids}
MGMT=${BASE_DIR}/bin/5gpn-ctl
EOF
    chmod 600 "${CONF_DIR}/tgbot.env"
    cat > /etc/systemd/system/5gpn-tgbot.service <<EOF
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
    systemctl enable --quiet --now 5gpn-tgbot.service
    if [[ -z "$ids" ]]; then
        warn "尚未设置授权 ID。给 Bot 发送 /id 获取数字 ID，填入 ${CONF_DIR}/tgbot.env 的 TG_ADMIN_IDS，然后:"
        warn "  systemctl restart 5gpn-tgbot"
    fi
    ok "Telegram bot 已安装。在 Telegram 给你的 Bot 发送 /start 开始操作。"
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
    systemctl enable --quiet --now update-mosdns-rules.timer
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
    ios_status=$(systemctl is-active 5gpn-ios-profile.socket 2>/dev/null || echo "unknown")
    if [[ "$ios_status" == "active" ]]; then
        echo -e "5gpn-ios-profile.socket: ${GREEN}listening${NC}"
    else
        echo -e "5gpn-ios-profile.socket: ${RED}$ios_status${NC}"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^5gpn-tgbot\.service'; then
        tg_status=$(systemctl is-active 5gpn-tgbot 2>/dev/null || echo "unknown")
        echo -e "5gpn-tgbot: $([[ "$tg_status" == active ]] && echo "${GREEN}running${NC}" || echo "${RED}$tg_status${NC}")"
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
