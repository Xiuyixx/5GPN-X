#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${PGW_GO_PREFIX:-/opt/5gpn}"
bin="${prefix}/bin/5gpn-go"
config="${PGW_GO_CONFIG:-${prefix}/etc/5gpn-go.json}"
offset="${PGW_GO_OFFSET:-/var/lib/5gpn/tgbot-go.offset}"
user="${PGW_GO_USER:-root}"
mkdir -p "${prefix}/bin" "$(dirname "$config")" "$(dirname "$offset")"
"${root}/scripts/build-go.sh" "$bin" >/dev/null
legacy_conf="${PGW_LEGACY_CONF:-/opt/5gpn/etc}"
legacy_exits="${PGW_LEGACY_EXITS:-/etc/5gpn/exits}"
legacy_rules="${PGW_LEGACY_RULES:-/etc/5gpn/rules.conf}"
if [[ ! -f "$config" && -f "$legacy_rules" ]]; then
  # Migration is intentionally explicit and path-isolated for reinstall/rollback tests.
  temp_root="$(mktemp -d)"
  trap 'rm -rf "$temp_root"' EXIT
  mkdir -p "$temp_root/bin" "$temp_root/etc"
  cp "$bin" "$temp_root/bin/5gpn-go"
  PGW_GO_CONFIG="$config" PGW_LEGACY_CONF="$legacy_conf" PGW_LEGACY_EXITS="$legacy_exits" PGW_LEGACY_RULES="$legacy_rules" "$temp_root/bin/5gpn-go" migrate
fi
chmod 0755 "$bin"
# Generate the unit with stable paths and explicit service hardening.
cat > "${prefix}/5gpn-go.service" <<EOF
[Unit]
Description=5GPN-X Go gateway runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
ExecStart=${bin} run
Environment=PGW_GO_CONFIG=${config}
Environment=PGW_GO_OFFSET=${offset}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
if [[ "${PGW_GO_ENABLE:-0}" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
  install -m 0644 "${prefix}/5gpn-go.service" /etc/systemd/system/5gpn-go.service
  systemctl daemon-reload
  systemctl enable --now 5gpn-go.service
fi
if [[ "${PGW_GO_CHECK:-0}" == "1" ]]; then
  "$bin" check
fi
printf '%s\n' "$bin"
