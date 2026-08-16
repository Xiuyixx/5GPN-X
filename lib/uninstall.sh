#!/usr/bin/env bash
# 5GPN-X module: uninstall
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

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
        systemctl stop "5gpn-singbox@$(basename "$f" .type).service" 2>/dev/null || true
    done
    shopt -u nullglob
    systemctl stop mosdns dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy 5gpn-ios-profile.socket 5gpn-ios-profile 5gpn-exit 5gpn-tgbot 2>/dev/null || true
    systemctl disable mosdns dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy 5gpn-ios-profile.socket 5gpn-ios-profile 5gpn-exit 5gpn-tgbot 2>/dev/null || true
    rm -f /etc/systemd/system/{mosdns,sniproxy,wa-shim,quic-proxy,china-dns-race-proxy,5gpn-ios-profile,update-mosdns-rules,5gpn-exit,5gpn-tgbot}.*
    rm -f /etc/systemd/system/5gpn-ios-profile@.service \
        /etc/systemd/system/5gpn-mihomo@.service \
        /etc/systemd/system/5gpn-singbox@.service
    rm -rf /etc/systemd/system/quic-proxy.service.d /etc/systemd/system/mosdns.service.d \
        /etc/systemd/system/dnsdist.service.d /etc/systemd/system/china-dns-race-proxy.service.d
    systemctl daemon-reload
    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/mosdns /etc/dnsdist /usr/local/bin/update-mosdns-rules.sh
    rm -f /usr/local/bin/update-dnsdist-rules.sh /usr/local/bin/mosdns
    rm -f /usr/local/sbin/sniproxy
    rm -f /usr/local/bin/5gpn-apply-exit.sh
    rm -f "${WG_DIR}"/pgw-*.conf
    # Repair the host firewall BEFORE removing /etc/5gpn, otherwise a
    # managed /etc/nftables.conf would keep a dangling include and fail to load
    # on reboot (leaving the host with no firewall). Also clears auto-mode
    # persistence and the managed marker.
    firewall_cleanup_on_uninstall
    rm -rf /etc/5gpn
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    rm -f /etc/sysctl.d/99-5gpn.conf
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

