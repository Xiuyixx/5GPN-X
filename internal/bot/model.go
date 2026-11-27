// Package bot contains the Go Telegram control surface.
package bot

import (
	"fmt"
	"sort"

	"github.com/Xiuyixx/5GPN-X/internal/apps"
	"github.com/Xiuyixx/5GPN-X/internal/config"
)

type Button struct{ Text, Data, IconID string }
type Screen struct {
	Text string
	Rows [][]Button
}

func AppsScreen(cfg config.Config) Screen {
	selected := 0
	for _, app := range apps.All() {
		if cfg.Apps[app.Key] != "" {
			selected++
		}
	}
	text := "应用分流\n\n选择应用设置单独出口。"
	if selected > 0 {
		text = fmt.Sprintf("应用分流\n\n已设置 %d 个应用。", selected)
	}
	var rows [][]Button
	row := []Button{}
	for _, app := range apps.All() {
		row = append(row, Button{Text: app.Name, Data: "app:" + app.Key, IconID: app.IconID})
		if len(row) == 2 {
			rows = append(rows, row)
			row = nil
		}
	}
	if len(row) > 0 {
		rows = append(rows, row)
	}
	return Screen{Text: text, Rows: rows}
}

func AppScreen(cfg config.Config, key string) (Screen, error) {
	app, ok := apps.Get(key)
	if !ok {
		return Screen{}, fmt.Errorf("unknown application %q", key)
	}
	target := cfg.Apps[key]
	if target == "" {
		target = "跟随默认"
	}
	choices := []Button{{Text: "跟随默认", Data: "app-set:" + key + ":-"}, {Text: "本机直出", Data: "app-set:" + key + ":DIRECT"}}
	for _, e := range cfg.Egress {
		if e.Name != "DIRECT" {
			choices = append(choices, Button{Text: e.Name, Data: "app-set:" + key + ":" + e.Name})
		}
	}
	for i := range choices {
		if choices[i].Text == target || (target == "DIRECT" && choices[i].Text == "本机直出") {
			choices[i].Text = "● " + choices[i].Text
		}
	}
	var rows [][]Button
	for i := 0; i < len(choices); i += 2 {
		end := i + 2
		if end > len(choices) {
			end = len(choices)
		}
		rows = append(rows, choices[i:end])
	}
	return Screen{Text: fmt.Sprintf("%s\n\n当前出口：%s", app.Name, target), Rows: rows}, nil
}

func ExitsScreen(cfg config.Config) Screen {
	exits := append([]config.EgressConfig(nil), cfg.Egress...)
	sort.SliceStable(exits, func(i, j int) bool { return exits[i].Name < exits[j].Name })
	var rows [][]Button
	row := []Button{}
	for _, e := range exits {
		mark := "○"
		if e.Name == cfg.Final || (e.Name == "DIRECT" && cfg.Final == "DIRECT") {
			mark = "●"
		}
		row = append(row, Button{Text: mark + " " + e.Name, Data: "exit:" + e.Name})
		if len(row) == 2 {
			rows = append(rows, row)
			row = nil
		}
	}
	if len(row) > 0 {
		rows = append(rows, row)
	}
	return Screen{Text: "出口管理\n\n选择出口查看或切换。", Rows: rows}
}
