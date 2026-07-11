#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/lib/dnsdist.conf.template")"

if [[ "${template}" == *'SpoofAction("::1")'* ]]; then
    echo "GFWList AAAA queries must not be spoofed to ::1; clients may try local IPv6 and stall." >&2
    exit 1
fi

if [[ "${template}" != *'addAction(QTypeRule(DNSQType.AAAA), RCodeAction(DNSRCode.NOERROR))'* ]]; then
    echo "AAAA queries should return NOERROR/NODATA globally so clients fall back to IPv4 A records." >&2
    exit 1
fi

echo "GFWList AAAA policy OK"
