#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
# Behavioural tests for the firewall regressions fixed on top of the mode
# refactor: uninstall must not leave a dangling nftables include (P1), auto
# mode must persist its allow rules across reboots (P2), and the managed
# marker is written/removed at the right times.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hostsetup="${root}/lib/host-setup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() { echo "$1" >&2; exit 1; }

# --- load helpers + functions under test -------------------------------------
info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
eval "$(awk '/^write_auto_allow_persistence\(\)/,/^}/' "${hostsetup}")"
eval "$(awk '/^run_auto_allow_persistence\(\)/,/^}/' "${hostsetup}")"
eval "$(awk '/^firewall_cleanup_on_uninstall\(\)/,/^}/' "${hostsetup}")"

# mock systemctl / nft / iptables so nothing touches the host
mkdir -p "${tmp}/bin"
for cmd in systemctl nft iptables iptables-restore iptables-save; do
    cat > "${tmp}/bin/${cmd}" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${tmp}/bin/${cmd}"
done
export PATH="${tmp}/bin:${PATH}"

# =============================================================================
# P2: auto-mode persistence
# =============================================================================
auto_script="${tmp}/fw-allow.sh"
auto_unit="${tmp}/5gpn-firewall-allow.service"
PGW_AUTO_ALLOW_SCRIPT="${auto_script}" PGW_AUTO_ALLOW_UNIT="${auto_unit}" \
    write_auto_allow_persistence "2222,10022" "172.22.0.0/16"

[[ -f "${auto_script}" ]] || fail "auto mode must write a persistent replay script"
[[ -x "${auto_script}" ]] || fail "auto persistence script must be executable"
[[ -f "${auto_unit}" ]] || fail "auto mode must install a boot-time oneshot unit"
grep -q '5gpn-auto' "${auto_script}" || fail "auto replay rules must carry the project tag"
grep -q '2222,10022,853,8111' "${auto_script}" || fail "auto replay must keep the detected SSH ports and service ports (port 53 is source-restricted separately)"
grep -q '172.22.0.0/16' "${auto_script}" || fail "auto replay must whitelist the client network"
grep -q "ExecStart=${auto_script}" "${auto_unit}" || fail "oneshot unit must run the replay script"
grep -qE 'After=.*nftables.service' "${auto_unit}" || fail "oneshot must be ordered after the host firewall services"

# the generated script must itself be valid bash and idempotent (mocks no-op)
bash -n "${auto_script}" || fail "generated auto replay script must be valid bash"
PGW_AUTO_ALLOW_SCRIPT="${auto_script}" run_auto_allow_persistence || fail "replay script must run cleanly"

# =============================================================================
# P1: uninstall must not leave a dangling pgw-exit include
# =============================================================================

# case A: a pre-install backup exists -> restore it verbatim
nft_conf="${tmp}/nftables.conf"
cat > "${nft_conf}" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter { chain input { type filter hook input priority 0; policy drop; } }
include "/etc/5gpn/pgw-exit.nft"
EOF
printf '#!/usr/sbin/nft -f\nflush ruleset\n# pristine user ruleset\n' > "${nft_conf}.pgw-backup"
PGW_NFT_CONF="${nft_conf}" PGW_IPT_RULES="${tmp}/none" \
    PGW_FW_MARK="${tmp}/marker" \
    PGW_AUTO_ALLOW_SCRIPT="${tmp}/gone1" PGW_AUTO_ALLOW_UNIT="${tmp}/gone1.unit" \
    firewall_cleanup_on_uninstall
grep -q 'pristine user ruleset' "${nft_conf}" || fail "uninstall must restore the pre-install nftables backup"
[[ ! -f "${nft_conf}.pgw-backup" ]] || fail "uninstall must consume the nftables backup"
grep -q 'pgw-exit.nft' "${nft_conf}" && fail "restored ruleset must not reference the removed pgw-exit include"

# case B: no backup -> the dangling include line must be stripped, rest kept
nft_conf2="${tmp}/nftables2.conf"
cat > "${nft_conf2}" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter { chain input { type filter hook input priority 0; policy drop; } }
include "/etc/5gpn/pgw-exit.nft"
EOF
PGW_NFT_CONF="${nft_conf2}" PGW_IPT_RULES="${tmp}/none" \
    PGW_FW_MARK="${tmp}/marker" \
    PGW_AUTO_ALLOW_SCRIPT="${tmp}/gone2" PGW_AUTO_ALLOW_UNIT="${tmp}/gone2.unit" \
    firewall_cleanup_on_uninstall
grep -q 'include "/etc/5gpn/pgw-exit.nft"' "${nft_conf2}" && fail "uninstall must strip the dangling pgw-exit include"
grep -q 'table inet filter' "${nft_conf2}" || fail "uninstall must keep the rest of the user ruleset when stripping the include"

# case C: iptables backup restore
ipt_rules="${tmp}/iptables.rules"
printf '*filter\n:INPUT DROP [0:0]\nCOMMIT\n' > "${ipt_rules}"
printf '*filter\n:INPUT ACCEPT [0:0]\n# pristine iptables\nCOMMIT\n' > "${ipt_rules}.pgw-backup"
PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${ipt_rules}" \
    PGW_FW_MARK="${tmp}/marker" \
    PGW_AUTO_ALLOW_SCRIPT="${tmp}/gone3" PGW_AUTO_ALLOW_UNIT="${tmp}/gone3.unit" \
    firewall_cleanup_on_uninstall
grep -q 'pristine iptables' "${ipt_rules}" || fail "uninstall must restore the pre-install iptables backup"
[[ ! -f "${ipt_rules}.pgw-backup" ]] || fail "uninstall must consume the iptables backup"

# =============================================================================
# marker + auto artifacts are cleaned up on uninstall
# =============================================================================
marker="${tmp}/managed-marker"
: > "${marker}"
gone_script="${tmp}/cleanup-script.sh"; : > "${gone_script}"
gone_unit="${tmp}/cleanup.unit"; : > "${gone_unit}"
PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/none" \
    PGW_FW_MARK="${marker}" \
    PGW_AUTO_ALLOW_SCRIPT="${gone_script}" PGW_AUTO_ALLOW_UNIT="${gone_unit}" \
    firewall_cleanup_on_uninstall
[[ ! -f "${marker}" ]] || fail "uninstall must remove the managed marker file"
[[ ! -f "${gone_script}" ]] || fail "uninstall must remove the auto persistence script"
[[ ! -f "${gone_unit}" ]] || fail "uninstall must remove the auto persistence unit"

echo "firewall uninstall/auto-persistence behaviour OK"
