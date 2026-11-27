#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/install-go-runtime.sh"
[[ -x "$script" ]] || { echo "Go runtime installer must be executable" >&2; exit 1; }
grep -q 'build-go.sh' "$script"
grep -q '5gpn-go.service' "$script"
grep -q 'PGW_GO_ENABLE' "$script"
grep -q 'PGW_GO_CONFIG' "$script"
grep -q 'PGW_GO_OFFSET' "$script"
grep -q 'migrate' "$script"
echo "Go runtime installer policy OK"
