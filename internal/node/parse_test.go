package node

import "testing"

func TestParseURI(t *testing.T) {
	for _, raw := range []string{"socks5://user:pass@example.com:1080#WTT", "trojan://secret@example.com:443#node", "vless://id@example.com:443#vless"} {
		cfg, err := ParseURI(raw)
		if err != nil {
			t.Fatal(err)
		}
		if cfg.Name == "" || cfg.URI != raw {
			t.Fatalf("%#v", cfg)
		}
	}
}

func TestRejectsUnsupportedURI(t *testing.T) {
	if _, err := ParseURI("ftp://example.com"); err == nil {
		t.Fatal("unsupported scheme accepted")
	}
}
