package policy

import (
	"testing"

	"github.com/Xiuyixx/5GPN-X/internal/config"
)

func TestApplicationOverridesDefault(t *testing.T) {
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	cfg.Final = "WTT"
	cfg.Apps["chatgpt"] = "DIRECT"
	engine := New(cfg)
	if got := engine.Match("chatgpt", "api.openai.com"); got.Action != "DIRECT" {
		t.Fatalf("app action = %#v", got)
	}
	if got := engine.Match("", "example.net"); got.Action != "WTT" {
		t.Fatalf("default action = %#v", got)
	}
}

func TestValidateTarget(t *testing.T) {
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT"})
	for _, target := range []string{"DIRECT", "local", "WTT", ""} {
		if err := ValidateTarget(cfg, target); err != nil {
			t.Fatalf("%q: %v", target, err)
		}
	}
	if err := ValidateTarget(cfg, "missing"); err == nil {
		t.Fatal("missing target accepted")
	}
}
