package rules

import (
	"net/netip"
	"testing"
)

func targetOK(name string) bool { return name == "DIRECT" || name == "WTT" || name == "REJECT" }

func TestParseAndMatchFirstMatchInputs(t *testing.T) {
	got, err := Parse([]string{
		"# comment",
		"DOMAIN-SUFFIX,OpenAI.COM,DIRECT",
		"DOMAIN-KEYWORD,claude,WTT",
		"IP-CIDR,1.2.3.0/24,DIRECT",
	}, targetOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0].Raw != "DOMAIN-SUFFIX,openai.com,DIRECT" {
		t.Fatalf("rules: %#v", got)
	}
	if !got[0].Matches("api.openai.com", netip.Addr{}) {
		t.Fatal("suffix did not match")
	}
	if got[0].Matches("openai.example", netip.Addr{}) {
		t.Fatal("suffix matched unrelated domain")
	}
	if !got[1].Matches("api.claude.ai", netip.Addr{}) {
		t.Fatal("keyword did not match")
	}
	if !got[2].Matches("", netip.MustParseAddr("1.2.3.9")) {
		t.Fatal("cidr did not match")
	}
}

func TestRejectsFinalAndUnknownTarget(t *testing.T) {
	if _, err := Parse([]string{"FINAL,WTT"}, targetOK); err == nil {
		t.Fatal("FINAL accepted as custom rule")
	}
	if _, err := Parse([]string{"DOMAIN-SUFFIX,example.com,missing"}, targetOK); err == nil {
		t.Fatal("unknown target accepted")
	}
}
