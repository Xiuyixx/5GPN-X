#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091 # Source path is resolved dynamically from the test location.
. "${root}/lib/common.sh"

fail() { echo "$1" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="${tmp}/install.log"

cat > "$log" <<'EOF'
Requesting a certificate for x17.dpdns.org
An unexpected error occurred:
too many certificates (5) already issued for this exact set of identifiers in the last 168h0m0s, retry after 2026-08-17 20:59:04 UTC: see https://letsencrypt.org/docs/rate-limits/
EOF
summary="$(install_error_summary_from_log "$log")"
[[ "$summary" == "Let's Encrypt 签发频率已达上限，可重试时间：2026-08-17 20:59:04 UTC" ]] || \
    fail "rate-limit summary must replace the generic Certbot error: $summary"

printf '%s\n' 'Some challenges have failed.' > "$log"
summary="$(install_error_summary_from_log "$log")"
[[ "$summary" == *'域名验证失败'* ]] || fail "challenge failures need an actionable summary"

printf '%s\n' 'fatal stage error' > "$log"
summary="$(install_error_summary_from_log "$log")"
[[ "$summary" == 'fatal stage error' ]] || fail "generic stage errors must remain visible"

echo "install error summary OK"
