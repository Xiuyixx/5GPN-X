package egress

import (
	"testing"

	"github.com/Xiuyixx/5GPN-X/internal/config"
)

func TestDefaultAndAppMutations(t *testing.T) {
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	m := NewManager(cfg, "")
	if err := m.SetDefault("WTT"); err != nil {
		t.Fatal(err)
	}
	if err := m.SetApp("chatgpt", "local"); err != nil {
		t.Fatal(err)
	}
	got := m.Snapshot()
	if got.Final != "WTT" || got.Apps["chatgpt"] != Direct {
		t.Fatalf("unexpected state: %#v", got)
	}
	if err := m.SetApp("chatgpt", ""); err != nil {
		t.Fatal(err)
	}
	if _, ok := m.Snapshot().Apps["chatgpt"]; ok {
		t.Fatal("app override was not removed")
	}
}

func TestUnknownTargetsAreRejected(t *testing.T) {
	m := NewManager(config.Default(), "")
	if err := m.SetDefault("missing"); err == nil {
		t.Fatal("unknown default accepted")
	}
	if err := m.SetApp("chatgpt", "missing"); err == nil {
		t.Fatal("unknown app target accepted")
	}
	if err := m.SetApp("missing", Direct); err == nil {
		t.Fatal("unknown app accepted")
	}
}
