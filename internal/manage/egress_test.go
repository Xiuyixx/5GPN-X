package manage

import (
	"github.com/Xiuyixx/5GPN-X/internal/config"
	"testing"
)

func TestEgressLifecycle(t *testing.T) {
	m := New(config.Default(), "")
	e, err := m.AddURI("socks5://node.example:1080#WTT")
	if err != nil {
		t.Fatal(err)
	}
	if e.Name != "WTT" {
		t.Fatal(e.Name)
	}
	if err := m.SetDefault("WTT"); err != nil {
		t.Fatal(err)
	}
	if err := m.RenameEgress("WTT", "WTT2"); err != nil {
		t.Fatal(err)
	}
	if m.Snapshot().Final != "WTT2" {
		t.Fatal("default not renamed")
	}
	if err := m.DeleteEgress("WTT2"); err == nil {
		t.Fatal("active deletion accepted")
	}
	if err := m.SetDefault("DIRECT"); err != nil {
		t.Fatal(err)
	}
	if err := m.DeleteEgress("WTT2"); err != nil {
		t.Fatal(err)
	}
}
