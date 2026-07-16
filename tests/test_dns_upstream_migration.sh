#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # Extracted functions consume globals dynamically via eval.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "$1" >&2; exit 1; }
info() { :; }
err() { echo "$*" >&2; }
DEFAULT_REMOTE_DNS=("https://1.1.1.1/dns-query" "udp://8.8.8.8:53")
DEFAULT_LOCAL_DNS=("https://223.5.5.5/dns-query" "udp://119.29.29.29:53")
CONF_DIR="${tmp}/conf"
MOSDNS_DIR="$CONF_DIR"
mkdir -p "$CONF_DIR"

eval "$(sed -n '/^normalize_dns_upstreams() {/,/^}/p' "$install")"
eval "$(sed -n '/^configure_dns_upstreams() {/,/^}/p' "$install")"

# A reinstall over the old stock UDP defaults should adopt DoH primary + UDP fallback.
printf '1.1.1.1 8.8.8.8\n' > "${CONF_DIR}/.remote_dns"
printf '223.5.5.5 119.29.29.29\n' > "${CONF_DIR}/.local_dns"
unset REMOTE_DNS LOCAL_DNS DNS_UPSTREAMS OVERSEAS_DNS PRIVATE_OVERSEAS_DNS SNIPROXY_DNS
configure_dns_upstreams
[[ "$REMOTE_DNS" == "https://1.1.1.1/dns-query udp://8.8.8.8:53" ]] \
    || fail "legacy international defaults were not migrated"
[[ "$LOCAL_DNS" == "https://223.5.5.5/dns-query udp://119.29.29.29:53" ]] \
    || fail "legacy domestic defaults were not migrated"

# Explicit user choices, including plain UDP IPs, must remain untouched.
REMOTE_DNS="9.9.9.9 1.0.0.1"
LOCAL_DNS="180.76.76.76 114.114.114.114"
configure_dns_upstreams
[[ "$REMOTE_DNS" == "9.9.9.9 1.0.0.1" ]] || fail "explicit international DNS was changed"
[[ "$LOCAL_DNS" == "180.76.76.76 114.114.114.114" ]] || fail "explicit domestic DNS was changed"

# Unsupported/malformed encrypted DNS URLs must fail closed.
if (normalize_dns_upstreams "https://example.com/not-dns-query") >/dev/null 2>&1; then
    fail "invalid DoH URL was accepted"
fi

echo "DNS upstream migration and URL validation OK"
