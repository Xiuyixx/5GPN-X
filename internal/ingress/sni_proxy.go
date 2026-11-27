package ingress

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

// TLSProxy forwards opaque TLS streams after extracting SNI from ClientHello.
type TLSProxy struct {
	Listen      string
	DefaultPort int
	PeekTimeout time.Duration
	ln          net.Listener
}

func NewTLSProxy(listen string) (*TLSProxy, error) {
	if listen == "" {
		return nil, fmt.Errorf("listen address is required")
	}
	return &TLSProxy{Listen: listen, DefaultPort: 443, PeekTimeout: 3 * time.Second}, nil
}
func (p *TLSProxy) Serve(ctx context.Context) error {
	ln, err := net.Listen("tcp", p.Listen)
	if err != nil {
		return err
	}
	p.ln = ln
	defer p.Close()
	for {
		c, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
				return err
			}
		}
		go p.handle(c)
	}
}
func (p *TLSProxy) Close() error {
	if p.ln != nil {
		return p.ln.Close()
	}
	return nil
}
func (p *TLSProxy) handle(client net.Conn) {
	defer client.Close()
	_ = client.SetReadDeadline(time.Now().Add(p.PeekTimeout))
	br := bufio.NewReader(client)
	hello, err := br.Peek(5)
	if err != nil {
		return
	}
	if hello[0] != 0x16 || hello[1] != 3 {
		return
	}
	length := int(binary.BigEndian.Uint16(hello[3:5]))
	if length < 4 || length > 65536 {
		return
	}
	data, err := br.Peek(5 + length)
	if err != nil {
		return
	}
	_ = client.SetReadDeadline(time.Time{})
	host, ok := ClientHelloSNI(data)
	if !ok {
		return
	}
	backend, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(p.DefaultPort)), 8*time.Second)
	if err != nil {
		return
	}
	defer backend.Close()
	go func() { _, _ = io.Copy(backend, br) }()
	_, _ = io.Copy(client, backend)
}

func ClientHelloSNI(record []byte) (string, bool) {
	if len(record) < 9 || record[0] != 0x16 || record[5] != 1 {
		return "", false
	}
	hsLen := int(record[6])<<16 | int(record[7])<<8 | int(record[8])
	if hsLen+9 > len(record) || hsLen < 34 {
		return "", false
	}
	h := record[9 : 9+hsLen]
	off := 34
	if off >= len(h) {
		return "", false
	}
	sid := int(h[off])
	off++
	if off+sid+2 > len(h) {
		return "", false
	}
	off += sid
	cs := int(binary.BigEndian.Uint16(h[off:]))
	off += 2
	if off+cs+1 > len(h) {
		return "", false
	}
	off += cs
	cm := int(h[off])
	off++
	if off+cm+2 > len(h) {
		return "", false
	}
	off += cm
	exts := int(binary.BigEndian.Uint16(h[off:]))
	off += 2
	if off+exts > len(h) {
		return "", false
	}
	for end := off + exts; off+4 <= end; {
		typ := binary.BigEndian.Uint16(h[off:])
		n := int(binary.BigEndian.Uint16(h[off+2:]))
		off += 4
		if off+n > end {
			return "", false
		}
		if typ == 0 && n >= 5 {
			list := h[off+2 : off+n]
			if list[0] == 0 {
				l := int(binary.BigEndian.Uint16(list[1:]))
				if l > 0 && 3+l <= len(list) {
					return strings.TrimSpace(string(list[3 : 3+l])), true
				}
			}
		}
		off += n
	}
	return "", false
}
