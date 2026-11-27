#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Go runtime must remain independent of legacy control files.
if find "$root/cmd" "$root/internal" -type f -name '*.go' -print0 | xargs -0 grep -nHiE 'tgbot\.py|ios-http\.py|wa-shim\.py|mihomo-router-config\.py|5gpn-mihomo@smart|smart\.yaml'; then
  echo "Go runtime references legacy control chain" >&2
  exit 1
fi
[[ -x "$root/go-install.sh" ]] || { echo "Go-first installer missing" >&2; exit 1; }
[[ -x "$root/scripts/install-go-runtime.sh" ]] || { echo "Go runtime installer missing" >&2; exit 1; }
echo "legacy cleanup policy OK"
