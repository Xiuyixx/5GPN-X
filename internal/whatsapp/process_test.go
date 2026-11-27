package whatsapp

import (
	"context"
	"testing"
)

func TestProcessLifecycle(t *testing.T) {
	p, err := NewProcess("/bin/true", Config{Listen: ":443", Upstream: "127.0.0.1:8443"})
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
