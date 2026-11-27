// Package apps contains the stable application catalog used by routing and Bot UI.
package apps

import "strings"

type App struct {
	Key    string
	Name   string
	IconID string
	Core   []string
}

var catalog = []App{
	{Key: "google", Name: "Google", IconID: "5855241013836127351", Core: []string{"google.com", "googleapis.com", "gstatic.com"}},
	{Key: "youtube", Name: "YouTube", IconID: "5818947960364342679", Core: []string{"youtube.com", "googlevideo.com", "ytimg.com"}},
	{Key: "chatgpt", Name: "ChatGPT", IconID: "5861557411784957025", Core: []string{"openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com"}},
	{Key: "claude", Name: "Claude", IconID: "5872779796257184592", Core: []string{"claude.ai", "claude.com", "anthropic.com"}},
	{Key: "gemini", Name: "Gemini", IconID: "5866057150236727962", Core: []string{"gemini.google.com", "generativelanguage.googleapis.com"}},
	{Key: "grok", Name: "Grok", IconID: "5855218413718215319", Core: []string{"x.ai", "grok.com"}},
	{Key: "meta", Name: "Meta", IconID: "6046128455894965411", Core: []string{"facebook.com", "instagram.com", "whatsapp.com"}},
	{Key: "tiktok", Name: "TikTok", IconID: "5909018290759408000", Core: []string{"tiktok.com", "tiktokv.com", "tiktokcdn.com"}},
	{Key: "github", Name: "GitHub", IconID: "5870608651634349775", Core: []string{"github.com", "githubusercontent.com"}},
}

func All() []App { return append([]App(nil), catalog...) }
func Get(key string) (App, bool) {
	for _, a := range catalog {
		if a.Key == key {
			return a, true
		}
	}
	return App{}, false
}

func NormalizeTarget(target string) string {
	if strings.EqualFold(target, "local") || strings.EqualFold(target, "direct") {
		return "DIRECT"
	}
	return target
}

func (a App) Rules(target string) []string {
	target = NormalizeTarget(target)
	out := make([]string, 0, len(a.Core))
	for _, domain := range a.Core {
		out = append(out, "DOMAIN-SUFFIX,"+domain+","+target)
	}
	return out
}
