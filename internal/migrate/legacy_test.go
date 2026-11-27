package migrate

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadLegacyPreservesExitRulesAndApps(t *testing.T) {
	root := t.TempDir()
	conf, exits := filepath.Join(root, "etc"), filepath.Join(root, "exits")
	if err := os.MkdirAll(conf, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(exits, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "current-exit"), []byte("WTT\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(exits, "WTT.type"), []byte("socks5\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rules := filepath.Join(root, "rules.conf")
	data := "# 5GPN-APP chatgpt\nDOMAIN-SUFFIX,openai.com,direct\nDOMAIN-SUFFIX,example.com,WTT\n"
	if err := os.WriteFile(rules, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadLegacy(Paths{ConfDir: conf, ExitsDir: exits, Rules: rules})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Final != "WTT" || cfg.Apps["chatgpt"] != "DIRECT" || len(cfg.Rules) != 2 {
		t.Fatalf("bad migration: %#v", cfg)
	}
}
