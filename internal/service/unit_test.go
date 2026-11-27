package service

import "testing"

func TestUnitContainsRuntimeEntrypoint(t *testing.T) {
	unit := Unit("/opt/5gpn/bin/5gpn-go", "/opt/5gpn/etc/5gpn-go.json", "/var/lib/5gpn/tgbot-go.offset", "root")
	for _, want := range []string{"ExecStart=/opt/5gpn/bin/5gpn-go run", "PGW_GO_CONFIG=", "Restart=on-failure", "NoNewPrivileges=true"} {
		if !contains(unit, want) {
			t.Fatalf("unit missing %q", want)
		}
	}
}
func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
