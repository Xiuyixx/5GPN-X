#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
go test ./...
go vet ./...
bash tests/test_go_runtime_installer.sh
bash -n scripts/build-go.sh scripts/install-go-runtime.sh
# The old smart/Python control path must not be referenced by the Go runtime.
if grep -RniE 'tgbot\.py|mihomo-router-config\.py|5gpn-mihomo@smart|smart\.yaml' cmd internal; then
  echo "Go runtime still references removed legacy control path" >&2
  exit 1
fi
git diff --check
echo "Go migration verification OK"
