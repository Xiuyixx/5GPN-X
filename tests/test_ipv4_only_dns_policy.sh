#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/lib/dnsdist.conf.template")"

if [[ "${template}" != *'addAction(QTypeRule(DNSQType.AAAA), RCodeAction(DNSRCode.NOERROR))'* ]]; then
    echo "dnsdist must return NOERROR/NODATA for all AAAA queries so clients only use IPv4." >&2
    exit 1
fi

if [[ "${template}" == *'SpoofAction("::1")'* ]]; then
    echo "dnsdist must not spoof IPv6 loopback addresses." >&2
    exit 1
fi

echo "IPv4-only DNS policy OK"
