#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables are consumed by the eval-loaded regen_smart function.
# shellcheck disable=SC2016 # The fake mihomo binary intentionally expands at run time.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

BASE_DIR="${tmp}/opt"
CONF_DIR="${tmp}/etc"
EXITS_DIR="${CONF_DIR}/exits"
WG_DIR="${tmp}/wireguard"
RULESET_CACHE="${CONF_DIR}/rulesets"
RULES_FILE="${CONF_DIR}/rules.conf"
RULES_DEFAULT="${CONF_DIR}/rules-default.conf"
POLICY_MAP="${CONF_DIR}/policy-map.conf"
MIHOMO_ROUTER_GEN="${tmp}/router.py"
MIHOMO_BIN="${tmp}/mihomo"
mkdir -p "$EXITS_DIR" "${CONF_DIR}/mihomo/smart" "$RULESET_CACHE" "${BASE_DIR}/bin"
printf 'DOMAIN,example.com,direct\n' > "$RULES_FILE"
printf 'smart\n' > "${CONF_DIR}/current-exit"
printf 'OLD-YAML\n' > "${EXITS_DIR}/smart.yaml"
printf 'old-router\n' > "${EXITS_DIR}/smart.type"
printf 'print("NEW-YAML")\n' > "$MIHOMO_ROUTER_GEN"
printf '#!/bin/sh\n[ "${FAIL_PREFLIGHT:-0}" != 1 ]\n' > "$MIHOMO_BIN"
chmod +x "$MIHOMO_ROUTER_GEN" "$MIHOMO_BIN"

exit_mihomo_conf() { echo "${EXITS_DIR}/${1}.yaml"; }
exit_type_file() { echo "${EXITS_DIR}/${1}.type"; }
ok() { :; }
info() { :; }
err() { :; }

ensure_proxy_user() { :; }
setup_exit_switching() { :; }
ensure_mihomo() { :; }
install_mihomo_unit() { :; }
exit_wait_device() { return 0; }
apply_current_exit() { return 0; }
# First restart applies the new config and fails; second restart restores old.
printf '0\n' > "${tmp}/restart.count"
systemctl() {
    if [[ "${1:-}" == restart ]]; then
        local count
        count="$(cat "${tmp}/restart.count")"
        count=$((count + 1))
        printf '%s\n' "$count" > "${tmp}/restart.count"
        [[ $count -gt 1 ]]
        return
    fi
    return 0
}

eval "$(awk '/^regen_smart\(\) \{/{copy=1} copy{if ($0 ~ /^set_rules\(\) \{$/) exit; print}' "${root}/install.sh")"

# A failed mihomo -t preflight must not touch the installed config or service.
export FAIL_PREFLIGHT=1
if (regen_smart) >/dev/null 2>&1; then
    echo "regen_smart should reject an invalid generated config" >&2
    exit 1
fi
unset FAIL_PREFLIGHT
[[ "$(cat "${EXITS_DIR}/smart.yaml")" == OLD-YAML && "$(cat "${tmp}/restart.count")" -eq 0 ]] || {
    echo "preflight failure must leave the old config and service untouched" >&2; exit 1;
}

# A config that passes preflight but fails while restarting must roll back.
if (regen_smart) >/dev/null 2>&1; then
    echo "regen_smart should fail when the new active service cannot restart" >&2
    exit 1
fi
[[ "$(cat "${EXITS_DIR}/smart.yaml")" == OLD-YAML ]] || {
    echo "failed smart apply must restore the previous YAML" >&2; exit 1;
}
[[ "$(cat "${EXITS_DIR}/smart.type")" == old-router ]] || {
    echo "failed smart apply must restore the previous type marker" >&2; exit 1;
}
[[ "$(cat "${tmp}/restart.count")" -eq 2 ]] || {
    echo "rollback must restart the previous smart service" >&2; exit 1;
}

printf 'smart apply rollback OK\n'
