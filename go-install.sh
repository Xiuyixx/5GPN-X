#!/usr/bin/env bash
# Go-first installer entrypoint. Legacy install.sh remains only for rollback
# until the Go runtime has passed server reinstall acceptance.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PGW_GO_PREFIX="${PGW_GO_PREFIX:-/opt/5gpn}"
export PGW_GO_CONFIG="${PGW_GO_CONFIG:-${PGW_GO_PREFIX}/etc/5gpn-go.json}"
export PGW_GO_OFFSET="${PGW_GO_OFFSET:-/var/lib/5gpn/tgbot-go.offset}"
export PGW_GO_ENABLE="${PGW_GO_ENABLE:-0}"
case "${1:-install}" in
  install|upgrade) exec "${root}/scripts/install-go-runtime.sh" ;;
  verify) exec "${root}/scripts/verify-go-migration.sh" ;;
  help|-h|--help) printf '%s\n' 'Usage: go-install.sh [install|upgrade|verify|help]' ;;
  *) echo "unknown command: $1" >&2; exit 2 ;;
esac
