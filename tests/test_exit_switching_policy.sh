#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
sniproxy_conf="${root}/lib/sniproxy.conf"
exit_setup="${root}/lib/exit-server-setup.sh"
install_body="$(cat "${install}")"

fail() { echo "$1" >&2; exit 1; }

# --- CLI surface -------------------------------------------------------------
for needle in '--list-exits)' '--add-exit)' '--del-exit)' '--set-exit)'; do
    [[ "${install_body}" == *"${needle}"* ]] || fail "install.sh missing exit CLI dispatch: ${needle}"
done
for fn in 'setup_exit_switching()' 'set_exit()' 'add_exit()' 'del_exit()' 'list_exits()' 'ensure_proxy_user()'; do
    [[ "${install_body}" == *"${fn}"* ]] || fail "install.sh missing function: ${fn}"
done

# --- egress user must be a dedicated unprivileged account --------------------
[[ "${install_body}" == *'EXIT_USER="pxout"'* ]] || fail "install.sh must define the pxout egress user"

# --- the proxies must run as that user so their egress can be marked ---------
[[ "$(cat "${sniproxy_conf}")" == *'user pxout'* ]] || fail "sniproxy.conf must run as user pxout"
[[ "${install_body}" == *'User=pxout'* ]] || fail "quic-proxy.service must run as User=pxout"

# --- marking + policy routing must survive an nftables flush -----------------
[[ "${install_body}" == *'table inet pgw_exit'* ]] || fail "install.sh must define the pgw_exit nftables table inside the main ruleset"
[[ "${install_body}" == *'meta skuid "pxout" meta mark set 0x1'* ]] || fail "install.sh must mark pxout egress in nftables"

# --- client/private replies must NOT be marked (else they go into the tunnel) -
[[ "${install_body}" == *'ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } return'* ]] \
    || fail "nft mark chain must exclude client/private/loopback destinations"
[[ "${install_body}" == *'for pn in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10'* ]] \
    || fail "iptables mark path must iterate the private/client exclusion list"
[[ "${install_body}" == *'-d "$pn" -j RETURN'* ]] \
    || fail "iptables mark path must RETURN (not mark) excluded destinations"
[[ "${install_body}" == *'ip rule add fwmark'* ]] || fail "install.sh must add a fwmark policy-routing rule"
[[ "${install_body}" == *'ip route replace default dev'* ]] || fail "install.sh must route marked traffic into the exit interface"

# --- boot persistence --------------------------------------------------------
[[ "${install_body}" == *'proxy-gateway-exit.service'* ]] || fail "install.sh must install the boot-time exit selector service"
[[ "${install_body}" == *'proxy-gateway-apply-exit.sh'* ]] || fail "install.sh must install the apply-exit helper"

# --- WireGuard configs must never hijack the global default route -----------
[[ "${install_body}" == *'Table = off'* ]] || fail "install.sh must force 'Table = off' on imported WireGuard exit configs"

# --- remote exit-server helper ----------------------------------------------
[[ -f "${exit_setup}" ]] || fail "exit-server-setup.sh must exist"
exit_body="$(cat "${exit_setup}")"
[[ "${exit_body}" == *'MASQUERADE'* ]] || fail "exit-server-setup.sh must enable NAT (MASQUERADE)"
[[ "${exit_body}" == *'net.ipv4.ip_forward=1'* ]] || fail "exit-server-setup.sh must enable IP forwarding"
[[ "${exit_body}" == *'wg genkey'* ]] || fail "exit-server-setup.sh must generate WireGuard keys"

echo "exit switching policy OK"
