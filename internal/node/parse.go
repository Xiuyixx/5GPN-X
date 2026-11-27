// Package node parses supported proxy share URIs into durable egress metadata.
package node

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"strings"

	"github.com/Xiuyixx/5GPN-X/internal/config"
)

func ParseURI(raw string) (config.EgressConfig, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" {
		return config.EgressConfig{}, fmt.Errorf("invalid proxy URI")
	}
	name := u.Fragment
	if name == "" {
		name = u.Hostname()
	}
	if name == "" {
		name = u.Scheme
	}
	cfg := config.EgressConfig{Name: name, Type: strings.ToLower(u.Scheme), Server: u.Host, URI: raw, DisplayName: u.Fragment}
	switch strings.ToLower(u.Scheme) {
	case "ss":
		return parseSS(cfg, u)
	case "socks5", "http", "https", "vmess", "trojan", "vless", "hysteria2", "tuic", "anytls":
		return cfg, nil
	default:
		return config.EgressConfig{}, fmt.Errorf("unsupported proxy scheme %q", u.Scheme)
	}
}

func parseSS(cfg config.EgressConfig, u *url.URL) (config.EgressConfig, error) {
	payload := strings.TrimPrefix(u.Opaque, "//")
	if payload == "" {
		payload = strings.TrimPrefix(u.Host, "//")
	}
	if strings.Contains(payload, "@") {
		return cfg, nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		decoded, err = base64.StdEncoding.DecodeString(payload)
	}
	if err != nil || !strings.Contains(string(decoded), "@") {
		return config.EgressConfig{}, fmt.Errorf("invalid shadowsocks URI")
	}
	return cfg, nil
}
