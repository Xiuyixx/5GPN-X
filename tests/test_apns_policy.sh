#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal policy snippets.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "$1" >&2; exit 1; }
# Direct DNS is intentional: no new unauthenticated proxy or firewall port.
! grep -q '5223' "${root}/lib/sniproxy.conf" || fail "APNs must not add a gateway listener"
! grep -q '5223' "${root}/lib/host-setup.sh" || fail "APNs must not add firewall exposure"
grep -q 'domain:push.apple.com' "${root}/lib/mosdns.yaml.template" || fail "APNs suffix exception missing"
echo "APNs direct-DNS exposure policy OK"
