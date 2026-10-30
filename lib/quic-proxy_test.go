package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSelectBackendIPv4RejectsIPv6OnlyResults(t *testing.T) {
	backendIP, ok := selectBackendIPv4([]net.IP{
		net.ParseIP("2001:db8::443"),
		net.ParseIP("2606:4700:4700::1111"),
	})
	if ok {
		t.Fatalf("selectBackendIPv4 returned %s, want no IPv4 backend", backendIP)
	}
}

func TestSelectBackendIPv4ChoosesFirstIPv4Result(t *testing.T) {
	backendIP, ok := selectBackendIPv4([]net.IP{
		net.ParseIP("2001:db8::443"),
		net.ParseIP("203.0.113.10"),
		net.ParseIP("198.51.100.8"),
	})
	if !ok {
		t.Fatalf("selectBackendIPv4 returned ok=false")
	}
	if got, want := backendIP.String(), "203.0.113.10"; got != want {
		t.Fatalf("selectBackendIPv4 returned %s, want %s", got, want)
	}
}

func TestExtractSNIDoesNotMutateInitialPacket(t *testing.T) {
	packetHex := strings.Join([]string{
		"cf00000001080917f0960e7069db082640383fefc89e550041f1f3ee73e46d4b9708ecf630c4e0829991b650053db2713fce0ddae02cdf6ffe8a19a9b150bd70b63218aa13acb656c815276a16ae84b68f7ecdde2eed55e3ba0587edaba42f58e5661603b625ca1caec6d1b637e70cc6958f775bb41ffc4026c4f260a867e0c104fea23ed0fb4d3eb575cd41786a38d60f193d4dbdf7deb402bd1ea338e9f989ece0b1200ae500a5b3e13742cff7d362859fee0d6d7636649f97cec2bda186a4794d1f191cb47e0c9d11d8e6fbd6bfef611dcaff93afeb0c88a7782ee5f7550dc1c7f285033b95d1c36e794f56f9028a691a2994e5d8d27c9972bb41dfea7a8c32300603ef0d5a6e5fa8746d4f8fa1678596b3046c444cb5dc06617065f4298a4e12a4fa7a27dde2209ea6c91e991a9d8bcb350786c04ddb3549b27fe0cefdf2e1eb468144c37bb443a8b26d2024cccedf65c2ec73e1124ed91e9bb8cb3a35b2964b90547886597619b5b8bec4b6d567f1742298fd8542e9e6c0fdb769f5fe9d5284442c8b22a80e182e44f65d6b96e34744bccd1cb538960ee3afaffb2b8cb9205131dd62ff7dccbd1a547baa7ace2a07305cd3be2118fe26a1a889e2a606f27f5ec171488974c0befd79997adfdec0388928834c5011418370ac1e027bd3ecda56c4b00ebb676ca450b8fdf41136e70df75bc84484e9210484ce81390d1f2feb2ed3be5d54127b8bf309",
		"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
	}, "")
	packet, err := hex.DecodeString(packetHex)
	if err != nil {
		t.Fatalf("decode packet: %v", err)
	}
	original := append([]byte(nil), packet...)

	sni, ok := extractSNI(packet)
	if !ok {
		t.Fatalf("extractSNI returned ok=false")
	}
	if sni != "www.google.com" {
		t.Fatalf("extractSNI returned %q, want %q", sni, "www.google.com")
	}
	if !bytes.Equal(packet, original) {
		t.Fatalf("extractSNI mutated the packet")
	}
}

// Synthetic ClientHello: no device identifiers, tickets or captured user traffic.
func testHello() []byte {
	host := []byte("api.example.test")
	sni := []byte{0, byte(len(host) + 3), 0, 0, byte(len(host))}
	sni = append(sni, host...)
	ext := []byte{0, 0, 0, byte(len(sni))}
	ext = append(ext, sni...)
	body := append([]byte{3, 3}, make([]byte, 32)...)
	body = append(body, 0, 0, 2, 0x13, 1, 1, 0, 0, byte(len(ext)))
	body = append(body, ext...)
	return append([]byte{1, 0, 0, byte(len(body))}, body...)
}

func cryptoFrame(offset byte, data []byte) []byte {
	frame := []byte{6, offset, 0x40 | byte(len(data)>>8), byte(len(data))}
	return append(frame, data...)
}

func testInitial(t *testing.T, version uint32, salt string, plaintext []byte) []byte {
	t.Helper()
	dcid := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	secret := hkdfExpandLabel(hkdfExtract([]byte(salt), dcid), "client in", nil, 32)
	key := hkdfExpandLabel(secret, "quic key", nil, 16)
	iv := hkdfExpandLabel(secret, "quic iv", nil, 12)
	hp := hkdfExpandLabel(secret, "quic hp", nil, 16)
	// Pad to a 1200-byte client Initial datagram. One-byte packet number.
	const headerLen = 19
	plain := append([]byte(nil), plaintext...)
	plain = append(plain, make([]byte, 1200-headerLen-16-len(plain))...)
	header := []byte{0xc0, 0, 0, 0, 0, 8}
	binary.BigEndian.PutUint32(header[1:], version)
	header = append(header, dcid...)
	header = append(header, 0, 0) // empty SCID and token
	length := 1 + len(plain) + 16
	header = append(header, 0x40|byte(length>>8), byte(length), 1)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	iv[11] ^= 1
	packet := gcm.Seal(append([]byte(nil), header...), iv, plain, header)
	hpBlock, err := aes.NewCipher(hp)
	if err != nil {
		t.Fatal(err)
	}
	mask := make([]byte, 16)
	hpBlock.Encrypt(mask, packet[22:38]) // pn_offset + 4
	packet[0] ^= mask[0] & 0x0f
	packet[18] ^= mask[1]
	return packet
}

func TestInitialVersionsAndCryptoReassembly(t *testing.T) {
	hello := testHello()
	// Like the observed client: shuffled CRYPTO offsets interspersed with PING.
	frames := []byte{1, 0}
	frames = append(frames, cryptoFrame(30, hello[30:])...)
	frames = append(frames, 1)
	frames = append(frames, cryptoFrame(0, hello[:12])...)
	frames = append(frames, cryptoFrame(12, hello[12:30])...)
	for _, tc := range []struct {
		version uint32
		salt    string
	}{
		{0x00000001, "38762cf7f55934b34d179ae6a4c80cadccbb7f0a"},
		{0xff00001d, "afbfec289993d24c9e9786f19c6111e04390a899"},
	} {
		salt, _ := hex.DecodeString(tc.salt)
		packet := testInitial(t, tc.version, string(salt), frames)
		before := append([]byte(nil), packet...)
		if host, ok := extractSNI(packet); !ok || host != "api.example.test" {
			t.Fatalf("version %x: %q %v", tc.version, host, ok)
		}
		if !bytes.Equal(packet, before) {
			t.Fatal("packet mutated")
		}
		for n := 0; n < len(packet); n++ {
			if _, ok := extractSNI(packet[:n]); ok {
				t.Fatalf("accepted truncated packet %d", n)
			}
		}
		packet[len(packet)-1] ^= 1
		if _, ok := extractSNI(packet); ok {
			t.Fatal("accepted corrupted authentication tag")
		}
		binary.BigEndian.PutUint32(packet[1:5], 0x12345678)
		if _, ok := extractSNI(packet); ok {
			t.Fatal("accepted unknown version")
		}
	}
}

func TestCryptoFrameValidation(t *testing.T) {
	hello := testHello()
	good := cryptoFrame(0, hello)
	cases := map[string][]byte{
		"gap":           cryptoFrame(1, hello[1:]),
		"truncated":     good[:len(good)-1],
		"overflow":      {6, 0x80, 0x01, 0, 0, 1, 0},
		"ack truncated": {2, 0},
		"unknown":       {0x1f},
	}
	conflict := append([]byte(nil), good...)
	conflict = append(conflict, cryptoFrame(0, []byte{2})...)
	cases["overlap conflict"] = conflict
	for name, data := range cases {
		if _, ok := parseCryptoFrames(data); ok {
			t.Errorf("accepted %s", name)
		}
	}
	duplicate := append(append([]byte(nil), good...), good...)
	if _, ok := parseCryptoFrames(duplicate); !ok {
		t.Error("rejected matching retransmission")
	}
	for _, ack := range [][]byte{{2, 0, 0, 0, 0}, {3, 0, 0, 0, 0, 0, 0, 0}} {
		if _, ok := parseCryptoFrames(append(ack, good...)); !ok {
			t.Error("rejected ACK before CRYPTO")
		}
	}
}

func TestConfiguredDNS(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	go func() {
		buf := make([]byte, 1500)
		for {
			n, peer, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			if n < 12 {
				continue
			}
			end := 12
			for end < n && buf[end] != 0 {
				end += int(buf[end]) + 1
			}
			if end+5 > n {
				continue
			}
			end += 5
			response := append([]byte(nil), buf[:end]...)
			response[2], response[3] = 0x81, 0x80
			response[6], response[7] = 0, 1
			response[8], response[9], response[10], response[11] = 0, 0, 0, 0
			response = append(response, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 9)
			_, _ = conn.WriteTo(response, peer)
		}
	}()
	path := filepath.Join(t.TempDir(), "remote_dns")
	dead, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadAddr := dead.LocalAddr().String()
	dead.Close()
	if err := os.WriteFile(path, []byte(deadAddr+" "+conn.LocalAddr().String()), 0600); err != nil {
		t.Fatal(err)
	}
	ips, err := lookupBackendIPv4("routing-test.invalid", path)
	if err != nil || len(ips) != 1 || ips[0].String() != "203.0.113.9" {
		t.Fatalf("ips=%v err=%v", ips, err)
	}
	for _, invalid := range []string{"", "localhost:53", "https://127.0.0.1/dns-query", "tls://1.1.1.1", "127.0.0.1:65536"} {
		if err := os.WriteFile(path, []byte(invalid), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := lookupBackendIPv4("localhost", path); err == nil {
			t.Errorf("accepted unsupported endpoint %q", invalid)
		}
	}
	if _, err := lookupBackendIPv4("localhost", path+".absent"); err == nil {
		t.Fatal("missing file must not use system resolver")
	}
}
