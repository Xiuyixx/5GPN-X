package service

import (
	"context"
	"fmt"
	"os/exec"
	"sync"
)

// ExternalProcess is the temporary migration bridge for protocol binaries that
// are not yet native Go implementations. It keeps lifecycle ownership in Go.
type ExternalProcess struct {
	mu     sync.Mutex
	binary string
	args   []string
	cmd    *exec.Cmd
}

func NewExternalProcess(binary string, args ...string) (*ExternalProcess, error) {
	if binary == "" {
		return nil, fmt.Errorf("binary is required")
	}
	return &ExternalProcess{binary: binary, args: args}, nil
}
func (p *ExternalProcess) Start(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd != nil {
		return fmt.Errorf("process already running")
	}
	p.cmd = exec.CommandContext(ctx, p.binary, p.args...)
	if err := p.cmd.Start(); err != nil {
		p.cmd = nil
		return err
	}
	return nil
}
func (p *ExternalProcess) Wait() error {
	p.mu.Lock()
	cmd := p.cmd
	p.mu.Unlock()
	if cmd == nil {
		return fmt.Errorf("process not started")
	}
	err := cmd.Wait()
	p.mu.Lock()
	p.cmd = nil
	p.mu.Unlock()
	return err
}
func (p *ExternalProcess) Stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd == nil || p.cmd.Process == nil {
		return nil
	}
	err := p.cmd.Process.Kill()
	p.cmd = nil
	return err
}
