#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
tmpl="${root}/lib/dnsdist.conf.template"
update="${root}/lib/update-rules.sh"
ioshttp="${root}/lib/ios-http.py"
install_body="$(cat "${install}")"

fail() { echo "$1" >&2; exit 1; }

# --- auto-detection ----------------------------------------------------------
[[ "${install_body}" == *'detect_memory_profile()'* ]] || fail "install.sh must auto-detect the memory profile"
[[ "${install_body}" == *'MemTotal'* ]] || fail "memory detection must read MemTotal"
[[ "${install_body}" == *'detect_memory_profile'*'ensure_swap'* ]] || fail "main_install must detect memory then ensure swap"

# --- dnsdist cache must be parametrised, not a hard 500000 -------------------
[[ "$(cat "${tmpl}")" != *'newPacketCache(500000'* ]] || fail "template must not hard-code a 500000 packet cache"
[[ "$(cat "${tmpl}")" == *'newPacketCache(__PACKET_CACHE_SIZE__'* ]] || fail "template must use the cache-size placeholder"
[[ "${install_body}" == *'PACKET_CACHE_SIZE=20000'* ]] || fail "low-memory mode must shrink the packet cache"
[[ "$(cat "${update}")" == *'__PACKET_CACHE_SIZE__'* ]] || fail "update-rules.sh must substitute the cache-size placeholder"
[[ "$(cat "${update}")" == *'.cache_size'* ]] || fail "update-rules.sh must read the persisted cache size"

# --- sysctl must scale down on low memory -----------------------------------
[[ "${install_body}" == *'sy_conntrack_max=131072'* ]] || fail "low-memory mode must shrink nf_conntrack_max"
[[ "${install_body}" == *'sy_somaxconn=4096'* ]] || fail "low-memory mode must shrink somaxconn"

# --- Go runtime caps on low memory ------------------------------------------
[[ "${install_body}" == *'GOMEMLIMIT'* ]] || fail "low-memory mode must cap Go runtime memory"

# --- swap safety net ---------------------------------------------------------
[[ "${install_body}" == *'mkswap /swapfile'* ]] || fail "low-memory mode must be able to create swap"
[[ "${install_body}" == *'confirm_swap_creation()'* ]] || fail "installer must ask before creating swap"
[[ "${install_body}" == *'检测到低内存且当前没有 swap，是否创建 swap？输入 y 开启，其它输入跳过 [y/N]'* ]] || fail "installer must prompt for explicit swap enablement"
[[ "${install_body}" == *'Y|YES) return 0'* ]] || fail "only y/yes should enable swap creation"
[[ "${install_body}" == *'请输入 swap 大小（如 0.5/1/2 或 0.5G/1G/2G；回车默认 1）'* ]] || fail "installer must prompt for interactive swap size input after confirmation"
[[ "${install_body}" == *'swap_size_to_bytes()'* ]] || fail "installer must convert swap size strings into bytes"
[[ "${install_body}" == *'input="${input}G"'* ]] || fail "numeric swap input must default to GiB units"
[[ "${install_body}" == *'Skipping swap creation by user request.'* ]] || fail "installer must acknowledge skipped swap creation"
[[ "${install_body}" == *'fallocate -l "$swap_bytes" /swapfile'* ]] || fail "swap allocation must use the requested size"
[[ "${install_body}" == *'make -j"${MAKE_JOBS:-$(nproc)}"'* ]] || fail "compile must respect the bounded job count"

# --- iOS server must be socket-activated (zero idle process) -----------------
[[ -f "${ioshttp}" ]] || fail "ios-http.py must exist"
python3 -m py_compile "${ioshttp}" || fail "ios-http.py must compile"
[[ "${install_body}" == *'proxy-gateway-ios-profile.socket'* ]] || fail "iOS server must use a systemd socket"
[[ "${install_body}" == *'Accept=yes'* ]] || fail "iOS socket must be inetd-style (Accept=yes)"
[[ "${install_body}" != *'http.server'* ]] || fail "the always-on python http.server must be gone"

echo "low-memory policy OK"
