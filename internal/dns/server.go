package dns

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"sync"

	mdns "github.com/miekg/dns"
)

type Server struct {
	cfg       Config
	tcp       net.Listener
	dot       net.Listener
	tcpServer *mdns.Server
	dotServer *mdns.Server
	mu        sync.Mutex
}

func NewServer(cfg Config) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &Server{cfg: cfg}, nil
}
func (s *Server) Listen() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tcp != nil || s.dot != nil {
		return fmt.Errorf("DNS server already listening")
	}
	tcp, err := net.Listen("tcp", s.cfg.DNSListen)
	if err != nil {
		return err
	}
	cert, err := loadTLSCertificate(s.cfg)
	if err != nil {
		tcp.Close()
		return err
	}
	dot, err := tls.Listen("tcp", s.cfg.DoTListen, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		tcp.Close()
		return err
	}
	s.tcp, s.dot = tcp, dot
	forwarder := NewForwarder(s.cfg.Upstream)
	s.tcpServer = &mdns.Server{Listener: tcp, Handler: forwarder}
	s.dotServer = &mdns.Server{Listener: dot, Handler: forwarder}
	return nil
}
func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first error
	if s.tcpServer != nil {
		if err := s.tcpServer.Shutdown(); err != nil && first == nil {
			first = err
		}
		s.tcpServer = nil
	}
	if s.dotServer != nil {
		if err := s.dotServer.Shutdown(); err != nil && first == nil {
			first = err
		}
		s.dotServer = nil
	}
	if s.tcp != nil {
		if err := s.tcp.Close(); err != nil && first == nil {
			first = err
		}
		s.tcp = nil
	}
	if s.dot != nil {
		if err := s.dot.Close(); err != nil && first == nil {
			first = err
		}
		s.dot = nil
	}
	return first
}
func (s *Server) Serve(ctx context.Context) error {
	if err := s.Listen(); err != nil {
		return err
	}
	defer s.Close()
	errs := make(chan error, 2)
	go func() { errs <- s.tcpServer.ActivateAndServe() }()
	go func() { errs <- s.dotServer.ActivateAndServe() }()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-errs:
		return err
	}
}
func loadTLSCertificate(cfg Config) (tls.Certificate, error) {
	return tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
}
