package apps

import "testing"

func TestCatalogContainsCoreAppsAndIcons(t *testing.T) {
	for _, key := range []string{"chatgpt", "claude", "gemini", "meta"} {
		a, ok := Get(key)
		if !ok || a.IconID == "" || len(a.Core) == 0 {
			t.Fatalf("catalog entry %q is incomplete: %#v", key, a)
		}
	}
}

func TestNormalizeTarget(t *testing.T) {
	if got := NormalizeTarget("local"); got != "DIRECT" {
		t.Fatalf("local => %q", got)
	}
	if got := NormalizeTarget("DIRECT"); got != "DIRECT" {
		t.Fatalf("DIRECT => %q", got)
	}
}

func TestRulesUseDirectWithoutSmart(t *testing.T) {
	a, _ := Get("chatgpt")
	for _, rule := range a.Rules("local") {
		if rule[len(rule)-len("DIRECT"):] != "DIRECT" {
			t.Fatalf("rule is not DIRECT: %s", rule)
		}
	}
}
