// Package policy implements ordered first-match routing decisions.
package policy

import (
	"fmt"
	"net/netip"
	"strings"

	"github.com/Xiuyixx/5GPN-X/internal/apps"
	"github.com/Xiuyixx/5GPN-X/internal/config"
	"github.com/Xiuyixx/5GPN-X/internal/rules"
)

type Action string

const (
	ActionDirect Action = "DIRECT"
	ActionBlock  Action = "REJECT"
)

type Decision struct {
	Action string
	Rule   string
}

type Engine struct {
	cfg    config.Config
	parsed []rules.Rule
}

func New(cfg config.Config) Engine {
	parsed, _ := rules.Parse(cfg.Rules, func(target string) bool { return ValidateTarget(cfg, target) == nil })
	return Engine{cfg: cfg, parsed: parsed}
}

func (e Engine) Match(appKey, domain string) Decision {
	if target, ok := e.cfg.Apps[appKey]; ok {
		if a, exists := apps.Get(appKey); exists {
			for _, rule := range a.Rules(target) {
				if strings.HasSuffix(strings.ToLower(domain), strings.TrimPrefix(strings.Split(rule, ",")[1], ".")) {
					return Decision{Action: apps.NormalizeTarget(target), Rule: rule}
				}
			}
		}
	}
	for _, rule := range e.parsed {
		if rule.Matches(domain, netip.Addr{}) {
			return Decision{Action: rule.Target, Rule: rule.Raw}
		}
	}
	return Decision{Action: e.cfg.Final, Rule: "FINAL"}
}

// Default returns the configured fallback action.
func (e Engine) Default() string { return e.cfg.Final }

func ValidateTarget(cfg config.Config, target string) error {
	target = apps.NormalizeTarget(target)
	if target == string(ActionDirect) || target == string(ActionBlock) || target == "" {
		return nil
	}
	for _, e := range cfg.Egress {
		if e.Name == target {
			return nil
		}
	}
	return fmt.Errorf("unknown egress %q", target)
}
