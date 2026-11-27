// Package manage composes configuration, migration, policy, and egress state.
package manage

import (
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/Xiuyixx/5GPN-X/internal/apps"
	"github.com/Xiuyixx/5GPN-X/internal/config"
	"github.com/Xiuyixx/5GPN-X/internal/egress"
	"github.com/Xiuyixx/5GPN-X/internal/migrate"
	"github.com/Xiuyixx/5GPN-X/internal/node"
	"github.com/Xiuyixx/5GPN-X/internal/policy"
)

type Paths struct {
	Config string
	Legacy migrate.Paths
}

type Manager struct {
	mu    sync.RWMutex
	paths Paths
	cfg   config.Config
}

func Open(paths Paths) (*Manager, error) {
	cfg, err := config.Load(paths.Config)
	if err != nil {
		if !isNotExist(err) {
			return nil, err
		}
		cfg, err = migrate.LoadLegacy(paths.Legacy)
		if err != nil {
			return nil, fmt.Errorf("migrate legacy state: %w", err)
		}
		if err := cfg.Save(paths.Config); err != nil {
			return nil, err
		}
	}
	return &Manager{paths: paths, cfg: cfg}, nil
}

func New(cfg config.Config, path string) *Manager {
	return &Manager{paths: Paths{Config: path}, cfg: cfg}
}

func (m *Manager) Snapshot() config.Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return clone(m.cfg)
}

func (m *Manager) Decision(appKey, domain string) policy.Decision {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return policy.New(m.cfg).Match(appKey, domain)
}

func (m *Manager) AddURI(raw string) (config.EgressConfig, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, err := node.ParseURI(raw)
	if err != nil {
		return config.EgressConfig{}, err
	}
	for _, existing := range m.cfg.Egress {
		if existing.Name == e.Name {
			return config.EgressConfig{}, fmt.Errorf("egress %q already exists", e.Name)
		}
	}
	m.cfg.Egress = append(m.cfg.Egress, e)
	if err := m.saveLocked(); err != nil {
		return config.EgressConfig{}, err
	}
	return e, nil
}

func (m *Manager) DeleteEgress(name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if name == "DIRECT" || name == m.cfg.Final {
		return fmt.Errorf("cannot delete active or DIRECT egress")
	}
	found := false
	kept := make([]config.EgressConfig, 0, len(m.cfg.Egress))
	for _, e := range m.cfg.Egress {
		if e.Name == name {
			found = true
			continue
		}
		kept = append(kept, e)
	}
	if !found {
		return fmt.Errorf("unknown egress %q", name)
	}
	m.cfg.Egress = kept
	return m.saveLocked()
}

func (m *Manager) RenameEgress(oldName, newName string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if oldName == "DIRECT" || newName == "DIRECT" || oldName == "" || newName == "" {
		return fmt.Errorf("invalid egress name")
	}
	for _, e := range m.cfg.Egress {
		if e.Name == newName {
			return fmt.Errorf("egress %q already exists", newName)
		}
	}
	found := false
	for i := range m.cfg.Egress {
		if m.cfg.Egress[i].Name == oldName {
			m.cfg.Egress[i].Name = newName
			found = true
		}
	}
	if !found {
		return fmt.Errorf("unknown egress %q", oldName)
	}
	if m.cfg.Final == oldName {
		m.cfg.Final = newName
	}
	for key, target := range m.cfg.Apps {
		if target == oldName {
			m.cfg.Apps[key] = newName
		}
	}
	return m.saveLocked()
}

func (m *Manager) SetDefault(target string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	target = apps.NormalizeTarget(target)
	if err := egress.ValidateTarget(m.cfg, target); err != nil {
		return err
	}
	m.cfg.Final = target
	return m.saveLocked()
}

func (m *Manager) SetApp(appKey, target string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := apps.Get(appKey); !ok {
		return fmt.Errorf("unknown application %q", appKey)
	}
	target = apps.NormalizeTarget(target)
	if err := egress.ValidateTarget(m.cfg, target); err != nil {
		return err
	}
	if target == "" {
		delete(m.cfg.Apps, appKey)
	} else {
		m.cfg.Apps[appKey] = target
	}
	return m.saveLocked()
}

func (m *Manager) saveLocked() error {
	if m.paths.Config == "" {
		return nil
	}
	return m.cfg.Save(m.paths.Config)
}

func clone(in config.Config) config.Config {
	out := in
	out.Egress = append([]config.EgressConfig(nil), in.Egress...)
	out.Rules = append([]string(nil), in.Rules...)
	out.RuleSets = append([]config.RuleSetConfig(nil), in.RuleSets...)
	out.Apps = map[string]string{}
	for k, v := range in.Apps {
		out.Apps[k] = v
	}
	out.AppsChanged = map[string]int64{}
	for k, v := range in.AppsChanged {
		out.AppsChanged[k] = v
	}
	return out
}

func isNotExist(err error) bool { return errors.Is(err, os.ErrNotExist) }
