package dns

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"sync"
)

type Server struct {
	cfg Config
	tcp net.Listener
	dot net.Listener
	mu  sync.Mutex
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
	return nil
}
func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first error
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
	<-ctx.Done()
	return ctx.Err()
}
func loadTLSCertificate(cfg Config) (tls.Certificate, error) {
	return tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
}
