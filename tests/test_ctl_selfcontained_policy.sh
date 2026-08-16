#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
#
# Regression guard for the lib/*.sh modular split: the installed `5gpn-ctl`
# re-runs install.sh for runtime subcommands (--set-exit, --del-exit,
# --check-exits, ...). If the lib modules are not shipped next to the CLI,
# bootstrap_from_repo_if_needed falls back to `git clone`, which fails on
# offline hosts and breaks exit switching / deletion / connectivity checks
# from the Telegram bot ("无法自动获取完整源码树").
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
services="${root}/lib/services.sh"
services_src="$(cat "${services}")"

fail() { echo "$1" >&2; exit 1; }

# --- the CLI must be shipped with a self-contained lib payload --------------
[[ "${services_src}" == *'install_ctl_entrypoint()'* ]] \
    || fail "services.sh must define install_ctl_entrypoint to bundle 5gpn-ctl with its lib modules"
[[ "${services_src}" == *'install_ctl_entrypoint'* ]] \
    || fail "setup_tgbot must call install_ctl_entrypoint instead of copying install.sh bare"
[[ "${services_src}" == *'"${ctl_dir}/5gpn-ctl"'* || "${services_src}" == *'/bin/5gpn-ctl"'* ]] \
    || fail "install_ctl_entrypoint must install the 5gpn-ctl entrypoint"

# The entrypoint installer must copy each module bootstrap requires.
for lib in common.sh dns.sh cert.sh services.sh exits.sh rules.sh uninstall.sh \
           renew-hook.sh sniproxy.conf quic-proxy.go mosdns.yaml.template \
           update-rules.sh ios-http.py tgbot.py wa-shim.py rules-import.py \
           mihomo-exit-config.py mihomo-router-config.py rules-default.conf \
           host-setup.sh; do
    [[ "${services_src}" == *"${lib}"* ]] \
        || fail "install_ctl_entrypoint must bundle lib/${lib} next to 5gpn-ctl"
done

# --- bootstrap must not treat install.sh itself as a missing dependency -----
# The running script (or installed 5gpn-ctl) is always present; only the
# sourced lib payload can be missing.
bootstrap="$(awk '/^bootstrap_from_repo_if_needed\(\) \{/,/^\}/' "${install}")"
[[ -n "${bootstrap}" ]] || fail "bootstrap_from_repo_if_needed must exist in install.sh"
required_block="$(printf '%s\n' "${bootstrap}" | awk '/local required=\(/,/\)/')"
[[ "${required_block}" != *$'\n''        install.sh'* ]] \
    || fail "bootstrap required[] must not list install.sh itself (breaks the installed 5gpn-ctl)"
[[ "${required_block}" == *'lib/common.sh'* ]] \
    || fail "bootstrap required[] must still validate the lib payload"

echo "ctl self-contained policy OK"
