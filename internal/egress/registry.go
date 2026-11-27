package egress

import (
	"fmt"
	"sync"

	"github.com/Xiuyixx/5GPN-X/internal/config"
)

// Registry owns runtime dialers for all configured egresses.
type Registry struct {
	mu      sync.RWMutex
	dialers map[string]Dialer
}

func NewRegistry() *Registry { return &Registry{dialers: map[string]Dialer{}} }
func (r *Registry) Register(name string, dialer Dialer) error {
	if name == "" || dialer == nil {
		return fmt.Errorf("egress name and dialer are required")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.dialers[name]; exists {
		return fmt.Errorf("egress %q already registered", name)
	}
	r.dialers[name] = dialer
	return nil
}
func (r *Registry) Replace(name string, dialer Dialer) error {
	if name == "" || dialer == nil {
		return fmt.Errorf("egress name and dialer are required")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dialers[name] = dialer
	return nil
}
func (r *Registry) Remove(name string) { r.mu.Lock(); defer r.mu.Unlock(); delete(r.dialers, name) }
func (r *Registry) Get(name string) (Dialer, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	d, ok := r.dialers[name]
	return d, ok
}
func (r *Registry) Sync(cfg config.Config) error {
	for _, e := range cfg.Egress {
		if _, ok := r.Get(e.Name); !ok {
			return fmt.Errorf("egress %q has no runtime dialer", e.Name)
		}
	}
	return nil
}
