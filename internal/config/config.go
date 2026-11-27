// Package config defines the durable state used by the Go runtime.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Config is the first migration-safe subset of the runtime configuration.
// Fields intentionally mirror 5gpn-next so later services can share the model.
type Config struct {
	Egress      []EgressConfig    `json:"egress"`
	Rules       []string          `json:"rules"`
	RuleSets    []RuleSetConfig   `json:"rulesets,omitempty"`
	Final       string            `json:"final"`
	Apps        map[string]string `json:"apps,omitempty"`
	AppsChanged map[string]int64  `json:"apps_changed,omitempty"`
}

type RuleSetConfig struct {
	Name     string `json:"name"`
	URL      string `json:"url"`
	Path     string `json:"path,omitempty"`
	Behavior string `json:"behavior,omitempty"`
}

type EgressConfig struct {
	Name        string `json:"name"`
	Type        string `json:"type"`
	Addr        string `json:"addr,omitempty"`
	DisplayName string `json:"display_name,omitempty"`
	Proto       string `json:"proto,omitempty"`
	Server      string `json:"server,omitempty"`
}

func Default() Config {
	return Config{Egress: []EgressConfig{{Name: "DIRECT", Type: "direct"}}, Final: "direct", Apps: map[string]string{}}
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	if cfg.Apps == nil {
		cfg.Apps = map[string]string{}
	}
	return cfg, nil
}

func (c Config) Save(path string) error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("encode config: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".config-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
