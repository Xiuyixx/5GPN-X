package quic

import (
	"context"
	"testing"
)

func TestProcessRejectsInvalidConfig(t *testing.T) {
	if _, err := NewProcess("/bin/true", Config{}); err == nil {
		t.Fatal("invalid config accepted")
	}
}
func TestProcessLifecycle(t *testing.T) {
	p, err := NewProcess("/bin/true", Config{Listen: ":443", DNSFile: "/tmp/dns"})
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := p.Wait(); err != nil {
		t.Fatal(err)
	}
	if err := p.Stop(); err != nil {
		t.Fatal(err)
	}
}
