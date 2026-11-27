package bot

import (
	"testing"

	"github.com/Xiuyixx/5GPN-X/internal/config"
)

func TestAppScreenKeepsSelectionModel(t *testing.T) {
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	cfg.Apps["chatgpt"] = "DIRECT"
	s, err := AppScreen(cfg, "chatgpt")
	if err != nil {
		t.Fatal(err)
	}
	if s.Text == "" || len(s.Rows) == 0 {
		t.Fatal("empty screen")
	}
	found := false
	for _, row := range s.Rows {
		for _, b := range row {
			if b.Text == "● 本机直出" {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("direct selection not marked")
	}
}

func TestAppsAndExitsUseTwoColumns(t *testing.T) {
	cfg := config.Default()
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "WTT", Type: "socks5"})
	if len(AppsScreen(cfg).Rows[0]) != 2 {
		t.Fatal("apps not two columns")
	}
	if len(ExitsScreen(cfg).Rows[0]) != 2 {
		t.Fatal("exits not two columns")
	}
}
