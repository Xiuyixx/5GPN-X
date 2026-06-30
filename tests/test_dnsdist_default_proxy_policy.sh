#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/dnsdist.conf.template")"

fail() { echo "$1" >&2; exit 1; }

[[ "${template}" == *'addAction(AndRule({privateClientRule, QTypeRule(DNSQType.A)}), SpoofAction(serverIP))'* ]] \
    || fail "private clients must spoof default overseas A records to the gateway IP"
[[ "${template}" == *'enters the gateway and is sent through the selected exit'* ]] \
    || fail "dnsdist template must document the default gateway-entry model"
[[ "${template}" == *'addAction(AndRule({nonPrivateClientRule, AllRule()}), PoolAction("remote"))'* ]] \
    || fail "public DoT clients must keep normal remote DNS answers"
[[ "${template}" == *'addAction(LuaRule(function(dq) return chinaList:check(dq.qname) end), PoolAction("china"))'* ]] \
    || fail "ChinaList must stay on the domestic DNS pool before default spoofing"

echo "dnsdist default proxy policy OK"
