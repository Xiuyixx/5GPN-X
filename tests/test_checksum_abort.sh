#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # Assertions reference shell vars; globals are consumed by eval-loaded installers.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "$1" >&2; exit 1; }

# Minimal logging helpers used by the extracted installers.
info() { :; }
ok()   { :; }
warn() { :; }
err()  { printf 'err: %s\n' "$*" >&2; }

# Extract the two binary installers verbatim from their modules.
eval "$(awk '/^ensure_mihomo\(\)/,/^}/' "${root}/lib/exits.sh")"
eval "$(awk '/^install_mosdns_binary\(\)/,/^}/' "${root}/lib/services.sh")"

MIHOMO_VERSION_DEFAULT="1.19.28"
MOSDNS_VERSION_DEFAULT="5.3.4"
MIHOMO_BIN="/nonexistent/mihomo"
BASE_DIR="$(mktemp -d)"
trap 'rm -rf "$BASE_DIR"' EXIT
mkdir -p "$BASE_DIR"

# Record the temp dir the installer downloaded into, to assert cleanup on abort.
LAST_TMP=""
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi
    done
    [[ -n "$out" ]] || { err "mock curl: no -o target"; return 1; }
    mkdir -p "$(dirname "$out")"
    LAST_TMP="$(dirname "$out")"
    printf 'not-a-real-archive' > "$out"
}
sha256sum() {
    # Always report a digest that differs from every pinned one.
    printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$1"
}

# mihomo: checksum mismatch must abort (non-zero) and remove its temp dir.
if ensure_mihomo >/dev/null 2>&1; then
    fail "ensure_mihomo must abort on checksum mismatch"
fi
[[ -n "$LAST_TMP" && ! -d "$LAST_TMP" ]] || fail "ensure_mihomo must clean up its temp dir on mismatch"

# mosdns: checksum mismatch must abort (exit 1 from a subshell).
if (install_mosdns_binary) >/dev/null 2>&1; then
    fail "install_mosdns_binary must abort on checksum mismatch"
fi

echo "checksum abort policy OK"
