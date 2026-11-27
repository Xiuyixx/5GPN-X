// Package runtime connects policy decisions to actual egress dialers.
package runtime

import (
	"context"
	"fmt"
	"net"
	"sync"

	"github.com/Xiuyixx/5GPN-X/internal/egress"
	"github.com/Xiuyixx/5GPN-X/internal/manage"
)

type Runtime struct {
	mu      sync.RWMutex
	manager *manage.Manager
	dialers map[string]egress.Dialer
}

func New(manager *manage.Manager) *Runtime {
	return &Runtime{manager: manager, dialers: map[string]egress.Dialer{}}
}
func (r *Runtime) Register(name string, dialer egress.Dialer) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dialers[name] = dialer
}

func (r *Runtime) Dial(ctx context.Context, appKey, domain, addr string) (net.Conn, error) {
	decision := r.manager.Decision(appKey, domain)
	if decision.Action == "REJECT" || decision.Action == "block" {
		return nil, fmt.Errorf("blocked by %s", decision.Rule)
	}
	target := decision.Action
	if target == "" {
		return nil, fmt.Errorf("empty routing target")
	}
	r.mu.RLock()
	dialer, ok := r.dialers[target]
	r.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("no dialer registered for %s", target)
	}
	return dialer.DialContext(ctx, addr)
}
