package runtime

import (
	"context"
	"io"
	"net"
	"testing"

	"github.com/Xiuyixx/5GPN-X/internal/config"
	"github.com/Xiuyixx/5GPN-X/internal/egress"
	"github.com/Xiuyixx/5GPN-X/internal/manage"
)

func TestDialUsesAppDirectAndDefaultExit(t *testing.T) {
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
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	cfg.Final = "WTT"
	cfg.Apps["chatgpt"] = "DIRECT"
	m := manage.New(cfg, "")
	r := New(m)
	r.Register("DIRECT", egress.NewDirectDialer())
	if _, err := r.Dial(context.Background(), "chatgpt", "api.openai.com", ln.Addr().String()); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Dial(context.Background(), "", "example.net", ln.Addr().String()); err == nil {
		t.Fatal("missing default dialer accepted")
	}
}

func TestDialRejectsBlockedRule(t *testing.T) {
	cfg := config.Default()
	cfg.Rules = []string{"DOMAIN-SUFFIX,bad.example,REJECT"}
	m := manage.New(cfg, "")
	r := New(m)
	r.Register("DIRECT", egress.NewDirectDialer())
	if _, err := r.Dial(context.Background(), "", "bad.example:443", "127.0.0.1:1"); err == nil {
		t.Fatal("blocked target dialed")
	}
}
