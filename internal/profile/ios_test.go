package profile

import (
	"encoding/xml"
	"strings"
	"testing"
)

func TestIOSDoTProfile(t *testing.T) {
	data, err := IOSDoT("dns.example.com", "1.2.3.4")
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, want := range []string{"DNSProtocol", "TLS", "dns.example.com", "1.2.3.4", "Cellular", "WiFi"} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q", want)
		}
	}
	var v any
	if err := xml.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
}
