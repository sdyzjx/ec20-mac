package server

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestBoundDNSResolverUsesConfiguredServer(t *testing.T) {
	dnsAddr := startProxyTCPDNSServer(t, func(w dns.ResponseWriter, req *dns.Msg) {
		resp := new(dns.Msg)
		resp.SetReply(req)
		resp.Answer = append(resp.Answer, &dns.A{
			Hdr: dns.RR_Header{Name: req.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
			A:   net.ParseIP("203.0.113.17").To4(),
		})
		_ = w.WriteMsg(resp)
	})

	resolver := newBoundDNSResolver(&net.Dialer{Timeout: time.Second}, []string{"127.0.0.1:1", dnsAddr})
	resolver.timeout = time.Second
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, ip, err := resolver.Resolve(ctx, "example.test")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if got, want := ip.String(), "203.0.113.17"; got != want {
		t.Fatalf("Resolve() = %s, want %s", got, want)
	}
}

func TestBoundDNSResolverDoesNotFallBackToSystemDNS(t *testing.T) {
	dnsAddr := startProxyTCPDNSServer(t, func(w dns.ResponseWriter, req *dns.Msg) {
		resp := new(dns.Msg)
		resp.SetRcode(req, dns.RcodeNameError)
		_ = w.WriteMsg(resp)
	})

	resolver := newBoundDNSResolver(&net.Dialer{Timeout: time.Second}, []string{dnsAddr})
	resolver.timeout = time.Second
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	if _, ip, err := resolver.Resolve(ctx, "localhost"); err == nil || ip != nil {
		t.Fatalf("Resolve(localhost) = %v, %v; want configured DNS error without system fallback", ip, err)
	}
}

func TestBoundDNSResolverRejectsIPv6Literal(t *testing.T) {
	resolver := newBoundDNSResolver(&net.Dialer{}, []string{"127.0.0.1:53"})
	if _, ip, err := resolver.Resolve(context.Background(), "2001:db8::1"); err == nil || ip != nil {
		t.Fatalf("Resolve(IPv6) = %v, %v; want IPv4-only error", ip, err)
	}
}

func startProxyTCPDNSServer(t *testing.T, handler dns.HandlerFunc) string {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen DNS test server: %v", err)
	}
	server := &dns.Server{Listener: listener, Handler: handler}
	done := make(chan struct{})
	go func() {
		_ = server.ActivateAndServe()
		close(done)
	}()
	t.Cleanup(func() {
		_ = server.Shutdown()
		<-done
	})
	return listener.Addr().String()
}
