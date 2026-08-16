#!/usr/bin/env bash
# The configuration globals near the top of this file are shared with the
# sourced lib/*.sh modules. Per-file shellcheck cannot see that cross-module
# use (the original single-file install.sh made it obvious), so SC2034 is
# suppressed file-wide here. Behaviour is unchanged by the modular split.
# shellcheck disable=SC2034
set -euo pipefail
REPO_URL="https://github.com/Xiuyixx/5GPN-X.git"
# The globals below are shared configuration consumed by the sourced lib/*.sh
# modules. Per-file shellcheck cannot see that cross-module use (the original
# single-file install.sh made it obvious), so SC2034 is suppressed here only.
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
LIB_DIR="${SCRIPT_DIR}/lib"
BASE_DIR="/opt/5gpn"
CONF_DIR="${BASE_DIR}/etc"
SRC_DIR="${BASE_DIR}/src"
WWW_DIR="${BASE_DIR}/www"
IOS_PROFILE_PORT=8111
EXIT_USER="pxout"
EXIT_MARK="0x1"
EXIT_TABLE="100"
WG_DIR="/etc/wireguard"
EXITS_DIR="/etc/5gpn/exits"
RULES_FILE="/etc/5gpn/rules.conf"
POLICY_MAP="/etc/5gpn/policy-map.conf"
KEEP_FILE="/etc/5gpn/keep-categories"
DIRECT_FILE="/etc/5gpn/direct-categories"
RULES_DEFAULT="/etc/5gpn/rules-default.conf"
RULESET_CACHE="/etc/5gpn/rulesets"
MIHOMO_BIN="/opt/5gpn/bin/mihomo"
MIHOMO_CFG_GEN="/opt/5gpn/bin/mihomo-exit-config.py"
MIHOMO_ROUTER_GEN="/opt/5gpn/bin/mihomo-router-config.py"
RULES_IMPORT="/opt/5gpn/bin/rules-import.py"
MIHOMO_VERSION_DEFAULT="1.19.28"
MOSDNS_VERSION_DEFAULT="5.3.4"
DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_LOCAL_DNS=("101.226.4.6" "218.30.118.6" "180.76.76.76" "119.29.29.29")
bootstrap_from_repo_if_needed() {
    local required=(
        install.sh
        lib/common.sh lib/dns.sh lib/cert.sh lib/services.sh
        lib/exits.sh lib/rules.sh lib/uninstall.sh
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

# ---------------------------------------------------------------------------
# Modular library sourcing. install.sh stays the single entrypoint; feature
# functions live in lib/*.sh (verbatim, one module per feature domain) to keep
# this orchestrator readable. Order matters only in that common.sh defines
# shared helpers used by others at call time.
# ---------------------------------------------------------------------------
for _mod in common dns cert services exits rules uninstall; do
    _modf="${LIB_DIR}/${_mod}.sh"
    if [[ -f "${_modf}" ]]; then
        # shellcheck source=/dev/null
        . "${_modf}"
    else
        err "lib/${_mod}.sh not found next to this script; run from a full git clone or the documented installer."
        exit 1
    fi
done
unset _mod _modf

# Host firewall & kernel tuning helpers live in lib/host-setup.sh to keep this
# script below the 128 KiB single-argument limit of `bash -c "$(curl ...)"`.
if [[ -f "${LIB_DIR}/host-setup.sh" ]]; then
    # shellcheck source=lib/host-setup.sh
    . "${LIB_DIR}/host-setup.sh"
else
    err "lib/host-setup.sh not found next to this script; run from a full git clone or the documented installer."
    exit 1
fi

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
