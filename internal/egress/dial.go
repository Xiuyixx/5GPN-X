package egress

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

const DialTimeout = 4 * time.Second

type Dialer interface {
	DialContext(context.Context, string) (net.Conn, error)
}

type DirectDialer struct{ dialer *net.Dialer }

func NewDirectDialer() *DirectDialer {
	return &DirectDialer{dialer: &net.Dialer{Timeout: DialTimeout, KeepAlive: 30 * time.Second}}
}
func (d *DirectDialer) DialContext(ctx context.Context, addr string) (net.Conn, error) {
	return d.dialer.DialContext(ctx, "tcp", addr)
}

type SOCKS5Dialer struct {
	upstream string
	dialer   *net.Dialer
}

func NewSOCKS5Dialer(upstream string) *SOCKS5Dialer {
	return &SOCKS5Dialer{upstream: upstream, dialer: &net.Dialer{Timeout: DialTimeout}}
}
func (s *SOCKS5Dialer) DialContext(ctx context.Context, target string) (net.Conn, error) {
	conn, err := s.dialer.DialContext(ctx, "tcp", s.upstream)
	if err != nil {
		return nil, fmt.Errorf("connect SOCKS5 upstream: %w", err)
	}
	if err := socks5Connect(conn, target); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

func socks5Connect(conn net.Conn, target string) error {
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		return err
	}
	var hello [2]byte
	if _, err := io.ReadFull(conn, hello[:]); err != nil {
		return err
	}
	if hello[0] != 5 || hello[1] != 0 {
		return fmt.Errorf("SOCKS5 authentication rejected")
	}
	host, portText, err := net.SplitHostPort(target)
	if err != nil {
		return fmt.Errorf("invalid target %q: %w", target, err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("invalid target port")
	}
	request := []byte{5, 1, 0}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			request = append(request, 1)
			request = append(request, v4...)
		} else {
			request = append(request, 4)
			request = append(request, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return fmt.Errorf("target hostname too long")
		}
		request = append(request, 3, byte(len(host)))
		request = append(request, host...)
	}
	var portBuf [2]byte
	binary.BigEndian.PutUint16(portBuf[:], uint16(port))
	request = append(request, portBuf[:]...)
	if _, err := conn.Write(request); err != nil {
		return err
	}
	var reply [4]byte
	if _, err := io.ReadFull(conn, reply[:]); err != nil {
		return err
	}
	if reply[0] != 5 || reply[1] != 0 {
		return fmt.Errorf("SOCKS5 connect failed: code %d", reply[1])
	}
	var n int
	switch reply[3] {
	case 1:
		n = 4
	case 4:
		n = 16
	case 3:
		var l [1]byte
		if _, err := io.ReadFull(conn, l[:]); err != nil {
			return err
		}
		n = int(l[0])
	default:
		return fmt.Errorf("SOCKS5 invalid address type")
	}
	buf := make([]byte, n+2)
	_, err = io.ReadFull(conn, buf)
	return err
}

func validTarget(target string) bool { return strings.Contains(target, ":") }
