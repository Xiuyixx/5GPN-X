// Package dns contains Go DNS/DoT service configuration and lifecycle primitives.
package dns

import (
	"fmt"
	"net"
	"strings"
)

type Config struct {
	DoTListen string
	DNSListen string
	Upstream  []string
	GatewayIP string
	CertFile  string
	KeyFile   string
}

func (c Config) Validate() error {
	if c.DoTListen == "" {
		return fmt.Errorf("DoT listen address is required")
	}
	if c.DNSListen == "" {
		return fmt.Errorf("DNS listen address is required")
	}
	if c.GatewayIP != "" && net.ParseIP(c.GatewayIP) == nil {
		return fmt.Errorf("invalid gateway IP %q", c.GatewayIP)
	}
	if c.CertFile == "" || c.KeyFile == "" {
		return fmt.Errorf("TLS certificate and key are required")
	}
	if len(c.Upstream) == 0 {
		return fmt.Errorf("at least one DNS upstream is required")
	}
	for _, upstream := range c.Upstream {
		host, port, err := net.SplitHostPort(upstream)
		if err != nil || host == "" || port == "" {
			return fmt.Errorf("invalid DNS upstream %q", upstream)
		}
	}
	return nil
}

func NormalizeUpstreams(values []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}
