#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
hostsetup="${root}/lib/host-setup.sh"
install_body="$(cat "${install}" "${hostsetup}")"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() { echo "$1" >&2; exit 1; }

# --- markers: the firewall must no longer hardcode SSH on 22 only ------------
[[ "${install_body}" == *'detect_ssh_ports()'* ]] || fail "install.sh must detect SSH ports before touching the firewall"
[[ "${install_body}" != *'tcp_ports="22, 53, 853, 8111"'* ]] || fail "managed firewall must not hardcode the SSH port"
[[ "${install_body}" == *'resolve_firewall_mode()'* ]] || fail "install.sh must support firewall modes"
[[ "${install_body}" == *'FIREWALL_MODE'* ]] || fail "firewall mode must be selectable via FIREWALL_MODE"
[[ "${install_body}" == *'nft -c -f'* ]] || fail "managed nftables config must be validated before install"
[[ "${install_body}" == *'/etc/nftables.conf.pgw-backup'* ]] || fail "managed mode must back up the pre-existing ruleset"
[[ "${install_body}" == *'include "/etc/5gpn/pgw-exit.nft"'* ]] || fail "managed ruleset must include the shared pgw-exit table file"

# --- load the functions under test -------------------------------------------
helpers='info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }'
eval "$helpers"
eval "$(awk '/^detect_ssh_ports\(\)/,/^}/' "${hostsetup}")"
eval "$(awk '/^resolve_firewall_mode\(\)/,/^}/' "${hostsetup}")"
eval "$(awk '/^resolve_tuning_profile\(\)/,/^}/' "${hostsetup}")"

# --- detect_ssh_ports: union of session + sshd -T + listeners ----------------
mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/sshd" <<'EOF'
#!/bin/sh
[ "$1" = "-T" ] || exit 1
echo "port 5187"
echo "port 2222"
EOF
cat > "${tmp}/bin/ss" <<'EOF'
#!/bin/sh
echo 'LISTEN 0 128 0.0.0.0:5187 0.0.0.0:* users:(("sshd",pid=700,fd=3))'
echo 'LISTEN 0 128 [::]:10022 [::]:* users:(("sshd",pid=700,fd=4))'
echo 'LISTEN 0 128 127.0.0.1:53 0.0.0.0:* users:(("dnsdist",pid=800,fd=4))'
EOF
chmod +x "${tmp}/bin/sshd" "${tmp}/bin/ss"

got="$(PATH="${tmp}/bin:${PATH}" SSH_CONNECTION="198.51.100.7 51000 203.0.113.5 5187" detect_ssh_ports)"
[[ "$got" == "2222,5187,10022" ]] || fail "detect_ssh_ports union wrong: got '${got}'"

# fallback when nothing is detectable
cat > "${tmp}/bin/sshd" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "${tmp}/bin/ss" <<'EOF'
#!/bin/sh
exit 1
EOF
got="$(PATH="${tmp}/bin:${PATH}" SSH_CONNECTION="" detect_ssh_ports)"
[[ "$got" == "22" ]] || fail "detect_ssh_ports fallback must be 22: got '${got}'"

# --- resolve_firewall_mode ----------------------------------------------------
mark_absent="${tmp}/no-marker"
got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/none" FIREWALL_MODE='' resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "default firewall mode must be preserve: got '${got}'"

got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/none" FIREWALL_MODE=managed resolve_firewall_mode)"
[[ "$got" == "managed" ]] || fail "explicit FIREWALL_MODE must win: got '${got}'"

got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/none" FIREWALL_MODE=bogus resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "unknown FIREWALL_MODE must fall back to preserve: got '${got}'"

# A historical managed marker must not make a later reinstall destructive.
printf '' > "${tmp}/marker"
got="$(PGW_FW_MARK="${tmp}/marker" PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/none" FIREWALL_MODE='' resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "managed marker must not opt a reinstall into managed mode: got '${got}'"

# A legacy project-written nftables ruleset may contain later user additions.
printf 'flush ruleset\ntable inet pgw_exit {}\n' > "${tmp}/nftables.conf"
got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/nftables.conf" PGW_IPT_RULES="${tmp}/none" FIREWALL_MODE='' resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "legacy nftables fingerprint must not opt a reinstall into managed mode: got '${got}'"

# The same rule applies to old project-managed iptables rulesets.
printf '*filter\n:INPUT DROP [0:0]\n-A INPUT -s 172.22.0.0/16 -p tcp -j ACCEPT\nCOMMIT\n' > "${tmp}/managed.rules"
got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/managed.rules" FIREWALL_MODE='' resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "legacy iptables fingerprint must not opt a reinstall into managed mode: got '${got}'"

# a bare ':INPUT DROP' (iptables-persistent default set by the user, no project rules) must NOT trigger managed
printf '*filter\n:INPUT DROP [0:0]\n-A INPUT -p tcp --dport 22 -j ACCEPT\nCOMMIT\n' > "${tmp}/user.rules"
got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/none" PGW_IPT_RULES="${tmp}/user.rules" FIREWALL_MODE='' resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "a bare :INPUT DROP must not trigger managed: got '${got}'"

# a user-owned nftables config must NOT trigger managed mode
printf 'flush ruleset\ntable inet filter {}\n' > "${tmp}/user.conf"
got="$(PGW_FW_MARK="${mark_absent}" PGW_NFT_CONF="${tmp}/user.conf" PGW_IPT_RULES="${tmp}/none" FIREWALL_MODE='' resolve_firewall_mode)"
[[ "$got" == "preserve" ]] || fail "user-owned nftables config must stay preserve: got '${got}'"

# --- resolve_tuning_profile ----------------------------------------------------
got="$(PGW_SYSCTL_FILE="${tmp}/none" PGW_TUNING='' resolve_tuning_profile)"
[[ "$got" == "essential" ]] || fail "default tuning profile must be essential: got '${got}'"

got="$(PGW_SYSCTL_FILE="${tmp}/none" PGW_TUNING=performance resolve_tuning_profile)"
[[ "$got" == "performance" ]] || fail "explicit PGW_TUNING must win: got '${got}'"

echo "# Proxy Gateway Optimizations (profile: standard)" > "${tmp}/old-sysctl.conf"
got="$(PGW_SYSCTL_FILE="${tmp}/old-sysctl.conf" PGW_TUNING='' resolve_tuning_profile)"
[[ "$got" == "performance" ]] || fail "old aggressive sysctl installs must stay performance: got '${got}'"

echo "# Proxy Gateway Optimizations (profile: essential)" > "${tmp}/new-sysctl.conf"
got="$(PGW_SYSCTL_FILE="${tmp}/new-sysctl.conf" PGW_TUNING='' resolve_tuning_profile)"
[[ "$got" == "essential" ]] || fail "essential installs must stay essential: got '${got}'"

# --- sysctl safety markers ----------------------------------------------------
[[ "${install_body}" == *'profile: essential'* ]] || fail "essential sysctl profile must exist"
[[ "${install_body}" == *'sysctl apply failed; previous tuning restored'* ]] || fail "sysctl apply must roll back on failure"
if grep -A4 'write_essential_sysctl()' "${hostsetup}" | grep -q '/etc/sysctl\.conf'; then
    fail "essential profile must not rewrite /etc/sysctl.conf"
fi

# --- cert hook must not reload the full ruleset -------------------------------
[[ "${install_body}" != *'nft -f /etc/nftables.conf 2>/dev/null || true
elif command -v iptables'* ]] || fail "cert restore hook must not reapply the full nftables.conf"
[[ "${install_body}" == *'5gpn-cert-http'* ]] || fail "temporary cert rule must stay tagged"

echo "firewall ssh-port & mode policy OK"
