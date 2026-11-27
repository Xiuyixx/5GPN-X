// Package rules parses and matches the ordered gateway rule language.
package rules

import (
	"fmt"
	"net/netip"
	"strings"
)

type Kind string

const (
	Domain        Kind = "DOMAIN"
	DomainSuffix  Kind = "DOMAIN-SUFFIX"
	DomainKeyword Kind = "DOMAIN-KEYWORD"
	IPCIDR        Kind = "IP-CIDR"
	RuleSet       Kind = "RULE-SET"
	GEOIP         Kind = "GEOIP"
)

type Rule struct {
	Kind   Kind
	Value  string
	Target string
	Raw    string
	prefix netip.Prefix
}

func Parse(lines []string, validTarget func(string) bool) ([]Rule, error) {
	out := make([]Rule, 0, len(lines))
	for lineNo, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		parts := strings.Split(line, ",")
		if len(parts) != 3 {
			return nil, fmt.Errorf("line %d: rule needs type,value,target", lineNo+1)
		}
		kind := Kind(strings.ToUpper(strings.TrimSpace(parts[0])))
		value := strings.TrimSpace(parts[1])
		target := strings.TrimSpace(parts[2])
		if kind == "FINAL" || kind == "MATCH" {
			return nil, fmt.Errorf("line %d: FINAL/MATCH belongs to default egress, not custom rules", lineNo+1)
		}
		if value == "" || target == "" {
			return nil, fmt.Errorf("line %d: rule value and target are required", lineNo+1)
		}
		if !validKind(kind) {
			return nil, fmt.Errorf("line %d: unsupported rule type %q", lineNo+1, kind)
		}
		if validTarget != nil && !validTarget(target) {
			return nil, fmt.Errorf("line %d: unknown target %q", lineNo+1, target)
		}
		r := Rule{Kind: kind, Value: value, Target: target, Raw: fmt.Sprintf("%s,%s,%s", kind, value, target)}
		if kind == IPCIDR {
			prefix, err := netip.ParsePrefix(value)
			if err != nil {
				return nil, fmt.Errorf("line %d: invalid CIDR %q", lineNo+1, value)
			}
			r.prefix = prefix.Masked()
			r.Value = r.prefix.String()
			r.Raw = fmt.Sprintf("%s,%s,%s", kind, r.Value, target)
		}
		if kind == Domain || kind == DomainSuffix || kind == DomainKeyword {
			r.Value = strings.ToLower(strings.TrimSuffix(value, "."))
			r.Raw = fmt.Sprintf("%s,%s,%s", kind, r.Value, target)
		}
		out = append(out, r)
	}
	return out, nil
}

func validKind(k Kind) bool {
	switch k {
	case Domain, DomainSuffix, DomainKeyword, IPCIDR, RuleSet, GEOIP:
		return true
	}
	return false
}

func (r Rule) Matches(domain string, ip netip.Addr) bool {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	switch r.Kind {
	case Domain:
		return domain == r.Value
	case DomainSuffix:
		return domain == r.Value || strings.HasSuffix(domain, "."+r.Value)
	case DomainKeyword:
		return strings.Contains(domain, r.Value)
	case IPCIDR:
		return ip.IsValid() && r.prefix.Contains(ip)
	}
	return false
}
