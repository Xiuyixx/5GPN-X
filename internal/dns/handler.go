package dns

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"
	"time"

	mdns "github.com/miekg/dns"
)

type Forwarder struct {
	upstreams []string
	seq       atomic.Uint64
	client    *mdns.Client
}

func NewForwarder(upstreams []string) *Forwarder {
	return &Forwarder{upstreams: NormalizeUpstreams(upstreams), client: &mdns.Client{Net: "tcp", Timeout: 4 * time.Second}}
}

func (f *Forwarder) ServeDNS(w mdns.ResponseWriter, req *mdns.Msg) {
	if len(req.Question) == 0 {
		m := new(mdns.Msg)
		m.SetRcode(req, mdns.RcodeFormatError)
		_ = w.WriteMsg(m)
		return
	}
	var last error
	for i := 0; i < len(f.upstreams); i++ {
		upstream := f.upstreams[int(f.seq.Add(1)-1)%len(f.upstreams)]
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		resp, _, err := f.exchange(ctx, req, upstream)
		cancel()
		if err == nil {
			resp.Id = req.Id
			_ = w.WriteMsg(resp)
			return
		}
		last = err
	}
	m := new(mdns.Msg)
	m.SetRcode(req, mdns.RcodeServerFailure)
	_ = w.WriteMsg(m)
	_ = last
}

func (f *Forwarder) exchange(ctx context.Context, req *mdns.Msg, upstream string) (*mdns.Msg, time.Duration, error) {
	if _, _, err := net.SplitHostPort(upstream); err != nil {
		return nil, 0, fmt.Errorf("invalid DNS upstream %q", upstream)
	}
	return f.client.ExchangeContext(ctx, req, upstream)
}
