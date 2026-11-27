#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
entry="$root/go-install.sh"
[[ -x "$entry" ]] || { echo "go-first entrypoint missing" >&2; exit 1; }
grep -q 'scripts/install-go-runtime.sh' "$entry"
grep -q 'install|upgrade|verify' "$entry"
if grep -RniE 'tgbot\.py|mihomo-router-config\.py|5gpn-mihomo@smart|smart\.yaml' internal cmd; then
  echo "Go-first runtime references legacy control path" >&2
  exit 1
fi
echo "Go-first entrypoint policy OK"
