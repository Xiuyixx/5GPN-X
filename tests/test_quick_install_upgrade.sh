#!/usr/bin/env bash
# Policy/mock coverage for the one-line installer state machine.  No network,
# package manager, systemd, Telegram, or production paths are touched.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
quick="$(<"${root}/install.sh")"
install="$(<"${root}/install.sh")"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$quick" == *'mode=install'* && "$quick" == *'mode=upgrade'* ]] || fail "fresh/upgrade branches missing"
[[ "$quick" == *'legacy/unversioned'* ]] || fail "legacy non-Git runtime detection missing"
[[ "$quick" == *'已是当前版本'* && "$quick" == *'无需升级'* ]] || fail "current-version no-op missing"
[[ "$quick" == *'git ls-remote'* && "$quick" == *'Unable to resolve main'* ]] || fail "ref-resolution failure must be explicit"
[[ "$quick" == *'install-attempt'* && "$quick" == *'保留旧版本标记'* ]] || fail "failed upgrade diagnostic marker missing"
[[ "$quick" == *'< /dev/tty'* ]] || fail "first install must use /dev/tty when piped"
[[ "$quick" == *'if [[ $# -gt 0 ]]'* && "$quick" == *'exec bash ./install.sh "$@"'* ]] || fail "management arguments must retain stdin"
[[ "$quick" == *'Source and runtime directories must be separate'* ]] || fail "source/runtime collision guard missing"
[[ "$quick" == *'Local source changes found'* && "$quick" == *'Previous source preserved'* ]] || fail "dirty source archive path missing"
[[ "$quick" == *'not a Git checkout; preparing a clean checkout and archiving the old tree'* ]] || fail "legacy non-git source archive path missing"
[[ "$quick" == *'Source path must be absolute'* ]] || fail "source path safety guard missing"
# `--status` and other management args are dispatched before resolution only
# when the installed self-contained CLI exists; they never select upgrade mode.
[[ "$quick" != *'--status)"'* ]] || fail "quick installer must not own status branch"
[[ "$install" == *'--upgrade)'* && "$install" == *'main_upgrade'* ]] || fail "explicit upgrade entrypoint missing"
[[ "$install" == *'现有安装不完整；升级未修改配置'* ]] || fail "partial install must refuse upgrade"
[[ "$install" == *'/var/backups/5gpn/upgrade.'* ]] || fail "upgrade backup missing"
[[ "$install" == *'tgbot.env'* && "$install" == *'upgrade_code'* ]] || fail "bot state preservation path missing"
[[ "$install" == *'migrate_push_conntrack_timeout'* && "$install" == *'upgrade_stage=sysctl-migration'* ]] || fail "upgrade must migrate the long-lived TCP conntrack timeout"
[[ "$install" == *'install_ctl_entrypoint || return $?'* ]] || fail "fresh install must refresh self-contained CLI"

echo "quick installer upgrade policy OK"
