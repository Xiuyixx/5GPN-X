package quic

import "testing"

func TestConfigValidation(t *testing.T) {
	if err := (Config{Listen: ":443", DNSFile: "/tmp/dns"}).Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (Config{}).Validate(); err == nil {
		t.Fatal("empty config accepted")
	}
}
