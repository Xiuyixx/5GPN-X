// Package egress manages the desired default and application egress state.
// It deliberately does not start services yet; runtime reconciliation is a later phase.
package egress

import (
	"fmt"
	"sync"

	"github.com/Xiuyixx/5GPN-X/internal/apps"
	"github.com/Xiuyixx/5GPN-X/internal/config"
)

const Direct = "DIRECT"

// Manager owns an in-memory configuration and persists each accepted mutation.
type Manager struct {
	mu   sync.RWMutex
	cfg  config.Config
	path string
}

func NewManager(cfg config.Config, path string) *Manager {
	if cfg.Apps == nil {
		cfg.Apps = map[string]string{}
	}
	if cfg.Final == "" {
		cfg.Final = Direct
	}
	return &Manager{cfg: cfg, path: path}
}

func (m *Manager) Snapshot() config.Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneConfig(m.cfg)
}

func (m *Manager) SetDefault(name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	name = apps.NormalizeTarget(name)
	if err := validateEgress(m.cfg, name); err != nil {
		return err
	}
	m.cfg.Final = name
	return m.saveLocked()
}

func (m *Manager) SetApp(key, target string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := apps.Get(key); !ok {
		return fmt.Errorf("unknown application %q", key)
	}
	target = apps.NormalizeTarget(target)
	if err := validateEgress(m.cfg, target); err != nil {
		return err
	}
	if target == "" {
		delete(m.cfg.Apps, key)
	} else {
		m.cfg.Apps[key] = target
	}
	return m.saveLocked()
}

func validateEgress(cfg config.Config, name string) error {
	if name == "" || name == Direct {
		return nil
	}
	for _, e := range cfg.Egress {
		if e.Name == name {
			return nil
		}
	}
	return fmt.Errorf("unknown egress %q", name)
}

func (m *Manager) saveLocked() error {
	if m.path == "" {
		return nil
	}
	return m.cfg.Save(m.path)
}

func cloneConfig(in config.Config) config.Config {
	out := in
	out.Egress = append([]config.EgressConfig(nil), in.Egress...)
	out.Rules = append([]string(nil), in.Rules...)
	out.Apps = make(map[string]string, len(in.Apps))
	for k, v := range in.Apps {
		out.Apps[k] = v
	}
	out.AppsChanged = make(map[string]int64, len(in.AppsChanged))
	for k, v := range in.AppsChanged {
		out.AppsChanged[k] = v
	}
	return out
}
