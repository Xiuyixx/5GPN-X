package egress

import (
	"github.com/Xiuyixx/5GPN-X/internal/config"
	"testing"
)

func TestRegistryLifecycle(t *testing.T) {
	r := NewRegistry()
	d := NewDirectDialer()
	if err := r.Register("DIRECT", d); err != nil {
		t.Fatal(err)
	}
	if err := r.Register("DIRECT", d); err == nil {
		t.Fatal("duplicate accepted")
	}
	cfg := config.Default()
	if err := r.Sync(cfg); err != nil {
		t.Fatal(err)
	}
	r.Remove("DIRECT")
	if _, ok := r.Get("DIRECT"); ok {
		t.Fatal("remove failed")
	}
}
