package quic

import (
	"context"
	"fmt"
	"os/exec"
	"sync"
)

type Process struct {
	cfg    Config
	binary string
	mu     sync.Mutex
	cmd    *exec.Cmd
}

func NewProcess(binary string, cfg Config) (*Process, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if binary == "" {
		return nil, fmt.Errorf("QUIC binary is required")
	}
	return &Process{binary: binary, cfg: cfg}, nil
}
func (p *Process) Start(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd != nil && p.cmd.Process != nil {
		return fmt.Errorf("QUIC process already running")
	}
	p.cmd = exec.CommandContext(ctx, p.binary, "-l", p.cfg.Listen, "-dns-file", p.cfg.DNSFile)
	if err := p.cmd.Start(); err != nil {
		p.cmd = nil
		return err
	}
	return nil
}
func (p *Process) Wait() error {
	p.mu.Lock()
	cmd := p.cmd
	p.mu.Unlock()
	if cmd == nil {
		return fmt.Errorf("QUIC process not started")
	}
	err := cmd.Wait()
	p.mu.Lock()
	p.cmd = nil
	p.mu.Unlock()
	return err
}
func (p *Process) Stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd == nil || p.cmd.Process == nil {
		return nil
	}
	err := p.cmd.Process.Kill()
	p.cmd = nil
	return err
}
