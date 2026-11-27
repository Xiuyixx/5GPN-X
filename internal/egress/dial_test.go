package egress

import (
	"bufio"
	"context"
	"io"
	"net"
	"testing"
)

func TestDirectDialer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, _ := ln.Accept()
		if c != nil {
			_, _ = io.Copy(c, c)
			_ = c.Close()
		}
	}()
	c, err := NewDirectDialer().DialContext(context.Background(), ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, _ = c.Write([]byte("ok"))
	got := make([]byte, 2)
	if _, err := io.ReadFull(c, got); err != nil || string(got) != "ok" {
		t.Fatalf("echo: %q %v", got, err)
	}
}

func TestSOCKS5Dialer(t *testing.T) {
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		c, _ := target.Accept()
		if c != nil {
			_, _ = io.Copy(c, c)
			_ = c.Close()
		}
	}()
	proxy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	go func() {
		c, _ := proxy.Accept()
		if c == nil {
			return
		}
		r := bufio.NewReader(c)
		hello := make([]byte, 3)
		_, _ = io.ReadFull(r, hello)
		_, _ = c.Write([]byte{5, 0})
		req := make([]byte, 4)
		_, _ = io.ReadFull(r, req)
		if req[3] == 1 {
			b := make([]byte, 4+2)
			_, _ = io.ReadFull(r, b)
		} else {
			l, _ := r.ReadByte()
			b := make([]byte, int(l)+2)
			_, _ = io.ReadFull(r, b)
		}
		_, _ = c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1})
		_, _ = io.Copy(c, c)
		_ = c.Close()
	}()
	c, err := NewSOCKS5Dialer(proxy.Addr().String()).DialContext(context.Background(), target.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
}
