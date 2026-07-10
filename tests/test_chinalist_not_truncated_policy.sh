#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules="$(cat "${root}/update-rules.sh")"
chinalist_block="$(sed -n '/Downloading ChinaList/,/Template not found/p' "${root}/update-rules.sh")"

if [[ "${rules}" == *"max=30000"* ]]; then
    echo "ChinaList must not be capped at 30000 entries; common domains like qq.com and taobao.com appear later in the upstream list." >&2
    exit 1
fi

if [[ "${chinalist_block}" == *'[[ ${count} -ge ${max} ]] && break'* ]]; then
    echo "ChinaList parsing must not stop early on a fixed max count." >&2
    exit 1
fi

if [[ "${rules}" != *'local chinaList = ...'* ]]; then
    echo "ChinaList chunks must accept chinaList as an argument to avoid dnsdist Lua constant limits." >&2
    exit 1
fi

if [[ "${rules}" != *'loadfile(chunk)'* ]]; then
    echo "dnsdist configuration should load ChinaList chunk files instead of inlining every rule." >&2
    exit 1
fi

echo "ChinaList is not truncated"
