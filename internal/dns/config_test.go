package dns

import "testing"

func TestDNSConfigValidation(t *testing.T) {
	cfg := Config{DoTListen: ":853", DNSListen: "127.0.0.1:5353", Upstream: []string{"1.1.1.1:53"}, GatewayIP: "127.0.0.1"}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	cfg.Upstream = []string{"bad"}
	if err := cfg.Validate(); err == nil {
		t.Fatal("invalid upstream accepted")
	}
}

func TestNormalizeUpstreams(t *testing.T) {
	got := NormalizeUpstreams([]string{" 1.1.1.1:53", "1.1.1.1:53", "", "8.8.8.8:53"})
	if len(got) != 2 || got[0] != "1.1.1.1:53" {
		t.Fatalf("%v", got)
	}
}
