package bot

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Xiuyixx/5GPN-X/internal/config"
	"github.com/Xiuyixx/5GPN-X/internal/manage"
)

func TestHandlerAppSetStaysOnAppScreen(t *testing.T) {
	var bodies []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(b)
		bodies = append(bodies, string(b))
		_, _ = w.Write([]byte(`{"ok":true,"result":{}}`))
	}))
	defer ts.Close()
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	h := &Handler{Client: NewTelegramClient("test"), Manager: manage.New(cfg, ""), Admins: map[int64]bool{1: true}}
	h.Client.BaseURL = ts.URL
	if err := h.Handle(context.Background(), Update{Callback: &CallbackQuery{ID: "1", From: User{ID: 1}, Data: "app-set:chatgpt:DIRECT", Message: &Message{MessageID: 9, Chat: Chat{ID: 10}}}}); err != nil {
		t.Fatal(err)
	}
	if len(bodies) < 2 || !strings.Contains(bodies[len(bodies)-1], "ChatGPT") {
		t.Fatalf("did not render app detail: %v", bodies)
	}
	if h.Manager.Snapshot().Apps["chatgpt"] != "DIRECT" {
		t.Fatal("app target not persisted")
	}
}
