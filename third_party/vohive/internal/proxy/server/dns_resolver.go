package server

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

const proxyDNSResolveTimeout = 5 * time.Second

// defaultProxyDNSServers deliberately excludes the host's system resolver.
// On macOS a VPN may return synthetic addresses (for example 198.18.0.0/15)
// which are only routable through its utun interface. DNS sockets use the same
// interface-bound dialer as proxy traffic, so neither lookup nor the resulting
// connection can silently fall back to another host interface.
var defaultProxyDNSServers = []string{
	"192.168.225.1:53", // Quectel ECM gateway/DNS proxy
	"1.1.1.1:53",
	"8.8.8.8:53",
}

type boundDNSResolver struct {
	dialer  *net.Dialer
	servers []string
	timeout time.Duration
}

func newBoundDNSResolver(dialer *net.Dialer, servers []string) *boundDNSResolver {
	return &boundDNSResolver{
		dialer:  dialer,
		servers: append([]string(nil), servers...),
		timeout: proxyDNSResolveTimeout,
	}
}

// Resolve implements socks5.NameResolver. The go-socks5 interface returns one
// address, so the proxy intentionally asks for IPv4 A records until the Darwin
// ECM IPv6 path has its own end-to-end gate.
func (r *boundDNSResolver) Resolve(ctx context.Context, name string) (context.Context, net.IP, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return ctx, nil, errors.New("proxy dns name is empty")
	}
	if ip := net.ParseIP(name); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			return ctx, append(net.IP(nil), v4...), nil
		}
		return ctx, nil, fmt.Errorf("proxy dns only supports IPv4 destinations: %s", name)
	}
	if r == nil || r.dialer == nil {
		return ctx, nil, errors.New("proxy dns bound dialer is unavailable")
	}
	if len(r.servers) == 0 {
		return ctx, nil, errors.New("proxy dns servers are empty")
	}

	queryCtx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()

	client := &dns.Client{
		Net:     "tcp4",
		Timeout: r.timeout,
		Dialer:  r.dialer,
	}
	message := new(dns.Msg)
	message.SetQuestion(dns.Fqdn(name), dns.TypeA)

	var errs []error
	for _, server := range r.servers {
		server = strings.TrimSpace(server)
		if server == "" {
			continue
		}
		response, _, err := client.ExchangeContext(queryCtx, message, server)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", server, err))
			continue
		}
		if response == nil {
			errs = append(errs, fmt.Errorf("%s: empty response", server))
			continue
		}
		if response.Rcode != dns.RcodeSuccess {
			errs = append(errs, fmt.Errorf("%s: dns rcode=%s", server, dns.RcodeToString[response.Rcode]))
			continue
		}
		for _, answer := range response.Answer {
			record, ok := answer.(*dns.A)
			if !ok || record.A == nil {
				continue
			}
			return ctx, append(net.IP(nil), record.A.To4()...), nil
		}
		errs = append(errs, fmt.Errorf("%s: no A record", server))
	}

	err := errors.Join(errs...)
	if err == nil {
		err = fmt.Errorf("host %s has no usable proxy DNS server", name)
	}
	return ctx, nil, fmt.Errorf("resolve %s through bound DNS: %w", name, err)
}
