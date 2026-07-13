#!/usr/bin/env bash
# shellcheck disable=SC2317 # set_exit is redefined to exercise two rollback outcomes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

CONF_DIR="${tmp}/conf"
EXITS_DIR="${tmp}/exits"
WG_DIR="${tmp}/wg"
RULES_FILE="${tmp}/rules.conf"
POLICY_MAP="${tmp}/policy-map.conf"
mkdir -p "${CONF_DIR}/mihomo/old" "${EXITS_DIR}" "${WG_DIR}"
printf 'smart\n' > "${CONF_DIR}/current-exit"
printf 'socks\n' > "${EXITS_DIR}/old.type"
printf 'socks5://127.0.0.1:1080\n' > "${EXITS_DIR}/old.uri"
printf '{"tun":{"device":"pgw-old"}}\n' > "${EXITS_DIR}/old.yaml"
printf 'DOMAIN-SUFFIX,example.com,old\n' > "${RULES_FILE}"
printf 'AI=old\n' > "${POLICY_MAP}"

exit_conf_path() { echo "${WG_DIR}/pgw-${1}.conf"; }
exit_type_file() { echo "${EXITS_DIR}/${1}.type"; }
exit_mihomo_conf() { echo "${EXITS_DIR}/${1}.yaml"; }
exit_exists() { [[ -f "$(exit_type_file "$1")" || -f "$(exit_conf_path "$1")" ]]; }
ok() { :; }
err() { printf '%s\n' "$*" >> "${tmp}/errors"; }
set_exit() {
    printf '%s\n' "$1" >> "${tmp}/set-exit.calls"
    printf '%s\n' "$1" > "${CONF_DIR}/current-exit"
}
regen_smart() {
    local count=0
    [[ -f "${tmp}/regen.count" ]] && count="$(cat "${tmp}/regen.count")"
    count=$((count + 1))
    printf '%s\n' "$count" > "${tmp}/regen.count"
    [[ $count -gt 1 ]]
}

eval "$(awk '/^rename_exit\(\) \{/{copy=1} copy{if ($0 ~ /^set_exit\(\) \{$/) exit; print}' "${root}/install.sh")"

if (rename_exit old new); then
    echo "rename must fail when the first smart rebuild fails" >&2
    exit 1
fi

[[ "$(cat "${CONF_DIR}/current-exit")" == "smart" ]] || {
    echo "rollback must restore the active smart exit" >&2
    exit 1
}
[[ "$(cat "${tmp}/set-exit.calls")" == $'local\nsmart' ]] || {
    echo "rollback must reactivate smart through set_exit, not only rewrite current-exit" >&2
    exit 1
}
[[ "$(cat "${tmp}/regen.count")" == "2" ]] || {
    echo "rollback must rebuild the restored smart config" >&2
    exit 1
}
[[ -f "${EXITS_DIR}/old.type" && -f "${EXITS_DIR}/old.yaml" && -f "${EXITS_DIR}/old.uri" ]] || {
    echo "rollback must restore the old exit files" >&2
    exit 1
}
[[ ! -e "${EXITS_DIR}/new.type" && ! -e "${EXITS_DIR}/new.yaml" && ! -e "${EXITS_DIR}/new.uri" ]] || {
    echo "rollback must remove renamed exit files" >&2
    exit 1
}
grep -q 'example.com,old' "${RULES_FILE}" || {
    echo "rollback must restore smart rules" >&2
    exit 1
}
grep -q 'AI=old' "${POLICY_MAP}" || {
    echo "rollback must restore the policy map" >&2
    exit 1
}

printf 'smart\n' > "${CONF_DIR}/current-exit"
printf 'socks\n' > "${EXITS_DIR}/old.type"
printf 'socks5://127.0.0.1:1080\n' > "${EXITS_DIR}/old.uri"
printf '{"tun":{"device":"pgw-old"}}\n' > "${EXITS_DIR}/old.yaml"
printf 'DOMAIN-SUFFIX,example.com,old\n' > "${RULES_FILE}"
printf 'AI=old\n' > "${POLICY_MAP}"
rm -f "${tmp}/set-exit.calls" "${tmp}/regen.count" "${tmp}/errors"
set_exit() {
    printf '%s\n' "$1" >> "${tmp}/set-exit.calls"
    [[ "$1" != "smart" ]] || return 1
    printf '%s\n' "$1" > "${CONF_DIR}/current-exit"
}

if (rename_exit old new); then
    echo "rename must fail when smart cannot be reactivated" >&2
    exit 1
fi
[[ "$(cat "${CONF_DIR}/current-exit")" == "local" ]] || {
    echo "failed smart reactivation must remain recorded as local" >&2
    exit 1
}
grep -q 'failed to reactivate smart, left on local' "${tmp}/errors" || {
    echo "failed smart reactivation must be reported" >&2
    exit 1
}

echo "rename exit rollback OK"
