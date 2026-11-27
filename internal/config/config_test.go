package config

import (
	"path/filepath"
	"testing"
)

func TestConfigRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	want := Default()
	want.Apps["chatgpt"] = "DIRECT"
	if err := want.Save(path); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Apps["chatgpt"] != "DIRECT" || got.Final != "direct" {
		t.Fatalf("round trip mismatch: %#v", got)
	}
}
