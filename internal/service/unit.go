// Package service generates the Go runtime's systemd unit without touching the host.
package service

import "fmt"

func Unit(binary, config, offset, user string) string {
	if user == "" {
		user = "root"
	}
	return fmt.Sprintf(`[Unit]
Description=5GPN-X Go gateway runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%s
ExecStart=%s run
Environment=PGW_GO_CONFIG=%s
Environment=PGW_GO_OFFSET=%s
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
`, user, binary, config, offset)
}
