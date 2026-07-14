#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="$(cat "${root}/install.sh")"
sniproxy="$(cat "${root}/lib/sniproxy.conf")"
fail() { echo "$1" >&2; exit 1; }

python3 -m py_compile "${root}/lib/wa-shim.py" "${root}/tests/test_wa_shim.py"
python3 "${root}/tests/test_wa_shim.py" >/dev/null

[[ "${sniproxy}" == *'listener 127.0.0.1:8443'* ]] || fail "sniproxy TLS backend must be loopback-only"
[[ "${sniproxy}" != *'listener 0.0.0.0:443'* ]] || fail "sniproxy must not conflict with wa-shim on public TCP/443"
for needle in 'install_whatsapp_shim()' 'WA_SHIM_BACKEND=127.0.0.1:8443' \
  'WA_SHIM_ALLOW_CIDR=172.22.0.0/16,10.100.0.0/16,127.0.0.0/8' 'self_ips="${PUBLIC_IP:-},127.0.0.1,::1,"' \
  'User=${EXIT_USER}' 'AmbientCapabilities=CAP_NET_BIND_SERVICE' 'systemctl restart wa-shim'; do
    [[ "${install}" == *"${needle}"* ]] || fail "missing WhatsApp integration: ${needle}"
done
[[ "${install}" == *'for domain in whatsapp.net whatsapp.com'* ]] || fail "WhatsApp DNS interception must be persistent"
[[ "${install}" == *'systemctl stop dnsdist sniproxy wa-shim'* ]] || fail "uninstall must stop wa-shim"
[[ "${install}" == *'--setup-whatsapp)'* ]] || fail "repair command must be dispatched"

echo "WhatsApp patch policy OK"
