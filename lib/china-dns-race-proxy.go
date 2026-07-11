// china-dns-race-proxy.go - UDP DNS race proxy for ChinaList lookups.
//
// Listens on localhost, forwards each DNS query to several upstreams in
// parallel, and returns the first valid response. Domestic resolvers are queried
// over UDP first, then retried over TCP 53 before global fallback resolvers are
// used. This handles networks where UDP/53 to China is filtered but TCP/53 is
// still reachable.
//
// Build: go build -o china-dns-race-proxy china-dns-race-proxy.go

package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

var (
	raceListenAddr    = flag.String("l", "127.0.0.1:5301", "Listen address")
	raceUpstreams     = flag.String("upstreams", "101.226.4.6:53,218.30.118.6:53,180.76.76.76:53,119.29.29.29:53", "Primary DNS upstreams")
	raceFallbacks     = flag.String("fallback-upstreams", "1.1.1.1:53,8.8.8.8:53,22.22.22.22:53", "Fallback DNS upstreams")
	raceTCPDelay      = flag.Duration("tcp-delay", 150*time.Millisecond, "Delay before retrying primary upstreams over TCP")
	raceFallbackDelay = flag.Duration("fallback-delay", 750*time.Millisecond, "Delay before querying fallback upstreams")
	raceTimeout       = flag.Duration("timeout", 2*time.Second, "Per-query timeout")
)

func main() {
	flag.Parse()

	primary := parseUpstreamList(*raceUpstreams)
	fallback := parseUpstreamList(*raceFallbacks)
	if len(primary) == 0 && len(fallback) == 0 {
		log.Fatal("no upstreams configured")
	}

	udpConn, err := net.ListenPacket("udp", *raceListenAddr)
	if err != nil {
		log.Fatalf("ListenPacket udp: %v", err)
	}
	defer udpConn.Close()

	tcpListener, err := net.Listen("tcp", *raceListenAddr)
	if err != nil {
		log.Fatalf("Listen tcp: %v", err)
	}
	defer tcpListener.Close()

	log.Printf("China DNS race proxy listening on %s (udp/tcp)", *raceListenAddr)
	log.Printf("primary upstreams: %s", strings.Join(primary, ","))
	log.Printf("fallback upstreams: %s", strings.Join(fallback, ","))
	log.Printf("tcp delay: %s; fallback delay: %s; timeout: %s", *raceTCPDelay, *raceFallbackDelay, *raceTimeout)

	go serveTCP(tcpListener, primary, fallback, *raceTCPDelay, *raceFallbackDelay, *raceTimeout)
	serveUDP(udpConn, primary, fallback, *raceTCPDelay, *raceFallbackDelay, *raceTimeout)
}

func serveUDP(conn net.PacketConn, primary []string, fallback []string, tcpDelay time.Duration, fallbackDelay time.Duration, timeout time.Duration) {
	buf := make([]byte, 4096)
	for {
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			log.Printf("ReadFrom: %v", err)
			continue
		}
		query := append([]byte(nil), buf[:n]...)
		go handleRaceQuery(conn, addr, query, primary, fallback, *raceTCPDelay, *raceFallbackDelay, *raceTimeout)
	}
}

func serveTCP(listener net.Listener, primary []string, fallback []string, tcpDelay time.Duration, fallbackDelay time.Duration, timeout time.Duration) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("Accept tcp: %v", err)
			continue
		}
		go handleTCPConnection(conn, primary, fallback, tcpDelay, fallbackDelay, timeout)
	}
}

func handleRaceQuery(conn net.PacketConn, addr net.Addr, query []byte, primary []string, fallback []string, tcpDelay time.Duration, fallbackDelay time.Duration, timeout time.Duration) {
	response, err := raceQuery(query, primary, fallback, tcpDelay, fallbackDelay, timeout)
	if err != nil {
		log.Printf("[%s] DNS race failed: %v", addr.String(), err)
		response = dnsErrorResponse(query, 2)
		if response == nil {
			return
		}
		if _, err := conn.WriteTo(response, addr); err != nil {
			log.Printf("[%s] WriteTo SERVFAIL: %v", addr.String(), err)
		}
		return
	}
	if _, err := conn.WriteTo(response, addr); err != nil {
		log.Printf("[%s] WriteTo: %v", addr.String(), err)
	}
}

func handleTCPConnection(conn net.Conn, primary []string, fallback []string, tcpDelay time.Duration, fallbackDelay time.Duration, timeout time.Duration) {
	defer conn.Close()

	for {
		lengthBytes := make([]byte, 2)
		if _, err := io.ReadFull(conn, lengthBytes); err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
				log.Printf("[%s] Read TCP query length: %v", conn.RemoteAddr().String(), err)
			}
			return
		}
		queryLen := int(binary.BigEndian.Uint16(lengthBytes))
		if queryLen < 12 {
			log.Printf("[%s] TCP query too short: %d", conn.RemoteAddr().String(), queryLen)
			return
		}

		query := make([]byte, queryLen)
		if _, err := io.ReadFull(conn, query); err != nil {
			log.Printf("[%s] Read TCP query: %v", conn.RemoteAddr().String(), err)
			return
		}

		response, err := raceQuery(query, primary, fallback, tcpDelay, fallbackDelay, timeout)
		if err != nil {
			log.Printf("[%s] TCP DNS race failed: %v", conn.RemoteAddr().String(), err)
			response = dnsErrorResponse(query, 2)
			if response == nil {
				return
			}
		}
		if len(response) > 65535 {
			log.Printf("[%s] TCP response too large: %d", conn.RemoteAddr().String(), len(response))
			return
		}

		framedResponse := make([]byte, 2+len(response))
		binary.BigEndian.PutUint16(framedResponse[:2], uint16(len(response)))
		copy(framedResponse[2:], response)
		if _, err := conn.Write(framedResponse); err != nil {
			log.Printf("[%s] Write TCP response: %v", conn.RemoteAddr().String(), err)
			return
		}
	}
}

func raceQuery(query []byte, primary []string, fallback []string, tcpDelay time.Duration, fallbackDelay time.Duration, timeout time.Duration) ([]byte, error) {
	if len(query) < 2 {
		return nil, errors.New("query too short")
	}
	if fallbackDelay < tcpDelay {
		fallbackDelay = tcpDelay
	}

	responses := make(chan []byte, len(primary)*2+len(fallback))
	startQueries := func(network string, upstreams []string) {
		for _, upstream := range upstreams {
			upstream := upstream
			go func() {
				response, err := queryUpstream(network, query, upstream, timeout)
				if err != nil || !validDNSResponse(query, response) {
					return
				}
				responses <- response
			}()
		}
	}

	startQueries("udp", primary)

	tcpTimer := time.NewTimer(tcpDelay)
	defer tcpTimer.Stop()
	fallbackTimer := time.NewTimer(fallbackDelay)
	defer fallbackTimer.Stop()
	timeoutTimer := time.NewTimer(timeout)
	defer timeoutTimer.Stop()

	tcpStarted := len(primary) == 0
	fallbackStarted := len(fallback) == 0
	for {
		select {
		case response := <-responses:
			return response, nil
		case <-tcpTimer.C:
			if !tcpStarted {
				startQueries("tcp", primary)
				tcpStarted = true
			}
		case <-fallbackTimer.C:
			if !fallbackStarted {
				startQueries("udp", fallback)
				fallbackStarted = true
			}
		case <-timeoutTimer.C:
			return nil, errors.New("all upstreams timed out")
		}
	}
}

func queryUpstream(network string, query []byte, upstream string, timeout time.Duration) ([]byte, error) {
	switch network {
	case "udp":
		return queryUDPUpstream(query, upstream, timeout)
	case "tcp":
		return queryTCPUpstream(query, upstream, timeout)
	default:
		return nil, errors.New("unsupported network")
	}
}

func queryUDPUpstream(query []byte, upstream string, timeout time.Duration) ([]byte, error) {
	conn, err := net.DialTimeout("udp", upstream, timeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	deadline := time.Now().Add(timeout)
	if err := conn.SetDeadline(deadline); err != nil {
		return nil, err
	}
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}

	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, err
	}
	return append([]byte(nil), buf[:n]...), nil
}

func queryTCPUpstream(query []byte, upstream string, timeout time.Duration) ([]byte, error) {
	if len(query) > 65535 {
		return nil, errors.New("query too large")
	}

	conn, err := net.DialTimeout("tcp", upstream, timeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	deadline := time.Now().Add(timeout)
	if err := conn.SetDeadline(deadline); err != nil {
		return nil, err
	}

	framedQuery := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(framedQuery[:2], uint16(len(query)))
	copy(framedQuery[2:], query)
	if _, err := conn.Write(framedQuery); err != nil {
		return nil, err
	}

	lengthBytes := make([]byte, 2)
	if _, err := io.ReadFull(conn, lengthBytes); err != nil {
		return nil, err
	}
	responseLen := int(binary.BigEndian.Uint16(lengthBytes))
	if responseLen < 12 {
		return nil, errors.New("tcp response too short")
	}
	response := make([]byte, responseLen)
	if _, err := io.ReadFull(conn, response); err != nil {
		return nil, err
	}
	return response, nil
}

func validDNSResponse(query []byte, response []byte) bool {
	if len(query) < 2 || len(response) < 12 {
		return false
	}
	if response[0] != query[0] || response[1] != query[1] {
		return false
	}
	return response[2]&0x80 != 0
}

func dnsErrorResponse(query []byte, rcode byte) []byte {
	if len(query) < 12 {
		return nil
	}

	end := 12
	qdCount := int(query[4])<<8 | int(query[5])
	for i := 0; i < qdCount; i++ {
		for {
			if end >= len(query) {
				return nil
			}
			labelLen := int(query[end])
			end++
			if labelLen == 0 {
				break
			}
			if labelLen&0xc0 == 0xc0 {
				if end >= len(query) {
					return nil
				}
				end++
				break
			}
			if labelLen&0xc0 != 0 || end+labelLen > len(query) {
				return nil
			}
			end += labelLen
		}
		if end+4 > len(query) {
			return nil
		}
		end += 4
	}

	response := append([]byte(nil), query[:end]...)
	flags := uint16(response[2])<<8 | uint16(response[3])
	flags |= 0x8000
	flags &^= 0x000f
	flags |= uint16(rcode & 0x0f)
	response[2] = byte(flags >> 8)
	response[3] = byte(flags)
	response[6] = 0
	response[7] = 0
	response[8] = 0
	response[9] = 0
	response[10] = 0
	response[11] = 0
	return response
}

func parseUpstreamList(input string) []string {
	var upstreams []string
	for _, item := range strings.FieldsFunc(input, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' }) {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if _, _, err := net.SplitHostPort(item); err != nil {
			item = net.JoinHostPort(item, "53")
		}
		upstreams = append(upstreams, item)
	}
	return upstreams
}
