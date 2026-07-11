package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestRaceQueryReturnsFirstValidResponse(t *testing.T) {
	query := testDNSQuery(0x1234)
	slow := startTestDNSServer(t, 120*time.Millisecond, testDNSResponse(0x1234, 10, 0, 0, 1))
	fast := startTestDNSServer(t, 10*time.Millisecond, testDNSResponse(0x1234, 10, 0, 0, 2))

	start := time.Now()
	resp, err := raceQuery(query, []string{slow, fast}, nil, 50*time.Millisecond, 200*time.Millisecond, time.Second)
	if err != nil {
		t.Fatalf("raceQuery returned error: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 80*time.Millisecond {
		t.Fatalf("raceQuery took %s, want the fast upstream response", elapsed)
	}
	if !bytes.Equal(resp, testDNSResponse(0x1234, 10, 0, 0, 2)) {
		t.Fatalf("raceQuery returned %x, want fast upstream response", resp)
	}
}

func TestRaceQueryUsesPrimaryTCPBeforeFallback(t *testing.T) {
	query := testDNSQuery(0x3456)
	primaryTCP := startTestDNSTCPServer(t, 10*time.Millisecond, testDNSResponse(0x3456, 10, 0, 0, 3))
	fallback := startTestDNSServer(t, 1*time.Millisecond, testDNSResponse(0x3456, 10, 0, 0, 9))

	start := time.Now()
	resp, err := raceQuery(query, []string{primaryTCP}, []string{fallback}, 20*time.Millisecond, 120*time.Millisecond, 300*time.Millisecond)
	if err != nil {
		t.Fatalf("raceQuery returned error: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 20*time.Millisecond || elapsed > 90*time.Millisecond {
		t.Fatalf("raceQuery TCP elapsed=%s, want shortly after TCP fallback delay", elapsed)
	}
	if !bytes.Equal(resp, testDNSResponse(0x3456, 10, 0, 0, 3)) {
		t.Fatalf("raceQuery returned %x, want primary TCP response", resp)
	}
}

func TestRaceQueryUsesFallbackWhenPrimaryUDPAndTCPFail(t *testing.T) {
	query := testDNSQuery(0x5678)
	primary := startBlackholeDNSServer(t)
	fallback := startTestDNSServer(t, 10*time.Millisecond, testDNSResponse(0x5678, 10, 0, 0, 9))

	start := time.Now()
	resp, err := raceQuery(query, []string{primary}, []string{fallback}, 20*time.Millisecond, 80*time.Millisecond, 300*time.Millisecond)
	if err != nil {
		t.Fatalf("raceQuery returned error: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 80*time.Millisecond || elapsed > 160*time.Millisecond {
		t.Fatalf("raceQuery fallback elapsed=%s, want after primary UDP/TCP window", elapsed)
	}
	if !bytes.Equal(resp, testDNSResponse(0x5678, 10, 0, 0, 9)) {
		t.Fatalf("raceQuery returned %x, want fallback response", resp)
	}
}

func TestHandleRaceQueryReturnsServfailWhenAllUpstreamsFail(t *testing.T) {
	query := testDNSQuery(0x9012)
	primary := startBlackholeDNSServer(t)

	proxyConn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("ListenPacket: %v", err)
	}
	t.Cleanup(func() { proxyConn.Close() })

	clientConn, err := net.Dial("udp", proxyConn.LocalAddr().String())
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	t.Cleanup(func() { clientConn.Close() })

	go func() {
		buf := make([]byte, 512)
		n, addr, err := proxyConn.ReadFrom(buf)
		if err != nil {
			return
		}
		handleRaceQuery(proxyConn, addr, append([]byte(nil), buf[:n]...), []string{primary}, nil, time.Millisecond, 10*time.Millisecond, 30*time.Millisecond)
	}()

	if _, err := clientConn.Write(query); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if err := clientConn.SetReadDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}

	buf := make([]byte, 512)
	n, err := clientConn.Read(buf)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	response := buf[:n]
	if !validDNSResponse(query, response) {
		t.Fatalf("response %x is not a valid DNS response for query %x", response, query)
	}
	if rcode := response[3] & 0x0f; rcode != 2 {
		t.Fatalf("rcode=%d, want SERVFAIL", rcode)
	}
}

func TestHandleTCPConnectionReturnsDNSResponses(t *testing.T) {
	firstQuery := testDNSQuery(0x1111)
	secondQuery := testDNSQuery(0x2222)
	primary := startTestDNSServer(t, time.Millisecond, testDNSResponse(0x1111, 10, 0, 0, 11))
	fallback := startTestDNSServer(t, time.Millisecond, testDNSResponse(0x2222, 10, 0, 0, 22))
	client, server := net.Pipe()
	t.Cleanup(func() { client.Close() })

	go handleTCPConnection(server, []string{primary}, []string{fallback}, 20*time.Millisecond, 40*time.Millisecond, 100*time.Millisecond)

	if err := writeTCPDNSMessage(client, firstQuery); err != nil {
		t.Fatalf("write first query: %v", err)
	}
	firstResponse, err := readTCPDNSMessage(client)
	if err != nil {
		t.Fatalf("read first response: %v", err)
	}
	if !bytes.Equal(firstResponse, testDNSResponse(0x1111, 10, 0, 0, 11)) {
		t.Fatalf("first TCP response=%x, want primary response", firstResponse)
	}

	if err := writeTCPDNSMessage(client, secondQuery); err != nil {
		t.Fatalf("write second query: %v", err)
	}
	secondResponse, err := readTCPDNSMessage(client)
	if err != nil {
		t.Fatalf("read second response: %v", err)
	}
	if !bytes.Equal(secondResponse, testDNSResponse(0x2222, 10, 0, 0, 22)) {
		t.Fatalf("second TCP response=%x, want fallback response", secondResponse)
	}
}

func startTestDNSServer(t *testing.T, delay time.Duration, response []byte) string {
	t.Helper()
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("ListenPacket: %v", err)
	}
	t.Cleanup(func() { conn.Close() })

	go func() {
		buf := make([]byte, 512)
		for {
			_, addr, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			time.Sleep(delay)
			_, _ = conn.WriteTo(response, addr)
		}
	}()

	return conn.LocalAddr().String()
}

func startTestDNSTCPServer(t *testing.T, delay time.Duration, response []byte) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	t.Cleanup(func() { listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				header := make([]byte, 2)
				if _, err := io.ReadFull(conn, header); err != nil {
					return
				}
				queryLen := int(header[0])<<8 | int(header[1])
				if queryLen <= 0 {
					return
				}
				query := make([]byte, queryLen)
				if _, err := io.ReadFull(conn, query); err != nil {
					return
				}
				time.Sleep(delay)
				tcpResponse := append([]byte{byte(len(response) >> 8), byte(len(response))}, response...)
				_, _ = conn.Write(tcpResponse)
			}(conn)
		}
	}()

	return listener.Addr().String()
}

func startBlackholeDNSServer(t *testing.T) string {
	t.Helper()
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("ListenPacket: %v", err)
	}
	t.Cleanup(func() { conn.Close() })

	go func() {
		buf := make([]byte, 512)
		for {
			if _, _, err := conn.ReadFrom(buf); err != nil {
				return
			}
		}
	}()

	return conn.LocalAddr().String()
}

func testDNSQuery(id uint16) []byte {
	msg := make([]byte, 0, 27)
	header := make([]byte, 12)
	binary.BigEndian.PutUint16(header[0:2], id)
	binary.BigEndian.PutUint16(header[2:4], 0x0100)
	binary.BigEndian.PutUint16(header[4:6], 1)
	msg = append(msg, header...)
	msg = append(msg, 7)
	msg = append(msg, []byte("example")...)
	msg = append(msg, 3)
	msg = append(msg, []byte("com")...)
	msg = append(msg, 0, 0, 1, 0, 1)
	return msg
}

func testDNSResponse(id uint16, a, b, c, d byte) []byte {
	query := testDNSQuery(id)
	resp := append([]byte(nil), query...)
	binary.BigEndian.PutUint16(resp[2:4], 0x8180)
	binary.BigEndian.PutUint16(resp[6:8], 1)
	resp = append(resp, 0xc0, 0x0c)
	resp = append(resp, 0, 1, 0, 1)
	resp = append(resp, 0, 0, 0, 60)
	resp = append(resp, 0, 4, a, b, c, d)
	return resp
}

func writeTCPDNSMessage(conn net.Conn, msg []byte) error {
	frame := append([]byte{byte(len(msg) >> 8), byte(len(msg))}, msg...)
	_, err := conn.Write(frame)
	return err
}

func readTCPDNSMessage(conn net.Conn) ([]byte, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(conn, header); err != nil {
		return nil, err
	}
	msgLen := int(header[0])<<8 | int(header[1])
	msg := make([]byte, msgLen)
	if _, err := io.ReadFull(conn, msg); err != nil {
		return nil, err
	}
	return msg, nil
}
