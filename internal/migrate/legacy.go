// Package migrate converts the current Bash/Python state into Go config.
package migrate

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Xiuyixx/5GPN-X/internal/apps"
	"github.com/Xiuyixx/5GPN-X/internal/config"
)

type Paths struct {
	ConfDir  string
	ExitsDir string
	Rules    string
}

func LoadLegacy(p Paths) (config.Config, error) {
	cfg := config.Default()
	cfg.Egress = nil
	if err := loadExits(&cfg, p.ExitsDir); err != nil {
		return config.Config{}, err
	}
	if err := loadCurrent(&cfg, filepath.Join(p.ConfDir, "current-exit")); err != nil {
		return config.Config{}, err
	}
	if err := loadRules(&cfg, p.Rules); err != nil {
		return config.Config{}, err
	}
	return cfg, nil
}

func loadExits(cfg *config.Config, dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "DIRECT", Type: "direct"})
			return nil
		}
		return err
	}
	cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: "DIRECT", Type: "direct"})
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".type") {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), ".type")
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return err
		}
		typ := strings.TrimSpace(string(data))
		if name == "local" || name == "smart" || name == "" {
			continue
		}
		cfg.Egress = append(cfg.Egress, config.EgressConfig{Name: name, Type: typ})
	}
	return nil
}

func loadCurrent(cfg *config.Config, path string) error {
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	name := strings.TrimSpace(string(data))
	if name == "" || name == "local" {
		cfg.Final = "DIRECT"
	} else {
		cfg.Final = name
	}
	return nil
}

func loadRules(cfg *config.Config, path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	var pending string
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if strings.HasPrefix(line, "# 5GPN-APP ") {
			pending = strings.TrimSpace(strings.TrimPrefix(line, "# 5GPN-APP "))
			continue
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, ",")
		if len(parts) < 3 {
			return fmt.Errorf("invalid legacy rule %q", line)
		}
		if pending != "" {
			if _, ok := apps.Get(pending); ok {
				cfg.Apps[pending] = normalizeTarget(parts[2])
			}
			pending = ""
		}
		cfg.Rules = append(cfg.Rules, line)
	}
	return s.Err()
}

func normalizeTarget(target string) string {
	if strings.EqualFold(strings.TrimSpace(target), "direct") || strings.EqualFold(strings.TrimSpace(target), "local") {
		return "DIRECT"
	}
	return strings.TrimSpace(target)
}
