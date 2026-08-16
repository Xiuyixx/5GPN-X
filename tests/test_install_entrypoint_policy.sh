#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}" "${root}/lib/common.sh" "${root}/lib/dns.sh" "${root}/lib/cert.sh" "${root}/lib/services.sh" "${root}/lib/exits.sh" "${root}/lib/rules.sh" "${root}/lib/uninstall.sh")"

if [[ ! -x "${install}" ]]; then
    echo "install.sh must be executable after cloning the repository." >&2
    exit 1
fi

# `bash -c "$(curl .../install.sh)"` passes the complete script as one Linux
# argument. Linux limits one argument to 128 KiB (MAX_ARG_STRLEN).
install_size="$(wc -c < "${install}")"
if (( install_size >= 131072 )); then
    echo "install.sh must stay below 128 KiB for the documented bash -c installer (${install_size} bytes)." >&2
    exit 1
fi

first_three="$(head -c 3 "${install}" | od -An -tx1 | tr -d ' \n')"
if [[ "${first_three}" == "efbbbf" ]]; then
    echo "install.sh must not start with a UTF-8 BOM; it breaks the shebang when executed directly." >&2
    exit 1
fi

first_line="$(head -n 1 "${install}")"
if [[ "${first_line}" != "#!/usr/bin/env bash" && "${first_line}" != "#!/bin/bash" ]]; then
    echo "install.sh must start with a plain bash shebang." >&2
    exit 1
fi

[[ "${install_body}" != *'check_port_53()'* ]] \
    || { echo "installer must not stop services to claim port 53." >&2; exit 1; }
[[ "${install_body}" != *'systemd-resolved.service'* ]] \
    || { echo "installer must leave systemd-resolved untouched." >&2; exit 1; }
[[ "${install_body}" != *'/etc/resolv.conf.pgw.bak'* ]] \
    || { echo "installer must not rewrite the host resolver configuration." >&2; exit 1; }

echo "install entrypoint policy OK"
