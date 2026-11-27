// Package ingress contains native Go TCP transparent relay primitives.
package ingress

import (
	"context"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

type TCPProxy struct {
	Listen      string
	Backend     string
	PeekTimeout time.Duration
	ln          net.Listener
	mu          sync.Mutex
}

func NewTCPProxy(listen, backend string) (*TCPProxy, error) {
	if listen == "" || backend == "" {
		return nil, fmt.Errorf("listen and backend are required")
	}
	return &TCPProxy{Listen: listen, Backend: backend, PeekTimeout: 3 * time.Second}, nil
}

func (p *TCPProxy) Serve(ctx context.Context) error {
	ln, err := net.Listen("tcp", p.Listen)
	if err != nil {
		return err
	}
	p.mu.Lock()
	p.ln = ln
	p.mu.Unlock()
	defer p.Close()
	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
				return err
			}
		}
		go p.handle(conn)
	}
}
func (p *TCPProxy) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ln == nil {
		return nil
	}
	err := p.ln.Close()
	p.ln = nil
	return err
}

func (p *TCPProxy) handle(client net.Conn) {
	defer client.Close()
	_ = client.SetReadDeadline(time.Now().Add(p.PeekTimeout))
	first := make([]byte, 8)
	n, err := io.ReadAtLeast(client, first, 1)
	if err != nil && n == 0 {
		return
	}
	_ = client.SetReadDeadline(time.Time{})
	backend, err := net.DialTimeout("tcp", p.Backend, 8*time.Second)
	if err != nil {
		return
	}
	defer backend.Close()
	if _, err := backend.Write(first[:n]); err != nil {
		return
	}
	join(client, backend)
}

func join(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(b, a); _ = closeWrite(b); done <- struct{}{} }()
	go func() { _, _ = io.Copy(a, b); _ = closeWrite(a); done <- struct{}{} }()
	<-done
}
func closeWrite(c net.Conn) error {
	if tcp, ok := c.(*net.TCPConn); ok {
		return tcp.CloseWrite()
	}
	return nil
}
