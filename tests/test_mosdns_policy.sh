#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell/YAML snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/lib/mosdns.yaml.template")"
rules="$(cat "${root}/lib/update-rules.sh")"
install="$(cat "${root}/install.sh")"

fail() { echo "$1" >&2; exit 1; }
has() { [[ "$1" == *"$2"* ]] || fail "$3"; }

has "$template" 'client_ip 172.22.0.0/16 10.100.0.0/16' \
    "mosdns must identify both gateway client networks by source address"
has "$template" 'exec: goto private_client' \
    "gateway client networks must enter the synthetic proxy policy"
has "$template" 'exec: goto remote_resolve' \
    "non-private clients must use normal remote DNS resolution"
has "$template" 'exec: reject 0' \
    "private-client AAAA queries must receive NOERROR/NODATA"
has "$template" 'exec: black_hole __SERVER_IP__' \
    "private overseas A queries must resolve to the gateway"
[[ "$(grep -c 'exec: accept' "${root}/lib/mosdns.yaml.template")" -eq 2 ]] \
    || fail "synthetic A responses must terminate the sequence before normal forwarding"
has "$template" 'qname $china_domains' \
    "ChinaList domains must retain domestic resolution"

china_line=$(grep -n 'qname \$china_domains' "${root}/lib/mosdns.yaml.template" | cut -d: -f1)
spoof_line=$(grep -n 'exec: black_hole __SERVER_IP__' "${root}/lib/mosdns.yaml.template" | tail -n1 | cut -d: -f1)
[[ "$china_line" -lt "$spoof_line" ]] || fail "ChinaList matching must run before default private A spoofing"

[[ "$(grep -c 'type: fallback' "${root}/lib/mosdns.yaml.template")" -eq 2 ]] \
    || fail "remote and local DNS paths must each have a fallback plugin"
[[ "$(grep -c 'always_standby: true' "${root}/lib/mosdns.yaml.template")" -eq 2 ]] \
    || fail "both fallback paths must keep the secondary upstream warm"
has "$template" 'primary: remote_primary' "remote fallback primary is missing"
has "$template" 'secondary: remote_secondary' "remote fallback secondary is missing"
has "$template" 'primary: local_primary' "local fallback primary is missing"
has "$template" 'secondary: local_secondary' "local fallback secondary is missing"

has "$template" 'type: udp_server' "UDP/53 listener is missing"
[[ "$(grep -c 'type: tcp_server' "${root}/lib/mosdns.yaml.template")" -eq 2 ]] \
    || fail "TCP/53 and DoT/853 listeners must both be configured"
has "$template" 'cert: /etc/mosdns/certs/fullchain.pem' "DoT certificate is missing"

has "$rules" 'mode == "primary"' "upstream renderer must split primary and fallback servers"
has "$rules" 'next(item for item in fallbacks if item != items[0])' \
    "a single configured resolver must still get an independent fallback"
has "$rules" 'timeout 2 mosdns start -c "$validate_conf"' "generated mosdns config must be validated"
has "$rules" 'rc -ne 124' "successful timeout-based validation must be accepted"
has "$rules" 'mv -f "$MOSDNS_CONF.tmp" "$MOSDNS_CONF"' \
    "validated config must be installed atomically"

has "$install" 'MOSDNS_VERSION_DEFAULT="5.3.4"' "mosdns release must be pinned"
has "$install" 'ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml' \
    "systemd must start mosdns with the generated config"
has "$install" 'systemctl disable --now dnsdist.service' \
    "migration must disable the replaced dnsdist service"
[[ "$install" != *'install_china_dns_race_proxy()'* ]] \
    || fail "mosdns fallback should replace the extra China DNS race service"

echo "mosdns source routing and fallback policy OK"
