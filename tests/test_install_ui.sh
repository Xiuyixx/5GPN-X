#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_body="$(cat "${root}/install.sh")"
common_body="$(cat "${root}/lib/common.sh")"
cert_body="$(cat "${root}/lib/cert.sh")"
dns_body="$(cat "${root}/lib/dns.sh")"
services_body="$(cat "${root}/lib/services.sh")"

fail() {
    echo "$*" >&2
    exit 1
}

stages=(
    "检查运行环境"
    "安装系统依赖"
    "配置域名与 TLS 证书"
    "部署网络服务"
    "启动并完成配置"
)

for stage in "${stages[@]}"; do
    [[ "$install_body" == *"run_install_step \"${stage}\""* ]] || fail "missing install stage: ${stage}"
done

[[ "$install_body" == *"✓ 安装完成"* ]] || fail "missing concise completion summary"
[[ "$install_body" != *"高性能反代系统一键部署"* ]] || fail "legacy install banner must stay removed"
[[ "$install_body" != *"         部署完成！"* ]] || fail "legacy completion banner must stay removed"
# shellcheck disable=SC2016 # Match the literal variable reference in install.sh.
[[ "$install_body" == *'${BASE_DIR}/bin/5gpn-ctl --status'* ]] || fail "completion summary must use the stable management path"
[[ "$install_body" != *"info()"* ]] || fail "install.sh must reuse the common logger"
# shellcheck disable=SC2016 # Match the literal variable reference in install.sh.
[[ "$install_body" != *'cat "${WWW_DIR}/ios-dot.qr.txt"'* ]] || fail "completion summary must not print a full terminal QR code"
[[ "$common_body" == *"run_install_step()"* ]] || fail "common logger must provide the install runner"
[[ "$common_body" == *'/var/log/5gpn-install.log'* ]] || fail "installer must keep a persistent detail log"
[[ "$common_body" == *"collect_port53_confirmation()"* ]] || fail "port 53 confirmation must be separated from quiet execution"
[[ "$cert_body" != *'info "=================================================="'* ]] || fail "verbose DNS separator must stay removed"
[[ "$cert_body" != *'info "   TTL:'* ]] || fail "verbose DNS instruction block must stay removed"
[[ "$cert_body" != *'echo "  请输入你自己的域名"'* ]] || fail "legacy domain-entry banner must stay removed"
# shellcheck disable=SC2016 # Match the literal variable reference in dns.sh.
[[ "$dns_body" == *'"${PROMPT_DNS:-0}" == "1"'* ]] || fail "DNS prompts must be opt-in during installation"
[[ "$services_body" == *'read -r -p "Telegram Bot Token'* ]] || fail "Telegram token input must remain visible"

# shellcheck disable=SC1091 # Source path is resolved dynamically from the test location.
. "${root}/lib/common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
INSTALL_LOG="${tmp}/install.log"
init_install_log

mock_success() {
    echo "verbose stdout detail"
    echo "verbose stderr detail" >&2
}

success_output="$(run_install_step "模拟成功阶段" mock_success 2>&1)"
[[ "$success_output" == *"✓ 模拟成功阶段"* ]] || fail "successful stage must print one completion line"
[[ "$success_output" != *"verbose"* ]] || fail "successful stage details must stay out of the terminal"
grep -q "verbose stdout detail" "$INSTALL_LOG" || fail "stdout detail must be written to the install log"
grep -q "verbose stderr detail" "$INSTALL_LOG" || fail "stderr detail must be written to the install log"

mock_failure() {
    echo "fatal stage error" >&2
    exit 7
}

set +e
failure_output="$(run_install_step "模拟失败阶段" mock_failure 2>&1)"
failure_rc=$?
set -e
[[ "$failure_rc" -eq 7 ]] || fail "failed stage must preserve its exit code"
[[ "$failure_output" == *"✗ 模拟失败阶段"* ]] || fail "failed stage must print one failure line"
[[ "$failure_output" == *"详细日志: $INSTALL_LOG"* ]] || fail "failed stage must print the persistent log path"

mock_errexit() {
    false
    echo "must not continue after a failed command"
}

set +e
run_install_step "严格失败阶段" mock_errexit >/dev/null 2>&1
errexit_rc=$?
set -e
[[ "$errexit_rc" -ne 0 ]] || fail "stage runner must stop on an unhandled command failure"
! grep -q "must not continue" "$INSTALL_LOG" || fail "stage runner continued after a failed command"

echo "install UI policy OK"
