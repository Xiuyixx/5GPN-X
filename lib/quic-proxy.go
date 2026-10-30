// quic-proxy.go - Lightweight QUIC SNI transparent proxy
// Listens on UDP :443, extracts SNI from QUIC v1/draft-29 Initial packets,
// then forwards UDP datagrams to the backend server.
//
// Pure Go standard library only (no external deps).
// Build: go build -o quic-proxy quic-proxy.go
// Run:   ./quic-proxy -l :443

package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	quicVersion1       = 0x00000001
	quicVersionDraft29 = 0xff00001d
	longHeaderForm     = 0x80
	initialPacketType  = 0x00 // bits 4-5 of first byte = 00
	initialSaltV1      = "\x38\x76\x2c\xf7\xf5\x59\x34\xb3\x4d\x17\x9a\xe6\xa4\xc8\x0c\xad\xcc\xbb\x7f\x0a"
	initialSaltDraft29 = "\xaf\xbf\xec\x28\x99\x93\xd2\x4c\x9e\x97\x86\xf1\x9c\x61\x11\xe0\x43\x90\xa8\x99"
	tagSize            = 16
)

func initialSaltForVersion(version uint32) ([]byte, bool) {
	switch version {
	case quicVersion1:
		return []byte(initialSaltV1), true
	case quicVersionDraft29:
		return []byte(initialSaltDraft29), true
	default:
		return nil, false
	}
}

var (
	listenAddr  = flag.String("l", ":443", "Listen address (UDP)")
	idleTimeout = flag.Duration("idle-timeout", 300*time.Second, "UDP session idle timeout")
	dnsFile     = flag.String("dns-file", "/var/lib/5gpn-quic/remote-dns", "Overseas DNS configuration (plain IP or udp://IP:port only)")
	debug       = flag.Bool("debug", false, "Enable debug logging")
)

type Session struct {
	clientAddr   *net.UDPAddr
	backendConn  *net.UDPConn
	lastActivity time.Time
	mu           sync.Mutex
}

type SessionManager struct {
	sessions map[string]*Session
	mu       sync.RWMutex
	listener *net.UDPConn
}

func main() {
	flag.Parse()
	if *debug {
		log.SetFlags(log.LstdFlags | log.Lshortfile)
	}

	addr, err := net.ResolveUDPAddr("udp", *listenAddr)
	if err != nil {
		log.Fatalf("ResolveUDPAddr error: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("ListenUDP error: %v", err)
	}
	defer conn.Close()

	log.Printf("QUIC SNI Proxy listening on UDP %s", *listenAddr)

	mgr := &SessionManager{
		sessions: make(map[string]*Session),
		listener: conn,
	}
	go mgr.gcLoop()

	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if !os.IsTimeout(err) {
				log.Printf("ReadFromUDP error: %v", err)
			}
			continue
		}
		// Hot path: forward to an existing session inline (no goroutine, no
		// per-packet allocation, preserves datagram order). Only the one-off
		// session setup (SNI parse + DNS + dial) is offloaded to a goroutine.
		key := clientAddr.String()
		mgr.mu.RLock()
		sess, exists := mgr.sessions[key]
		mgr.mu.RUnlock()
		if exists {
			sess.mu.Lock()
			sess.lastActivity = time.Now()
			bc := sess.backendConn
			sess.mu.Unlock()
			if bc != nil {
				if _, err := bc.Write(buf[:n]); err != nil {
					log.Printf("[%s] Write to backend error: %v", key, err)
				}
			}
			continue
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		go mgr.handleNewSession(data, clientAddr)
	}
}

func (m *SessionManager) handleNewSession(data []byte, clientAddr *net.UDPAddr) {
	key := clientAddr.String()

	sni, ok := extractSNI(data)
	if !ok || sni == "" {
		if *debug {
			log.Printf("[%s] Not a QUIC Initial, drop", key)
		}
		return
	}

	// Resolve SNI
	ips, err := lookupBackendIPv4(sni, *dnsFile)
	if err != nil || len(ips) == 0 {
		log.Printf("[%s] DNS lookup failed for '%s': %v", key, sni, err)
		return
	}
	backendIP, ok := selectBackendIPv4(ips)
	if !ok {
		log.Printf("[%s] DNS lookup for '%s' returned no IPv4 address", key, sni)
		return
	}

	backendAddr := &net.UDPAddr{IP: backendIP, Port: 443}
	bc, err := net.DialUDP("udp", nil, backendAddr)
	if err != nil {
		log.Printf("[%s] DialUDP to %s error: %v", key, backendAddr, err)
		return
	}

	sess := &Session{
		clientAddr:   clientAddr,
		backendConn:  bc,
		lastActivity: time.Now(),
	}
	// Two packets from the same new client can race here; keep the first
	// session and feed this datagram into it instead of leaking a backend conn.
	m.mu.Lock()
	if existing, ok := m.sessions[key]; ok {
		m.mu.Unlock()
		bc.Close()
		existing.mu.Lock()
		existing.lastActivity = time.Now()
		ebc := existing.backendConn
		existing.mu.Unlock()
		if ebc != nil {
			if _, err := ebc.Write(data); err != nil {
				log.Printf("[%s] Write to backend error: %v", key, err)
			}
		}
		return
	}
	m.sessions[key] = sess
	m.mu.Unlock()

	if _, err := bc.Write(data); err != nil {
		log.Printf("[%s] First packet forward error: %v", key, err)
		m.removeSession(key)
		return
	}

	go m.relayBackendToClient(sess, key)
	if *debug {
		log.Printf("[%s] New session to %s (%s)", key, sni, backendIP)
	}
}

// Never silently fall back to the host resolver or strip an encrypted scheme.
// TCP/SNI and wa-shim currently require plain UDP DNS too; configuration
// validation rejects unsupported remote transports before changing live files.
func lookupBackendIPv4(host, path string) ([]net.IP, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	servers := strings.Fields(strings.ReplaceAll(string(data), ",", " "))
	if len(servers) == 0 {
		return nil, fmt.Errorf("empty overseas DNS list")
	}
	addresses := make([]string, 0, len(servers))
	for _, server := range servers {
		server = strings.TrimPrefix(server, "udp://")
		if strings.Contains(server, "://") {
			return nil, fmt.Errorf("unsupported remote DNS transport")
		}
		var ip net.IP
		var port = "53"
		if strings.HasPrefix(server, "[") {
			end := strings.Index(server, "]:")
			if end < 0 {
				return nil, fmt.Errorf("invalid remote DNS endpoint: %s", server)
			}
			ip = net.ParseIP(server[1:end])
			port = server[end+2:]
		} else if parsed := net.ParseIP(server); parsed != nil {
			ip = parsed
		} else {
			colon := strings.LastIndex(server, ":")
			if colon <= 0 {
				return nil, fmt.Errorf("remote DNS endpoint must use an IP address: %s", server)
			}
			ip = net.ParseIP(server[:colon])
			port = server[colon+1:]
		}
		if ip == nil || port == "" {
			return nil, fmt.Errorf("invalid remote DNS endpoint: %s", server)
		}
		portNum, scanErr := strconv.Atoi(port)
		if scanErr != nil || portNum < 1 || portNum > 65535 {
			return nil, fmt.Errorf("invalid remote DNS port: %s", port)
		}
		addresses = append(addresses, net.JoinHostPort(ip.String(), port))
	}
	var last error
	for _, address := range addresses {
		resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, ignored string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "udp", address)
		}}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		ips, err := resolver.LookupIP(ctx, "ip4", host)
		cancel()
		if err == nil && len(ips) > 0 {
			return ips, nil
		}
		last = err
	}
	return nil, fmt.Errorf("configured overseas DNS lookup failed: %v", last)
}

func selectBackendIPv4(ips []net.IP) (net.IP, bool) {
	for _, ip := range ips {
		if ip4 := ip.To4(); ip4 != nil {
			return ip4, true
		}
	}
	return nil, false
}

func (m *SessionManager) relayBackendToClient(sess *Session, key string) {
	buf := make([]byte, 65535)
	for {
		n, err := sess.backendConn.Read(buf)
		if err != nil {
			if *debug {
				log.Printf("[%s] Backend read error: %v", key, err)
			}
			m.removeSession(key)
			return
		}
		sess.mu.Lock()
		sess.lastActivity = time.Now()
		sess.mu.Unlock()
		if _, err := m.listener.WriteToUDP(buf[:n], sess.clientAddr); err != nil {
			log.Printf("[%s] WriteToUDP error: %v", key, err)
			m.removeSession(key)
			return
		}
	}
}

func (m *SessionManager) removeSession(key string) {
	m.mu.Lock()
	sess, ok := m.sessions[key]
	if ok {
		delete(m.sessions, key)
	}
	m.mu.Unlock()
	if ok && sess.backendConn != nil {
		sess.backendConn.Close()
	}
}

func (m *SessionManager) gcLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		var keys []string
		m.mu.RLock()
		for k, s := range m.sessions {
			s.mu.Lock()
			idle := now.Sub(s.lastActivity)
			s.mu.Unlock()
			if idle > *idleTimeout {
				keys = append(keys, k)
			}
		}
		m.mu.RUnlock()
		for _, k := range keys {
			m.removeSession(k)
			if *debug {
				log.Printf("[%s] GC idle session", k)
			}
		}
	}
}

// extractSNI decrypts a supported QUIC Initial packet and returns the SNI hostname.
func extractSNI(data []byte) (string, bool) {
	if len(data) < 5 {
		return "", false
	}
	if data[0]&0x80 == 0 {
		return "", false // short header
	}
	version := binary.BigEndian.Uint32(data[1:5])
	initialSalt, ok := initialSaltForVersion(version)
	if !ok {
		return "", false
	}
	pktType := (data[0] & 0x30) >> 4
	if pktType != initialPacketType {
		return "", false
	}

	off := 5
	if len(data) < off+1 {
		return "", false
	}
	dcidLen := int(data[off])
	off++
	if len(data) < off+dcidLen {
		return "", false
	}
	dcid := data[off : off+dcidLen]
	off += dcidLen

	if len(data) < off+1 {
		return "", false
	}
	scidLen := int(data[off])
	off++
	if len(data) < off+scidLen {
		return "", false
	}
	off += scidLen

	tokenLen, n := readVarint(data[off:])
	if n == 0 || len(data) < off+n+int(tokenLen) {
		return "", false
	}
	off += n + int(tokenLen)

	length, n := readVarint(data[off:])
	if n == 0 || uint64(len(data)-off) < length {
		return "", false
	}
	off += n
	if off+int(length) > len(data) {
		return "", false
	}
	protected := data[off : off+int(length)]

	// Derive keys
	initialSecret := hkdfExtract(initialSalt, dcid)
	clientInitialSecret := hkdfExpandLabel(initialSecret, "client in", nil, 32)
	key := hkdfExpandLabel(clientInitialSecret, "quic key", nil, 16)
	iv := hkdfExpandLabel(clientInitialSecret, "quic iv", nil, 12)
	hp := hkdfExpandLabel(clientInitialSecret, "quic hp", nil, 16)

	// Header protection (AES-128-ECB)
	hpCipher, err := aes.NewCipher(hp)
	if err != nil {
		return "", false
	}
	if len(protected) < 5 {
		return "", false
	}
	sampleOffset := 4
	if len(protected) < sampleOffset+16 {
		sampleOffset = 0
	}
	if sampleOffset+16 > len(protected) {
		return "", false
	}
	sample := protected[sampleOffset : sampleOffset+16]
	mask := make([]byte, 16)
	hpCipher.Encrypt(mask, sample)

	// Long-header protection masks only the low four bits; bit 4-5 are the
	// packet type and remain visible for Initial packet classification.
	firstByte := data[0] ^ (mask[0] & 0x0f)
	pnLen := int(firstByte&0x03) + 1
	if len(protected) < pnLen {
		return "", false
	}
	packetNumber := make([]byte, pnLen)
	for i := 0; i < pnLen; i++ {
		packetNumber[i] = protected[i] ^ mask[1+i]
	}
	pn := 0
	for i := 0; i < pnLen; i++ {
		pn = (pn << 8) | int(packetNumber[i])
	}

	// Nonce = iv XOR packet_number (left-padded)
	nonce := make([]byte, 12)
	copy(nonce, iv)
	for i := 0; i < pnLen; i++ {
		nonce[11-i] ^= packetNumber[pnLen-1-i]
	}

	// AEAD decrypt
	aesBlock, err := aes.NewCipher(key)
	if err != nil {
		return "", false
	}
	aead, err := cipher.NewGCM(aesBlock)
	if err != nil {
		return "", false
	}

	aad := make([]byte, off+pnLen)
	copy(aad, data[:off+pnLen])
	aad[0] = firstByte
	copy(aad[off:], packetNumber)

	ciphertext := protected[pnLen:]
	if len(ciphertext) < tagSize {
		return "", false
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return "", false
	}

	return parseCryptoFrames(plaintext)
}

func readVarint(buf []byte) (uint64, int) {
	if len(buf) == 0 {
		return 0, 0
	}
	first := buf[0]
	prefix := first >> 6
	length := 1 << prefix
	if len(buf) < length {
		return 0, 0
	}
	var val uint64
	switch length {
	case 1:
		val = uint64(first & 0x3f)
	case 2:
		val = uint64(first&0x3f)<<8 | uint64(buf[1])
	case 4:
		val = uint64(first&0x3f)<<24 | uint64(buf[1])<<16 | uint64(buf[2])<<8 | uint64(buf[3])
	case 8:
		val = binary.BigEndian.Uint64(buf)
		val &= 0x3fffffffffffffff
	}
	return val, length
}

// HKDF-Extract with SHA-256 (RFC 5869)
func hkdfExtract(salt, ikm []byte) []byte {
	mac := hmac.New(sha256.New, salt)
	mac.Write(ikm)
	return mac.Sum(nil)
}

// HKDF-Expand (RFC 5869)
func hkdfExpand(prk []byte, info []byte, length int) []byte {
	var okm []byte
	var prev []byte
	n := (length + sha256.Size - 1) / sha256.Size
	for i := 1; i <= n; i++ {
		mac := hmac.New(sha256.New, prk)
		mac.Write(prev)
		mac.Write(info)
		mac.Write([]byte{byte(i)})
		prev = mac.Sum(nil)
		okm = append(okm, prev...)
	}
	return okm[:length]
}

// HKDF-Expand-Label (RFC 8446)
func hkdfExpandLabel(secret []byte, label string, context []byte, length int) []byte {
	qlabel := "tls13 " + label
	lbl := make([]byte, 0, 2+1+len(qlabel)+1+len(context))
	lbl = append(lbl, byte(length>>8), byte(length))
	lbl = append(lbl, byte(len(qlabel)))
	lbl = append(lbl, qlabel...)
	lbl = append(lbl, byte(len(context)))
	lbl = append(lbl, context...)
	return hkdfExpand(secret, lbl, length)
}

// parseCryptoFrames reassembles bounded, possibly out-of-order CRYPTO frames
// within an Initial packet. PING is payload-free, unlike ACK.
func parseCryptoFrames(plaintext []byte) (string, bool) {
	const maxHello = 65536
	data := make([]byte, maxHello)
	present := make([]bool, maxHello)
	end := 0
	read := func() (uint64, bool) {
		v, n := readVarint(plaintext)
		if n == 0 {
			return 0, false
		}
		plaintext = plaintext[n:]
		return v, true
	}
	for len(plaintext) > 0 {
		kind, ok := read()
		if !ok {
			return "", false
		}
		switch kind {
		case 0, 1: // PADDING, PING
		case 6: // CRYPTO
			offset, ok := read()
			if !ok {
				return "", false
			}
			length, ok := read()
			if !ok || length > uint64(len(plaintext)) || offset > maxHello || length > maxHello-offset {
				return "", false
			}
			for i, value := range plaintext[:int(length)] {
				pos := int(offset) + i
				if present[pos] && data[pos] != value {
					return "", false
				}
				data[pos], present[pos] = value, true
			}
			if last := int(offset + length); last > end {
				end = last
			}
			plaintext = plaintext[int(length):]
		case 2, 3: // ACK, ACK_ECN
			if _, ok := read(); !ok {
				return "", false
			}
			if _, ok := read(); !ok {
				return "", false
			}
			ranges, ok := read()
			if !ok {
				return "", false
			}
			if _, ok := read(); !ok {
				return "", false
			}
			if ranges > uint64(len(plaintext)/2) {
				return "", false
			}
			for i := uint64(0); i < ranges; i++ {
				if _, ok := read(); !ok {
					return "", false
				}
				if _, ok := read(); !ok {
					return "", false
				}
			}
			if kind == 3 {
				for i := 0; i < 3; i++ {
					if _, ok := read(); !ok {
						return "", false
					}
				}
			}
		default:
			return "", false // Unknown/invalid Initial frames are not guessed.
		}
	}
	if end < 4 || data[0] != 1 {
		return "", false
	}
	size := 4 + (int(data[1]) << 16) + (int(data[2]) << 8) + int(data[3])
	if size > end || size > maxHello {
		return "", false
	}
	for _, exists := range present[:size] {
		if !exists {
			return "", false
		}
	}
	return extractSNIFromClientHello(data[:size])
}

// extractSNIFromClientHello parses a TLS ClientHello from either a TLS record
// or QUIC CRYPTO frame handshake bytes.
func extractSNIFromClientHello(data []byte) (string, bool) {
	if len(data) < 5 {
		return "", false
	}
	var hs []byte
	if data[0] == 0x16 {
		recordLen := binary.BigEndian.Uint16(data[3:5])
		if len(data) < 5+int(recordLen) {
			return "", false
		}
		hs = data[5 : 5+int(recordLen)]
	} else if data[0] == 0x01 {
		hs = data
	} else {
		return "", false
	}
	if len(hs) < 4 || hs[0] != 0x01 {
		return "", false
	}
	hello := hs[4:]
	if len(hello) < 34 {
		return "", false
	}
	off := 34
	if len(hello) < off+1 {
		return "", false
	}
	sessionIDLen := int(hello[off])
	off++
	if len(hello) < off+sessionIDLen+2 {
		return "", false
	}
	off += sessionIDLen
	csLen := binary.BigEndian.Uint16(hello[off : off+2])
	off += 2
	if len(hello) < off+int(csLen)+1 {
		return "", false
	}
	off += int(csLen)
	cmLen := int(hello[off])
	off++
	if len(hello) < off+cmLen+2 {
		return "", false
	}
	off += cmLen
	extLen := binary.BigEndian.Uint16(hello[off : off+2])
	off += 2
	if len(hello) < off+int(extLen) {
		return "", false
	}
	extensions := hello[off : off+int(extLen)]
	eo := 0
	for eo+4 <= len(extensions) {
		extType := binary.BigEndian.Uint16(extensions[eo : eo+2])
		extDataLen := binary.BigEndian.Uint16(extensions[eo+2 : eo+4])
		if eo+4+int(extDataLen) > len(extensions) {
			return "", false
		}
		extData := extensions[eo+4 : eo+4+int(extDataLen)]
		if extType == 0x0000 {
			if len(extData) < 2 {
				return "", false
			}
			sniListLen := binary.BigEndian.Uint16(extData[0:2])
			if int(sniListLen) > len(extData)-2 {
				return "", false
			}
			sniData := extData[2 : 2+sniListLen]
			if len(sniData) < 3 {
				return "", false
			}
			if sniData[0] != 0x00 {
				return "", false
			}
			sniLen := binary.BigEndian.Uint16(sniData[1:3])
			if int(sniLen) > len(sniData)-3 {
				return "", false
			}
			return string(sniData[3 : 3+sniLen]), true
		}
		eo += 4 + int(extDataLen)
	}
	return "", false
}
