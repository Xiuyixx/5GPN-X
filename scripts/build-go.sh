#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${root}/dist/5gpn-go}"
mkdir -p "$(dirname "$out")"
cd "$root"
go build -trimpath -ldflags="-s -w" -o "$out" ./cmd/5gpn-go
chmod 0755 "$out"
printf '%s\n' "$out"
