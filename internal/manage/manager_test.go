package manage

import (
	"testing"

	"github.com/Xiuyixx/5GPN-X/internal/config"
)

func TestManagerUsesOneStatePath(t *testing.T) {
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	m := New(cfg, "")
	if err := m.SetDefault("WTT"); err != nil {
		t.Fatal(err)
	}
	if err := m.SetApp("chatgpt", "DIRECT"); err != nil {
		t.Fatal(err)
	}
	if d := m.Decision("chatgpt", "api.openai.com"); d.Action != "DIRECT" {
		t.Fatalf("decision: %#v", d)
	}
	if d := m.Decision("", "example.net"); d.Action != "WTT" {
		t.Fatalf("fallback: %#v", d)
	}
}

func TestManagerRejectsInvalidChanges(t *testing.T) {
	m := New(config.Default(), "")
	if err := m.SetApp("unknown", "DIRECT"); err == nil {
		t.Fatal("unknown app accepted")
	}
	if err := m.SetDefault("missing"); err == nil {
		t.Fatal("unknown egress accepted")
	}
}
