#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/lib/dnsdist.conf.template")"
install="$(cat "${root}/install.sh")"

if [[ "${template}" != *'address="127.0.0.1:5301", pool="china", name="china_dns_race"'* ]]; then
    echo "ChinaList traffic must be sent to the local China DNS race proxy." >&2
    exit 1
fi

if [[ "${template}" == *'pool="china", name="china_shanghai"'* || "${template}" == *'pool="china", name="dnspod"'* ]]; then
    echo "dnsdist must not load-balance ChinaList queries directly across remote DNS servers." >&2
    exit 1
fi

if [[ "${install}" != *'install_china_dns_race_proxy()'* ]]; then
    echo "install.sh must install the China DNS race proxy service." >&2
    exit 1
fi

if [[ "${install}" != *'china-dns-race-proxy.service'* ]]; then
    echo "install.sh must create china-dns-race-proxy.service." >&2
    exit 1
fi

if [[ "${install}" != *'systemctl restart china-dns-race-proxy'* ]]; then
    echo "install.sh must start china-dns-race-proxy before dnsdist." >&2
    exit 1
fi

if [[ "${install}" != *'for svc in dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy'* ]]; then
    echo "install.sh --status must include china-dns-race-proxy." >&2
    exit 1
fi

if [[ "${install}" != *'systemctl stop dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy proxy-gateway-ios-profile'* ]]; then
    echo "install.sh --uninstall must stop china-dns-race-proxy." >&2
    exit 1
fi

if [[ "${install}" != *'rm -f /etc/systemd/system/{sniproxy,wa-shim,quic-proxy,china-dns-race-proxy,'* ]]; then
    echo "install.sh --uninstall must remove china-dns-race-proxy.service." >&2
    exit 1
fi

if [[ "${install}" != *'ExecStart=/opt/proxy-gateway/bin/china-dns-race-proxy -l 127.0.0.1:5301'* ]]; then
    echo "china-dns-race-proxy must listen on the dnsdist China pool address." >&2
    exit 1
fi

race_proxy="$(cat "${root}/lib/china-dns-race-proxy.go")"
if [[ "${race_proxy}" != *'net.Listen("tcp", *raceListenAddr)'* ]]; then
    echo "china-dns-race-proxy must accept TCP DNS queries from dnsdist DoT/TCP clients." >&2
    exit 1
fi

echo "China DNS race proxy policy OK"
