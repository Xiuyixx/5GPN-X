#!/usr/bin/env bash
# The configuration globals near the top of this file are shared with the
# sourced lib/*.sh modules. Per-file shellcheck cannot see that cross-module
# use (the original single-file install.sh made it obvious), so SC2034 is
# suppressed file-wide here. Behaviour is unchanged by the modular split.
# shellcheck disable=SC2034,SC2153
set -euo pipefail
REPO_URL="https://github.com/Xiuyixx/5GPN-X.git"
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
else
    SCRIPT_DIR="/nonexistent/5gpn-raw-entrypoint"
    SCRIPT_PATH="${SCRIPT_DIR}/install.sh"
fi
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
bootstrap_err() { printf 'Error: %s\n' "$*" >&2; }

# Raw entrypoint bootstrap runs in a subshell: traps and globals cannot leak.
bootstrap_install() (
REPO="Xiuyixx/5GPN-X"
# Keep source checkout separate from the live runtime/data tree. The
# installer deploys into /opt/5gpn and never removes an existing runtime tree.
SOURCE_DIR="${PGW_SRC_DIR:-/opt/5gpn-source}"
COMMIT="${PGW_COMMIT:-}"
RUNTIME_DIR="/opt/5gpn"
MARKER="${RUNTIME_DIR}/.installed-commit"
ATTEMPT="${RUNTIME_DIR}/.install-attempt"

RED='\033[0;31m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Run the installer as root (for example: curl ... | sudo bash)"
    exit 1
fi

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@"
    elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@"
    else return 1; fi
}

# Management commands are not install/upgrade requests, even when offline.
if [[ $# -gt 0 && -f "${RUNTIME_DIR}/bin/5gpn-ctl" ]]; then
    exec bash "${RUNTIME_DIR}/bin/5gpn-ctl" "$@"
fi
# Never check out source inside the live data tree (including symlink aliases).
source_real="$(realpath -m "$SOURCE_DIR")"
source_nominal="$(realpath -m -s "$SOURCE_DIR")"
runtime_real="$(realpath -m "$RUNTIME_DIR")"
if [[ "$source_real" == "$runtime_real" || "$source_real" == "$runtime_real/"* || "$runtime_real" == "$source_real/"* ]]; then
    err "Source and runtime directories must be separate"
    exit 1
fi

command -v git >/dev/null 2>&1 || pkg_install git || { err "git is required"; exit 1; }

if [[ -z "$COMMIT" ]]; then
    COMMIT="$(git ls-remote "https://github.com/${REPO}.git" refs/heads/main | awk 'NR==1 {print $1}')" || {
        err "Unable to resolve main from GitHub"
        exit 1
    }
fi
if [[ ! "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    err "Unable to resolve a complete main commit; set PGW_COMMIT to a 40-hex commit and retry"
    exit 1
fi

COMMIT="${COMMIT,,}"
# The child installer inherits this; the caller intentionally does not.
# shellcheck disable=SC2030
export PGW_COMMIT="$COMMIT"
mode=install
if [[ $# -eq 0 ]]; then
    # A checkout alone is NOT an installation. Recognize deployed runtime
    # state, including historical non-Git installs without a version marker.
    if [[ -f "$MARKER" || -f "$ATTEMPT" || -f "${RUNTIME_DIR}/bin/5gpn-ctl" || -s "${RUNTIME_DIR}/etc/.domain" ]]; then
        mode=upgrade
        installed="$(cat "$MARKER" 2>/dev/null || true)"
        if [[ "$installed" == "$COMMIT" && ! -e "$ATTEMPT" ]]; then
            ok "已是当前版本 ${COMMIT}，无需升级。"
            exit 0
        fi
        info "检测到已有安装（${installed:-legacy/unversioned}），保留配置并升级。"
    else
        info "未检测到已有安装，开始首次安装。"
    fi
fi

info "Downloading ${REPO}@${COMMIT} into ${SOURCE_DIR} ..."
# Reject ambiguous paths rather than rename a symlink target or a traversal.
if [[ "$SOURCE_DIR" != /* || "/$SOURCE_DIR/" == */../* || "/$SOURCE_DIR/" == */./* ||
      "$source_nominal" != "$source_real" ]]; then
    err "Source path must be absolute and must not contain symlinks or traversal"
    exit 1
fi
SOURCE_DIR="$source_real"
# Renames are safe only within a trusted parent. Check ancestors too, allowing
# sticky directories such as /tmp (the immediate parent must still be private).
parent="$(dirname -- "$SOURCE_DIR")"
check_parent="$parent"
while [[ "$check_parent" != / ]]; do
    if [[ -d "$check_parent" ]]; then
        owner="$(stat -c %u -- "$check_parent")"
        permissions="$(stat -c %a -- "$check_parent")"
        if [[ "$owner" != "$EUID" ]] ||
           { (( (8#$permissions & 0022) != 0 )) &&
              { [[ "$check_parent" == "$parent" ]] || (( (8#$permissions & 01000) == 0 )); }; }; then
            err "Source parent must be root-owned and not writable by other users: $check_parent"
            exit 1
        fi
    fi
    check_parent="$(dirname -- "$check_parent")"
done

stage_source() {
    local stage
    mkdir -p "$(dirname -- "$SOURCE_DIR")" || return 1
    stage="$(mktemp -d "${SOURCE_DIR}.staging.XXXXXX")" || return 1
    # The staging checkout is disposable; the existing source is not touched
    # until clone, checkout, and commit verification have all succeeded.
    if ! git clone --no-checkout "https://github.com/${REPO}.git" "$stage" >&2 ||
       ! git -C "$stage" checkout --quiet --detach "$COMMIT" ||
       [[ "$(git -C "$stage" rev-parse HEAD)" != "${COMMIT,,}" ]]; then
        rm -rf -- "$stage"
        err "Unable to prepare a clean source checkout; existing source was preserved"
        return 1
    fi
    printf '%s\n' "$stage"
}

replace_source_atomically() {
    local stage="$1" backup
    # A private, unique container prevents collisions without overwriting any
    # backup. Moving into it is a same-filesystem atomic rename; retain modes,
    # ownership and ignored files inside, protected by the root-only container.
    if ! backup="$(mktemp -d "${SOURCE_DIR}.backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"; then
        err "Unable to reserve source backup; old source unchanged; prepared checkout: $stage"
        return 1
    fi
    info "Preserving previous source at ${backup}/source (retained even if interrupted)"
    if ! mv -T -- "$SOURCE_DIR" "$backup/source"; then
        err "Unable to archive existing source; old source unchanged; prepared checkout: $stage"
        return 1
    fi
    if mv -T -- "$stage" "$SOURCE_DIR"; then
        info "Previous source preserved at ${backup}/source"
        return 0
    fi
    # Do not replace a path created by another process during the failure.
    err "Unable to publish clean source; old source preserved at ${backup}/source; prepared checkout: $stage"

    return 1
}

if [[ -d "${SOURCE_DIR}/.git" ]]; then
    info "Existing source checkout found; checking out trusted commit..."
    source_status="$(git -C "${SOURCE_DIR}" status --porcelain --untracked-files=all --ignored)"
    if [[ -n "$source_status" ]]; then
        info "Local source changes found; preparing a clean checkout and archiving the old tree"
        stage="$(stage_source)" || exit 1
        replace_source_atomically "$stage" || exit 1
    else
        git -C "${SOURCE_DIR}" fetch "https://github.com/${REPO}.git" "$COMMIT" --quiet
        git -C "${SOURCE_DIR}" checkout --quiet --detach "$COMMIT"
    fi
elif [[ -e "${SOURCE_DIR}" ]]; then
    # Historical installers could leave a plain source tree without .git.
    # Treat it like an untrusted/legacy checkout: prepare and verify the new
    # tree first, then archive the old tree instead of deleting or overwriting
    # it. Runtime configuration remains under /opt/5gpn and is unaffected.
    info "Existing source is not a Git checkout; preparing a clean checkout and archiving the old tree"
    stage="$(stage_source)" || exit 1
    replace_source_atomically "$stage" || exit 1
else
    stage="$(stage_source)" || exit 1
    mv -T -- "$stage" "$SOURCE_DIR"
fi
[[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" == "${COMMIT,,}" ]] || { err "Commit verification failed"; exit 1; }
ok "Source ready at ${SOURCE_DIR}; existing /opt/5gpn runtime data was not removed"

cd "${SOURCE_DIR}"
# Arguments retain stdin verbatim and never create installation markers.
if [[ $# -gt 0 ]]; then
    exec bash ./install.sh "$@"
fi
mkdir -p "$RUNTIME_DIR"
umask 077
printf 'mode=%s\ntarget=%s\nstarted=%s\n' "$mode" "$COMMIT" "$(date -u +%FT%TZ)" > "$ATTEMPT"
trap 'rc=$?; if (( rc != 0 )); then err "安装/升级未完成；保留旧版本标记。诊断: $ATTEMPT 、${RUNTIME_DIR}/.upgrade-attempt 或 /var/log/5gpn-install.log；检查备份后重试。"; fi' EXIT
info "Launching ${mode} at ${COMMIT}..."
if [[ "$mode" == upgrade ]]; then
    bash ./install.sh --upgrade < /dev/null
elif [[ ! -t 0 ]] && ( : < /dev/tty ) 2>/dev/null; then
    bash ./install.sh < /dev/tty
else
    bash ./install.sh
fi
# A resolved checkout is not a successful deployment. Publish only on success.
marker_tmp="$(mktemp "${MARKER}.XXXXXX")"
printf '%s\n' "$COMMIT" > "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -f "$ATTEMPT"
ok "${mode} 完成，版本提交 ${COMMIT}"

)

bootstrap_from_repo_if_needed() {
    # Standalone/stdin execution stages the exact verified repository commit.
    local required=(
        lib/common.sh lib/dns.sh lib/cert.sh lib/services.sh
        lib/exits.sh lib/rules.sh lib/uninstall.sh
        lib/renew-hook.sh lib/sniproxy.conf lib/quic-proxy.go
        lib/mosdns.yaml.template lib/update-rules.sh lib/ios-http.py lib/tgbot.py
        lib/wa-shim.py lib/rules-import.py lib/mihomo-exit-config.py
        lib/mihomo-router-config.py lib/rules-default.conf lib/host-setup.sh
    )
    local missing=0 f
    for f in "${required[@]}"; do
        [[ -f "${SCRIPT_DIR}/${f}" ]] || { missing=1; break; }
    done
    [[ $missing -eq 0 ]] && return 0
    if [[ "$(basename -- "$SCRIPT_PATH")" == 5gpn-ctl ]]; then
        bootstrap_err "Missing ${f}; restore the self-contained CLI from a full checkout"
        return 1
    fi
    bootstrap_install "$@"
    exit $?
}
bootstrap_from_repo_if_needed "$@"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m' # No Color

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
        bootstrap_err "lib/${_mod}.sh not found next to this script; run from a full git clone or the documented installer."
        exit 1
    fi
done
unset _mod _modf

# Host firewall and kernel tuning are isolated from component deployment.
if [[ -f "${LIB_DIR}/host-setup.sh" ]]; then
    # shellcheck source=lib/host-setup.sh
    . "${LIB_DIR}/host-setup.sh"
else
    bootstrap_err "lib/host-setup.sh not found next to this script; run from a full git clone or the documented installer."
    exit 1
fi
unset -f bootstrap_err

usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  (none)         Full interactive installation
  --upgrade      Upgrade deployed code, preserving configuration/data
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
  MOSDNS_VERSION Override the locked mosdns version (default: ${MOSDNS_VERSION_DEFAULT})
  TG_STATE_FILE   tgbot getUpdates offset state file (default: /var/lib/5gpn/tgbot-state.json)
  FIREWALL_MODE  preserve (default) | auto | managed.
                 preserve keeps the existing host firewall untouched and only
                 manages the project's own egress-marking rules; auto adds the
                 needed allow rules to UFW/firewalld/nft/iptables without
                 flushing anything; managed fully owns the INPUT firewall
                 (always allowing every detected SSH port). Historical managed
                 settings do not opt in; managed must be explicitly requested.
  PGW_TUNING     essential (default) | performance. essential applies only the
                 sysctls the gateway needs (ip_forward, rp_filter, BBR when
                 available); performance applies the legacy aggressive tuning.
                 Hosts upgraded from older releases keep the performance profile.
EOF
}

install_stage_environment() {
    detect_os || return $?
    detect_memory_profile || return $?
    {
        printf 'OS=%q\n' "$OS"
        printf 'VER=%q\n' "$VER"
        printf 'PKG_MGR=%q\n' "$PKG_MGR"
        printf 'MEM_TOTAL_MB=%q\n' "$MEM_TOTAL_MB"
        printf 'LOWMEM=%q\n' "$LOWMEM"
        printf 'MAKE_JOBS=%q\n' "$MAKE_JOBS"
        printf 'PACKET_CACHE_SIZE=%q\n' "$PACKET_CACHE_SIZE"
    } > "$INSTALL_STATE"
}

install_stage_dependencies() {
    ensure_swap || return $?
    get_public_ip || return $?
    install_deps || return $?
    printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP" >> "$INSTALL_STATE"
}

install_stage_certificate() {
    ensure_mosdns_user || return $?
    install_cert || return $?
    configure_dns_upstreams || return $?
    printf 'REMOTE_DNS=%q\n' "$REMOTE_DNS" >> "$INSTALL_STATE"
    printf 'LOCAL_DNS=%q\n' "$LOCAL_DNS" >> "$INSTALL_STATE"
}

install_stage_deploy() {
    install_sniproxy || return $?
    install_whatsapp_shim || return $?
    install_quic_proxy || return $?
    install_mosdns || return $?
    init_rules || return $?
    system_tuning || return $?
    setup_firewall || return $?
    setup_exit_switching || return $?
    generate_ios_profile || return $?
    apply_lowmem_go_limits || return $?
}

install_stage_finalize() {
    install_ctl_entrypoint || return $?
    start_services || return $?
    setup_schedules || return $?
    setup_tgbot || return $?
}

main_install() {
    check_root
    init_install_log
    INSTALL_STATE="$(mktemp /tmp/5gpn-install-state.XXXXXX)"
    trap 'rm -f "${INSTALL_STATE:-}"' EXIT
    printf '\n5GPN-X 安装\n\n'

    run_install_step "检查运行环境" install_stage_environment || { warn "安装阶段失败：检查运行环境。已完成阶段未自动回滚；请检查安装日志和现有配置备份后重试。"; return 1; }
    # shellcheck disable=SC1090 # State file is generated by the stage above.
    . "$INSTALL_STATE"
    collect_swap_preferences
    run_install_step "安装系统依赖" install_stage_dependencies || { warn "安装阶段失败：安装系统依赖。已完成阶段未自动回滚；请检查安装日志和现有配置备份后重试。"; return 1; }
    # shellcheck disable=SC1090 # State file is generated by the stage above.
    . "$INSTALL_STATE"

    while true; do
        generate_domain
        if ! validate_domain_dns; then
            [[ -t 0 ]] || return 1
            warn "请重新输入域名（Ctrl+C 退出）。"
            DOMAIN=""
            continue
        fi
        if run_install_step "配置域名与 TLS 证书" install_stage_certificate; then
            break
        fi
        [[ -t 0 ]] || return 1
        warn "证书配置失败，请重新输入域名（Ctrl+C 退出）。"
        DOMAIN=""
    done
    # shellcheck disable=SC1090 # State file is generated by the stage above.
    . "$INSTALL_STATE"

    run_install_step "部署网络服务" install_stage_deploy || { warn "安装阶段失败：部署网络服务。已完成阶段未自动回滚；请检查安装日志和现有配置备份后重试。"; return 1; }

    collect_tgbot_settings
    run_install_step "启动并完成配置" install_stage_finalize || { warn "安装阶段失败：启动并完成配置。已完成阶段未自动回滚；请检查安装日志和现有配置备份后重试。"; return 1; }
    rm -f "$INSTALL_STATE"
    trap - EXIT

    printf '\n%b✓ 安装完成%b\n' "$GREEN" "$NC"
    cat <<EOF
  DNS:  ${DOMAIN}
  iOS:  http://${DOMAIN}:${IOS_PROFILE_PORT}/ios-dot.mobileconfig
  管理: ${BASE_DIR}/bin/5gpn-ctl --status
EOF
    echo ""
}

# Code-only deployment deliberately avoids configuration-generating first-run
# helpers. Existing domain/DNS, routing, certificates and bot state stay in place.
upgrade_code() (
    # Keep EXIT trap locals and the routing lock alive through rollback.
    set -e
    local upgrade_stage=lock
    # Fixed stage labels only: never log shell commands or configuration data.
    trap 'rc=$?; if (( rc != 0 )); then printf "[!] Upgrade failed: stage=%s exit=%s\n" "$upgrade_stage" "$rc" >&2; fi' EXIT
    routing_lock
    upgrade_stage=dns-preflight
    local txn committed=0 name remote_dns local_dns unit path i build_dir=""
    local push_sysctl_restore=0 push_sysctl_old_runtime=""
    remote_dns="$(normalize_dns_upstreams "$(cat /etc/mosdns/.remote_dns)")"
    local_dns="$(normalize_dns_upstreams "$(cat /etc/mosdns/.local_dns)")"
    [[ -n "$remote_dns" && -n "$local_dns" ]] || return 1
    upgrade_stage=snapshot
    txn="$(mktemp -d "${BASE_DIR}/.upgrade-txn.XXXXXX")"
    local paths=("$BASE_DIR/bin" "$CONF_DIR/mihomo" "$RULES_DEFAULT"
        "$EXITS_DIR/smart.yaml" "$EXITS_DIR/smart.type" "$EXITS_DIR/smart.yaml.tmp" "$RULESET_CACHE"
        /etc/sysctl.d/99-5gpn.conf
        /etc/mosdns/config.yaml.template /etc/mosdns/config.yaml
        /etc/mosdns/gfwlist.txt /etc/mosdns/chinalist.txt
        /etc/mosdns/override-direct.txt /etc/mosdns/override-proxy.txt /etc/mosdns/override-block.txt
        /var/lib/5gpn-quic/remote-dns /usr/local/bin/update-mosdns-rules.sh /usr/local/bin/mosdns
        /etc/systemd/system/quic-proxy.service /etc/systemd/system/5gpn-mihomo@.service
        /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh)
    local active=() units=(mosdns sniproxy quic-proxy wa-shim 5gpn-tgbot 5gpn-mihomo@smart)
    for unit in "${units[@]}"; do
        if systemctl is-active --quiet "$unit.service"; then active+=("$unit"); fi
    done
    for i in "${!paths[@]}"; do
        path="${paths[$i]}"
        [[ ! -e "$path" && ! -L "$path" ]] || cp -a "$path" "$txn/$i"
    done
    # shellcheck disable=SC2317 # Invoked by EXIT trap.
    upgrade_rollback() {
        local rc=$? recovery=0
        trap - EXIT HUP INT TERM
        if (( rc != 0 )); then
            printf '[!] Upgrade failed: stage=%s exit=%s\n' "$upgrade_stage" "$rc" >&2
        fi
        if (( ! committed )); then
            set +e
            rollback_push_conntrack_timeout || recovery=1
            for i in "${!paths[@]}"; do
                path="${paths[$i]}"
                rm -rf "$path" || recovery=1
                if [[ -e "$txn/$i" || -L "$txn/$i" ]]; then
                    mkdir -p "$(dirname "$path")"
                    cp -a "$txn/$i" "$path" || recovery=1
                fi
            done
            systemctl daemon-reload || recovery=1
            for unit in "${active[@]}"; do
                systemctl restart "$unit.service" || recovery=1
            done
            if (( recovery )); then
                err "Upgrade rollback needs attention; snapshot retained: $txn"
                exit 1
            fi
        fi
        [[ -z "$build_dir" ]] || rm -rf "$build_dir"
        rm -rf "$txn"
        exit "$rc"
    }
    trap upgrade_rollback EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    upgrade_stage=sysctl-migration
    migrate_push_conntrack_timeout
    upgrade_stage=deploy-code
    write_quic_dns_file "$remote_dns"
    install_ctl_entrypoint
    for name in tgbot ios-http wa-shim mihomo-exit-config mihomo-router-config rules-import; do
        install -m 0755 "${LIB_DIR}/${name}.py" "${BASE_DIR}/bin/${name}.py"
    done
    install -m 0755 "${LIB_DIR}/update-rules.sh" /usr/local/bin/update-mosdns-rules.sh
    # Migrate managed templates/defaults on every code upgrade, while leaving
    # runtime inputs (DNS, overrides, rule caches, exits and bot state) intact.
    # The offline renderer publishes a new mosdns config transactionally and
    # preserves the current mosdns active/stopped state.
    install -m 0644 "${LIB_DIR}/mosdns.yaml.template" /etc/mosdns/config.yaml.template
    install -m 0644 "${LIB_DIR}/rules-default.conf" "${RULES_DEFAULT}"
    upgrade_stage=offline-dns
    if [[ -x /usr/local/bin/update-mosdns-rules.sh ]]; then
        /usr/local/bin/update-mosdns-rules.sh --render-only
    fi
    upgrade_stage=smart-config
    if [[ -f "$RULES_FILE" ]]; then
        # regen_smart is an interactive apply helper: it can create users,
        # install/stop legacy units and change routes. Upgrade only renders and
        # validates here; the existing units are restarted once below.
        [[ -x "$MIHOMO_BIN" ]] || { err "Existing mihomo binary missing"; exit 1; }
        local eff="$txn/effective-rules"
        cat "$RULES_DEFAULT" "$RULES_FILE" > "$eff"
        mkdir -p "$RULESET_CACHE" "$CONF_DIR/mihomo/smart"
        EXITS_DIR="$EXITS_DIR" WG_DIR="$WG_DIR" PGW_RULESET_CACHE="$RULESET_CACHE" \
            PGW_POLICY_MAP="$POLICY_MAP" python3 "$MIHOMO_ROUTER_GEN" "$eff" > "$EXITS_DIR/smart.yaml.tmp"
        "$MIHOMO_BIN" -d "$CONF_DIR/mihomo/smart" -t -f "$EXITS_DIR/smart.yaml.tmp"
        install -m 0600 "$EXITS_DIR/smart.yaml.tmp" "$EXITS_DIR/smart.yaml"
        rm -f "$EXITS_DIR/smart.yaml.tmp"
        printf 'router\n' > "$EXITS_DIR/smart.type"
    fi
    upgrade_stage=renew-hook
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    install -m 0755 "${LIB_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    # Unlike install_quic_proxy, rebuild even when the old executable exists.
    upgrade_stage=quic-build
    export PATH="$PATH:/usr/local/go/bin"
    build_dir="$(mktemp -d "${BASE_DIR}/.upgrade-build.XXXXXX")"
    cp "${LIB_DIR}/quic-proxy.go" "$build_dir/"
    (cd "$build_dir" && go build -ldflags="-s -w" -o quic-proxy quic-proxy.go)
    install -m 0755 "$build_dir/quic-proxy" "${BASE_DIR}/bin/quic-proxy"
    rm -rf "$build_dir"
    # Reuse the existing pinned binary installer; it does not edit DNS config.
    upgrade_stage=mosdns-binary
    install_mosdns_binary
    upgrade_stage=service-unit
    # Migrate the managed unit without enabling it; only active units restart.
    cat > /etc/systemd/system/quic-proxy.service <<'EOF'
[Unit]
Description=quic-proxy (UDP/QUIC SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/opt/5gpn/bin/quic-proxy -l 0.0.0.0:443 -dns-file /var/lib/5gpn-quic/remote-dns
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
    # Keep service enablement and active/stopped state unchanged; only active units restart.
    for unit in "${active[@]}"; do
        upgrade_stage="restart-$unit"
        systemctl restart "$unit.service"
        systemctl is-active --quiet "$unit.service"
    done
    committed=1
    trap - EXIT HUP INT TERM
    rm -rf "$txn"
)

main_upgrade() {
    check_root
    # Refuse partial/unrecognized installations rather than run a fresh wizard.
    if [[ ! -s "${CONF_DIR}/.domain" || ! -s /etc/mosdns/config.yaml || ! -x "${BASE_DIR}/bin/quic-proxy" ]]; then
        err "现有安装不完整；升级未修改配置。请检查安装日志并修复安装后重试。"
        return 1
    fi
    local backup
    umask 077
    mkdir -p /var/backups/5gpn
    backup="$(mktemp -d /var/backups/5gpn/upgrade.XXXXXX)"
    # Archive code and all managed config; do not read/execute tgbot.env or
    # touch its custom TG_STATE_FILE. State outside these paths is unchanged.
    local paths=() path
    for path in "$BASE_DIR/bin" "$CONF_DIR" /etc/5gpn /etc/wireguard /etc/mosdns \
        /etc/sniproxy.conf /etc/letsencrypt /var/lib/5gpn /etc/systemd/system \
        /usr/local/bin/update-mosdns-rules.sh /usr/local/bin/mosdns /etc/sysctl.d/99-5gpn.conf; do
        [[ ! -e "$path" ]] || paths+=("${path#/}")
    done
    tar -C / -czf "$backup/config-code.tar.gz" "${paths[@]}"
    INSTALL_LOG="$backup/upgrade.log"
    init_install_log
    # shellcheck disable=SC2031 # Read the child process environment, not bootstrap locals.
    printf 'target=%s\nbackup=%s\n' "${PGW_COMMIT:-unknown}" "$backup" > "${BASE_DIR}/.upgrade-attempt"
    info "升级备份与日志: $backup（含敏感配置，仅 root 可读）"
    # Call directly, not inside an `if` function context that suppresses -e.
    run_install_step "更新程序并检查已有服务" upgrade_code
    rm -f "${BASE_DIR}/.upgrade-attempt"
    ok "升级完成；已迁移托管模板并重新生成配置，用户数据和原有服务状态已保留。"
}

case "${1:-}" in
    --upgrade)
        main_upgrade
        ;;
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
