package ruleset

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestDomainSetMatchesSubdomains(t *testing.T) {
	s := NewDomainSet([]string{"openai.com", "||claude.ai", "*.example.net"})
	for _, domain := range []string{"openai.com", "api.openai.com", "claude.ai", "x.claude.ai", "a.example.net"} {
		if !s.Match(domain) {
			t.Errorf("did not match %s", domain)
		}
	}
	if s.Match("notopenai.com") {
		t.Error("matched unrelated suffix")
	}
}

func TestFetchCachesAtomically(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("openai.com\n")) }))
	defer ts.Close()
	dir := t.TempDir()
	set, err := Fetch(context.Background(), ts.Client(), ts.URL, dir, "openai")
	if err != nil || !set.Match("api.openai.com") {
		t.Fatalf("fetch: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "openai.list")); err != nil {
		t.Fatal(err)
	}
	set, err = Fetch(context.Background(), nil, "http://invalid", dir, "openai")
	if err != nil || !set.Match("openai.com") {
		t.Fatalf("cache: %v", err)
	}
}
