#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal sysctl snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hostsetup="${root}/lib/host-setup.sh"
body="$(cat "${hostsetup}")"
fail() { echo "$1" >&2; exit 1; }

# Long-lived mobile push connections must outlive the first TCP keepalive
# probe. A short conntrack timeout can break idle stateful TLS sessions.
[[ "$body" == *'net.netfilter.nf_conntrack_tcp_timeout_established=86400'* ]] \
    || fail "established TCP conntrack timeout must preserve long-lived push sessions"

keepalive_time="$(sed -n 's/^net\.ipv4\.tcp_keepalive_time=\([0-9][0-9]*\)$/\1/p' "$hostsetup")"
keepalive_intvl="$(sed -n 's/^net\.ipv4\.tcp_keepalive_intvl=\([0-9][0-9]*\)$/\1/p' "$hostsetup")"
keepalive_probes="$(sed -n 's/^net\.ipv4\.tcp_keepalive_probes=\([0-9][0-9]*\)$/\1/p' "$hostsetup")"
conntrack_timeout="$(sed -n 's/^net\.netfilter\.nf_conntrack_tcp_timeout_established=\([0-9][0-9]*\)$/\1/p' "$hostsetup")"
[[ -n "$keepalive_time" && -n "$keepalive_intvl" && -n "$keepalive_probes" && -n "$conntrack_timeout" ]] \
    || fail "TCP keepalive/conntrack settings are incomplete"
(( conntrack_timeout > keepalive_time + keepalive_intvl * keepalive_probes )) \
    || fail "conntrack timeout must exceed the complete TCP keepalive probe window"

echo "push keepalive policy OK"
