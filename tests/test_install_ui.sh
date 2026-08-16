#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_body="$(cat "${root}/install.sh")"
common_body="$(cat "${root}/lib/common.sh")"
cert_body="$(cat "${root}/lib/cert.sh")"

fail() {
    echo "$*" >&2
    exit 1
}

stages=(
    "检查运行环境"
    "安装系统依赖"
    "配置域名、证书与 DNS"
    "部署代理与 DNS 服务"
    "配置分流与系统网络"
    "生成客户端配置"
    "启动服务并完成自检"
    "配置自动维护与管理"
)

for stage in "${stages[@]}"; do
    [[ "$install_body" == *"step \"${stage}\""* ]] || fail "missing install stage: ${stage}"
done

[[ "$install_body" == *"  安装完成"* ]] || fail "missing concise completion summary"
[[ "$install_body" != *"高性能反代系统一键部署"* ]] || fail "legacy install banner must stay removed"
[[ "$install_body" != *"         部署完成！"* ]] || fail "legacy completion banner must stay removed"
[[ "$install_body" != *"info()"* ]] || fail "install.sh must reuse the common logger"
# shellcheck disable=SC2016 # Match the literal variable reference in install.sh.
[[ "$install_body" != *'cat "${WWW_DIR}/ios-dot.qr.txt"'* ]] || fail "completion summary must not print a full terminal QR code"
[[ "$common_body" == *"step()"* ]] || fail "common logger must provide stage headings"
[[ "$cert_body" != *'info "=================================================="'* ]] || fail "verbose DNS separator must stay removed"
[[ "$cert_body" != *'info "   TTL:'* ]] || fail "verbose DNS instruction block must stay removed"
[[ "$cert_body" != *'echo "  请输入你自己的域名"'* ]] || fail "legacy domain-entry banner must stay removed"

echo "install UI policy OK"
