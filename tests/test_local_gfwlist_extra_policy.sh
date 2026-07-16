#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules="$(cat "${root}/lib/update-rules.sh")"
readme="$(cat "${root}/README.md")"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "Missing local GFWList extra marker: ${description} (${needle})" >&2
        exit 1
    fi
}

assert_contains "${rules}" 'GFWLIST_EXTRA_FILE="${BASE_DIR}/gfwlist-extra-local.txt"' 'local extra list path'
assert_contains "${rules}" 'append_local_gfwlist_extras()' 'local extra append function'
assert_contains "${rules}" 'printf '\''%s\n'\'' "$domain"' 'append valid local domains to the mosdns domain set'
assert_contains "${rules}" 'sort -u -o "$GFWLIST_FILE" "$GFWLIST_FILE"' 'dedupe the merged mosdns domain set'
assert_contains "${readme}" '/etc/mosdns/gfwlist-extra-local.txt' 'operator documentation for local extras'

echo "local GFWList extra policy markers OK"
