package service

import (
	"context"
	"testing"
)

func TestExternalProcessLifecycle(t *testing.T) {
	p, err := NewExternalProcess("/bin/true")
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
