#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell snippets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules="$(cat "${root}/lib/update-rules.sh")"

if [[ "${rules}" != *'DNSDIST_CONF_TMP=$(mktemp "${DNSDIST_CONF}.tmp.XXXXXX")'* ]]; then
    echo "update-rules.sh must generate dnsdist.conf through a temporary file." >&2
    exit 1
fi

if [[ "${rules}" != *'dnsdist --check-config -C "${DNSDIST_CONF_TMP}"'* ]]; then
    echo "update-rules.sh must validate the temporary dnsdist.conf before installing it." >&2
    exit 1
fi

if [[ "${rules}" != *'install -m 0644 "${DNSDIST_CONF_TMP}" "${DNSDIST_CONF}"'* ]]; then
    echo "update-rules.sh must atomically install dnsdist.conf only after validation." >&2
    exit 1
fi

if [[ "${rules}" != *'Generated dnsdist configuration failed validation'* ]]; then
    echo "update-rules.sh must stop with a clear error when dnsdist config validation fails." >&2
    exit 1
fi

echo "update-rules dnsdist config validation policy OK"
