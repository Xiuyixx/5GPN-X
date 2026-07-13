#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}")"

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

if [[ "${install_body}" != *'systemd_unit_for_pid()'* ]]; then
    echo "install.sh must resolve the systemd unit that owns port 53 before stopping it." >&2
    exit 1
fi

if [[ "${install_body}" != *'port53_pids()'* || "${install_body}" != *'wait_for_port53_free 10'* ]]; then
    echo "install.sh must enumerate all port 53 owners and wait for the port to be released." >&2
    exit 1
fi

if [[ "${install_body}" != *'stop_systemd_unit_and_socket()'* || "${install_body}" != *'${unit%.service}.socket'* ]]; then
    echo "install.sh must stop matching systemd sockets when freeing port 53." >&2
    exit 1
fi

if [[ "${install_body}" != *'Still in use by: $(port53_owner_summary)'* ]]; then
    echo "install.sh must report the remaining port 53 owner when cleanup fails." >&2
    exit 1
fi

if [[ "${install_body}" != *'systemd-resolved.service'* ]]; then
    echo "install.sh must handle systemd-resolved when it owns port 53 as systemd-resolve." >&2
    exit 1
fi

echo "install entrypoint policy OK"
