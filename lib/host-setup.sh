#!/usr/bin/env bash
# Host firewall & kernel tuning helpers for 5GPN-X.
# Sourced by install.sh (kept separate so the main script stays below the
# 128 KiB single-argument limit of the documented `bash -c "$(curl ...)"`
# installer). Relies on install.sh globals: EXIT_USER, EXIT_MARK, LOWMEM,
# and the info/ok/warn/err logging helpers.

resolve_tuning_profile() {
    # essential (default): only what the gateway needs to function.
    # performance:         the legacy aggressive tuning (opt-in).
    local sysctl_file="${PGW_SYSCTL_FILE:-/etc/sysctl.d/99-proxy-gateway.conf}"
    case "${PGW_TUNING:-}" in
        essential|performance) echo "${PGW_TUNING}"; return 0 ;;
        "") ;;
        *) warn "Unknown PGW_TUNING='${PGW_TUNING}'; using essential"; echo essential; return 0 ;;
    esac
    # Upgrade path: hosts that already run the old aggressive profile keep it,
    # so an update does not silently change kernel behaviour underneath them.
    if grep -qE 'profile: (standard|low-memory|performance)' "$sysctl_file" 2>/dev/null; then
        echo performance; return 0
    fi
    echo essential
}
write_essential_sysctl() {
    cat > /etc/sysctl.d/99-proxy-gateway.conf <<EOF
# Proxy Gateway Optimizations (profile: essential)
# Only settings the gateway needs to function. Re-run the installer with
# PGW_TUNING=performance for the aggressive throughput profile.
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        cat >> /etc/sysctl.d/99-proxy-gateway.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    fi
}
write_performance_sysctl() {
    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d
    echo nf_conntrack > /etc/modules-load.d/proxy-gateway-net.conf
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
# Proxy Gateway Optimizations (profile: performance$([[ "${LOWMEM:-0}" == "1" ]] && printf '%s' ', low-memory scaled'; true))
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
            echo "net.ipv4.tcp_mem=$((mem_pages * 12 / 100)) $((mem_pages * 50 / 100)) $((mem_pages * 70 / 100))"
        } >> /etc/sysctl.d/99-proxy-gateway.conf
    fi
    if grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E 's/^([[:space:]]*vm\.swappiness[[:space:]]*=)/# disabled by proxy-gateway (see 99-proxy-gateway.conf): \1/' /etc/sysctl.conf
    fi
}
system_tuning() {
    local profile; profile="$(resolve_tuning_profile)"
    info "Applying kernel and system tuning (profile: ${profile})..."
    local sysctl_file=/etc/sysctl.d/99-proxy-gateway.conf backup=""
    if [[ -f "$sysctl_file" ]]; then
        backup="$(mktemp)"
        cp -a "$sysctl_file" "$backup"
    fi
    if [[ "$profile" == "performance" ]]; then
        write_performance_sysctl
    else
        write_essential_sysctl
    fi
    if ! sysctl --system >/dev/null; then
        if [[ -n "$backup" ]]; then
            install -m 644 "$backup" "$sysctl_file"
            sysctl --system >/dev/null 2>&1 || true
            rm -f "$backup"
        else
            rm -f "$sysctl_file"
        fi
        err "sysctl apply failed; previous tuning restored"
        return 1
    fi
    [[ -n "$backup" ]] && rm -f "$backup"
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
PGW_EXIT_NFT="/etc/proxy-gateway/pgw-exit.nft"
detect_ssh_ports() {
    # Union of: the current session's server port, sshd's configured ports and
    # the ports sshd actually listens on. Never assume 22 is the only entrance.
    local ports="" p
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        p="${SSH_CONNECTION##* }"
        [[ "$p" =~ ^[0-9]+$ ]] && ports+="${p}"$'\n'
    fi
    while IFS= read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] && ports+="${p}"$'\n'
    done < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
    while IFS= read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] && ports+="${p}"$'\n'
    done < <(ss -H -lntp 2>/dev/null | awk '/"sshd"/ { addr = $4; sub(/.*:/, "", addr); print addr }')
    if [[ -z "$ports" ]]; then
        echo 22
        return 0
    fi
    printf '%s' "$ports" | sort -un | paste -sd, -
}
resolve_firewall_mode() {
    # preserve (default): never touch the host INPUT firewall, only manage the
    #                     project's own egress-marking table and print hints.
    # auto:               incrementally allow the needed ports in the existing
    #                     firewall (UFW/firewalld/nft/iptables); never flush.
    # managed:            fully own the INPUT firewall (legacy behaviour).
    local nft_conf="${PGW_NFT_CONF:-/etc/nftables.conf}"
    local ipt_rules="${PGW_IPT_RULES:-/etc/iptables.rules}"
    local mark_file="${PGW_FW_MARK:-/etc/proxy-gateway/.firewall-managed}"
    case "${FIREWALL_MODE:-}" in
        preserve|auto|managed) echo "${FIREWALL_MODE}"; return 0 ;;
        "") ;;
        *) warn "Unknown FIREWALL_MODE='${FIREWALL_MODE}'; using preserve"; echo preserve; return 0 ;;
    esac
    # Authoritative signal: our own marker, dropped only after a successful
    # managed install. When we know for sure, never guess from ruleset shape.
    if [[ -f "$mark_file" ]]; then
        echo managed; return 0
    fi
    # Legacy upgrade path (installs predating the marker file). Only claim a host
    # as managed when the ruleset carries our own fingerprint. A bare
    # ':INPUT DROP' is a common iptables-persistent default set by the user, so
    # it must NOT on its own trigger managed mode (which would flush INPUT).
    if [[ -f "$nft_conf" ]] && grep -q 'pgw_exit' "$nft_conf" 2>/dev/null; then
        echo managed; return 0
    fi
    if [[ -f "$ipt_rules" ]] \
        && grep -qE '^:INPUT DROP' "$ipt_rules" 2>/dev/null \
        && grep -qE '172\.22\.0\.0/16|10\.100\.0\.0/16' "$ipt_rules" 2>/dev/null; then
        echo managed; return 0
    fi
    echo preserve
}
write_pgw_exit_nft() {
    mkdir -p "$(dirname "${PGW_EXIT_NFT}")"
    cat > "${PGW_EXIT_NFT}" <<'EOF'
#!/usr/sbin/nft -f
# Switchable egress: mark proxy ("pxout") outbound so policy routing can send it
# into a WireGuard tunnel; clamp MSS on tunnel interfaces. Self-contained so it
# can be (re)loaded after any firewall reload without duplicating rules.
# Traffic to the client network and any private/loopback range is NOT marked,
# so proxy replies to 172.22.0.0/16 still take the normal route (not the tunnel).
table inet pgw_exit
delete table inet pgw_exit
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
    chmod 644 "${PGW_EXIT_NFT}"
}
apply_pgw_exit_rules() {
    if command -v nft >/dev/null 2>&1; then
        write_pgw_exit_nft
        nft -f "${PGW_EXIT_NFT}" 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1 && id -u "${EXIT_USER}" >/dev/null 2>&1; then
        local pn pp
        while iptables -t mangle -D OUTPUT -m owner --uid-owner "${EXIT_USER}" -j MARK --set-mark "${EXIT_MARK}" 2>/dev/null; do :; done
        for pn in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
            while iptables -t mangle -D OUTPUT -m owner --uid-owner "${EXIT_USER}" -d "$pn" -j RETURN 2>/dev/null; do :; done
            iptables -t mangle -A OUTPUT -m owner --uid-owner "${EXIT_USER}" -d "$pn" -j RETURN 2>/dev/null || true
        done
        for pp in udp tcp; do
            while iptables -t mangle -D OUTPUT -m owner --uid-owner "${EXIT_USER}" -p "$pp" --dport 53 -j RETURN 2>/dev/null; do :; done
            iptables -t mangle -A OUTPUT -m owner --uid-owner "${EXIT_USER}" -p "$pp" --dport 53 -j RETURN 2>/dev/null || true
        done
        iptables -t mangle -A OUTPUT -m owner --uid-owner "${EXIT_USER}" -j MARK --set-mark "${EXIT_MARK}" 2>/dev/null || true
        iptables -t mangle -C POSTROUTING -o "pgw+" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -A POSTROUTING -o "pgw+" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
}
firewall_preserve_hints() {
    local ssh_ports="$1"
    info "FIREWALL_MODE=preserve: leaving the existing host firewall untouched."
    info "Make sure these inbound ports are open (SSH detected on: ${ssh_ports}):"
    info "  TCP ${ssh_ports} (SSH), 53 (DNS), 853 (DoT), 8111 (iOS profile)"
    info "  UDP 53 (DNS)"
    info "  From 172.22.0.0/16 only: TCP 80/443 and UDP 443 (reverse proxy)"
    info "  TCP 80 must be reachable while Let's Encrypt issues/renews the cert."
}
firewall_auto_allow() {
    local ssh_ports="$1" p net
    local tcp_list="${ssh_ports},53,853,8111"
    local client_nets="172.22.0.0/16"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        info "FIREWALL_MODE=auto: adding allow rules to the active UFW profile..."
        for p in ${tcp_list//,/ }; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
        ufw allow 53/udp >/dev/null 2>&1 || true
        for net in ${client_nets}; do
            ufw allow from "${net}" to any port 80,443 proto tcp >/dev/null 2>&1 || true
            ufw allow from "${net}" to any port 443 proto udp >/dev/null 2>&1 || true
        done
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        info "FIREWALL_MODE=auto: adding ports to the running firewalld zone..."
        for p in ${tcp_list//,/ }; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true; done
        firewall-cmd --permanent --add-port=53/udp >/dev/null 2>&1 || true
        for net in ${client_nets}; do
            firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="'"${net}"'" port port="80" protocol="tcp" accept' >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="'"${net}"'" port port="443" protocol="tcp" accept' >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="'"${net}"'" port port="443" protocol="udp" accept' >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
        return 0
    fi
    if command -v nft >/dev/null 2>&1 && nft list chain inet filter input >/dev/null 2>&1; then
        info "FIREWALL_MODE=auto: inserting accept rules into inet filter input (persisted across reboots)..."
        write_auto_allow_persistence "$ssh_ports" "$client_nets"
        run_auto_allow_persistence
        return 0
    fi
    # nft is installed but its 'inet filter input' chain is missing: the running
    # firewall is iptables-based, so fall back rather than silently doing nothing.
    if command -v nft >/dev/null 2>&1; then
        warn "FIREWALL_MODE=auto: nft present but no 'inet filter input' chain; falling back to iptables."
    fi
    if command -v iptables >/dev/null 2>&1; then
        info "FIREWALL_MODE=auto: inserting iptables INPUT accept rules (persisted across reboots)..."
        write_auto_allow_persistence "$ssh_ports" "$client_nets"
        run_auto_allow_persistence
        return 0
    fi
    warn "FIREWALL_MODE=auto: no known firewall found; nothing to change."
    firewall_preserve_hints "$ssh_ports"
}
PGW_AUTO_ALLOW_SCRIPT_DEFAULT="/usr/local/bin/proxy-gateway-fw-allow.sh"
PGW_AUTO_ALLOW_UNIT_DEFAULT="/etc/systemd/system/proxy-gateway-firewall-allow.service"
write_auto_allow_persistence() {
    # auto mode adds rules to the *running* firewall, which is lost on reboot.
    # Persist an idempotent replay script + a oneshot unit ordered after the
    # host firewall services so 53/853/8111 and the client nets stay open.
    local ssh_ports="$1" client_nets="$2"
    local script="${PGW_AUTO_ALLOW_SCRIPT:-${PGW_AUTO_ALLOW_SCRIPT_DEFAULT}}"
    local unit="${PGW_AUTO_ALLOW_UNIT:-${PGW_AUTO_ALLOW_UNIT_DEFAULT}}"
    mkdir -p "$(dirname "$script")" "$(dirname "$unit")"
    {
        echo '#!/bin/bash'
        echo '# 5GPN-X auto-mode firewall allow rules. Idempotent; safe to replay.'
        echo '# Managed by the installer (FIREWALL_MODE=auto). Tag: proxy-gateway-auto'
        printf 'tcp_list="%s,53,853,8111"\n' "$ssh_ports"
        printf 'client_nets="%s"\n' "$client_nets"
        cat <<'AUTO_BODY'
if command -v nft >/dev/null 2>&1 && nft list chain inet filter input >/dev/null 2>&1; then
    have="$(nft list chain inet filter input 2>/dev/null)"
    for p in ${tcp_list//,/ }; do
        printf '%s' "$have" | grep -qE "tcp dport ${p} .*accept" || \
            nft insert rule inet filter input tcp dport "$p" accept comment '"proxy-gateway-auto"' 2>/dev/null || true
    done
    printf '%s' "$have" | grep -qE 'udp dport 53 .*accept' || \
        nft insert rule inet filter input udp dport 53 accept comment '"proxy-gateway-auto"' 2>/dev/null || true
    for net in ${client_nets}; do
        printf '%s' "$have" | grep -q "${net} tcp" || \
            nft insert rule inet filter input ip saddr "${net}" tcp dport '{ 80, 443 }' accept comment '"proxy-gateway-auto"' 2>/dev/null || true
        printf '%s' "$have" | grep -q "${net} udp" || \
            nft insert rule inet filter input ip saddr "${net}" udp dport 443 accept comment '"proxy-gateway-auto"' 2>/dev/null || true
    done
elif command -v iptables >/dev/null 2>&1; then
    for p in ${tcp_list//,/ }; do
        iptables -C INPUT -p tcp --dport "$p" -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$p" -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || true
    done
    iptables -C INPUT -p udp --dport 53 -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport 53 -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || true
    for net in ${client_nets}; do
        iptables -C INPUT -s "${net}" -p tcp -m multiport --dports 80,443 -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -s "${net}" -p tcp -m multiport --dports 80,443 -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -s "${net}" -p udp --dport 443 -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -s "${net}" -p udp --dport 443 -m comment --comment proxy-gateway-auto -j ACCEPT 2>/dev/null || true
    done
fi
AUTO_BODY
    } > "$script"
    chmod 755 "$script"
    cat > "$unit" <<AUTO_UNIT
[Unit]
Description=5GPN-X auto-mode firewall allow rules
After=network-pre.target nftables.service netfilter-persistent.service iptables.service firewalld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${script}

[Install]
WantedBy=multi-user.target
AUTO_UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable proxy-gateway-firewall-allow.service >/dev/null 2>&1 || true
}
run_auto_allow_persistence() {
    local script="${PGW_AUTO_ALLOW_SCRIPT:-${PGW_AUTO_ALLOW_SCRIPT_DEFAULT}}"
    if [[ -x "$script" ]]; then
        bash "$script" 2>/dev/null || true
    fi
}
firewall_managed_apply() {
    local tcp_ports="$1" tcp_ports_ipt="$2"
    if command -v nft >/dev/null 2>&1; then
        # Keep the very first pre-project ruleset around for disaster recovery.
        if [[ -f /etc/nftables.conf && ! -f /etc/nftables.conf.pgw-backup ]] \
            && ! grep -q 'pgw_exit' /etc/nftables.conf 2>/dev/null; then
            cp -a /etc/nftables.conf /etc/nftables.conf.pgw-backup
            info "Existing /etc/nftables.conf backed up to /etc/nftables.conf.pgw-backup"
        fi
        local tmp_conf; tmp_conf="$(mktemp /etc/nftables.conf.pgw.XXXXXX)"
        cat > "$tmp_conf" <<'EOF'
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

# Egress-marking table (pgw_exit) lives in its own include so it can also be
# reloaded independently after partial firewall reloads.
include "/etc/proxy-gateway/pgw-exit.nft"
EOF
        sed -i "s/__TCP_PORTS__/${tcp_ports}/" "$tmp_conf"
        if ! nft -c -f "$tmp_conf" >/dev/null 2>&1; then
            rm -f "$tmp_conf"
            warn "Generated nftables config failed validation; existing firewall left unchanged."
            return 1
        fi
        install -m 755 "$tmp_conf" /etc/nftables.conf
        rm -f "$tmp_conf"
        nft -f /etc/nftables.conf 2>/dev/null || true
        systemctl enable nftables 2>/dev/null || true
    else
        # Keep the very first pre-project ruleset around for disaster recovery,
        # mirroring the nftables branch above.
        if [[ ! -f /etc/iptables.rules.pgw-backup ]] && command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules.pgw-backup 2>/dev/null || true
            info "Existing iptables ruleset backed up to /etc/iptables.rules.pgw-backup"
        fi
        iptables -F INPUT
        iptables -P INPUT DROP
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp -m multiport --dports "${tcp_ports_ipt}" -j ACCEPT
        iptables -A INPUT -p udp --dport 53 -j ACCEPT
        iptables -A INPUT -s 172.22.0.0/16 -p tcp -m multiport --dports 80,443 -j ACCEPT
        iptables -A INPUT -s 172.22.0.0/16 -p udp --dport 443 -j ACCEPT
        iptables -A INPUT -p icmp -j ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
    fi
    # Record that this host is now project-managed so future runs never have to
    # guess from ruleset shape (see resolve_firewall_mode). Reached only on a
    # successful apply; the nft branch returns early on validation failure.
    local mark_file="${PGW_FW_MARK:-/etc/proxy-gateway/.firewall-managed}"
    mkdir -p "$(dirname "$mark_file")"
    : > "$mark_file"
}
firewall_cleanup_on_uninstall() {
    # Called by do_uninstall BEFORE /etc/proxy-gateway is removed. managed mode
    # writes /etc/nftables.conf with include "/etc/proxy-gateway/pgw-exit.nft";
    # once that directory is gone the include dangles and nftables.service fails
    # to load on the next boot, leaving the host with NO firewall on a public
    # IP. Restore the pre-install backup, or strip our include, validating
    # before writing. Do the analogous check for the iptables ruleset.
    local nft_conf="${PGW_NFT_CONF:-/etc/nftables.conf}"
    local ipt_rules="${PGW_IPT_RULES:-/etc/iptables.rules}"
    if [[ -f "$nft_conf" ]] && grep -qE 'pgw_exit|/etc/proxy-gateway/pgw-exit\.nft' "$nft_conf" 2>/dev/null; then
        if [[ -f "${nft_conf}.pgw-backup" ]]; then
            install -m 755 "${nft_conf}.pgw-backup" "$nft_conf"
            rm -f "${nft_conf}.pgw-backup"
            info "Restored pre-install ${nft_conf} from backup."
        else
            local tmp; tmp="$(mktemp)"
            grep -vE 'include[[:space:]]+"/etc/proxy-gateway/pgw-exit\.nft"' "$nft_conf" > "$tmp"
            if command -v nft >/dev/null 2>&1 && ! nft -c -f "$tmp" >/dev/null 2>&1; then
                warn "Could not derive a valid ${nft_conf} after dropping the pgw-exit include; writing a minimal empty ruleset instead."
                printf '#!/usr/sbin/nft -f\nflush ruleset\n' > "$tmp"
            fi
            install -m 755 "$tmp" "$nft_conf"
            rm -f "$tmp"
            info "Removed dangling pgw-exit include from ${nft_conf}."
        fi
        if command -v nft >/dev/null 2>&1; then
            nft -f "$nft_conf" >/dev/null 2>&1 || true
        fi
    fi
    if [[ -f "${ipt_rules}.pgw-backup" ]]; then
        install -m 644 "${ipt_rules}.pgw-backup" "$ipt_rules"
        rm -f "${ipt_rules}.pgw-backup"
        info "Restored pre-install ${ipt_rules} from backup."
        if command -v iptables-restore >/dev/null 2>&1; then
            iptables-restore < "$ipt_rules" 2>/dev/null || true
        fi
    fi
    # Drop the auto-mode persistence artifacts and the managed marker.
    local auto_script="${PGW_AUTO_ALLOW_SCRIPT:-${PGW_AUTO_ALLOW_SCRIPT_DEFAULT:-/usr/local/bin/proxy-gateway-fw-allow.sh}}"
    local auto_unit="${PGW_AUTO_ALLOW_UNIT:-${PGW_AUTO_ALLOW_UNIT_DEFAULT:-/etc/systemd/system/proxy-gateway-firewall-allow.service}}"
    if [[ -f "$auto_unit" ]]; then
        systemctl disable --now proxy-gateway-firewall-allow.service >/dev/null 2>&1 || true
    fi
    rm -f "$auto_script" "$auto_unit"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "${PGW_FW_MARK:-/etc/proxy-gateway/.firewall-managed}"
    nft delete table inet pgw_exit 2>/dev/null || true
}
setup_firewall() {
    info "Configuring firewall..."
    ensure_proxy_user
    local mode ssh_ports tcp_ports tcp_ports_ipt
    mode="$(resolve_firewall_mode)"
    ssh_ports="$(detect_ssh_ports)"
    tcp_ports_ipt="${ssh_ports},53,853,8111"
    tcp_ports="${tcp_ports_ipt//,/, }"
    info "Firewall mode: ${mode} (detected SSH port(s): ${ssh_ports})"
    apply_pgw_exit_rules
    case "$mode" in
        preserve) firewall_preserve_hints "$ssh_ports" ;;
        auto)     firewall_auto_allow "$ssh_ports" ;;
        managed)  firewall_managed_apply "$tcp_ports" "$tcp_ports_ipt" || true ;;
    esac
    ok "Firewall configured (reverse proxy whitelist: 172.22.0.0/16)"
}
open_cert_http_port() {
    info "Temporarily opening TCP/80 for Let's Encrypt HTTP-01..."
    if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
        nft insert rule inet filter input tcp dport 80 accept comment '"proxy-gateway-cert-http"' 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null || true
    fi
}
close_cert_http_port() {
    # Remove only our tagged temporary rule; never reload a full ruleset here,
    # because in preserve/auto mode /etc/nftables.conf belongs to the user.
    local h
    if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
        while h="$(nft --handle list chain inet filter input 2>/dev/null | awk '/proxy-gateway-cert-http/ { print $NF; exit }')" && [[ -n "$h" ]]; do
            nft delete rule inet filter input handle "$h" 2>/dev/null || break
        done
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -D INPUT -p tcp --dport 80 -m comment --comment proxy-gateway-cert-http -j ACCEPT 2>/dev/null; do :; done
    fi
}
restore_reverse_proxy_firewall() {
    info "Restoring reverse proxy firewall whitelist..."
    close_cert_http_port
    setup_firewall >/dev/null 2>&1 || true
}
