//go:build darwin

package netbind

import (
	"net"
	"testing"

	"golang.org/x/sys/unix"
)

func loopbackInterfaceName(*testing.T) string { return "lo0" }

func TestDarwinNetworkFamily(t *testing.T) {
	tests := []struct {
		network string
		address string
		want    int
	}{
		{"tcp4", "example.invalid:443", 4},
		{"udp6", "example.invalid:53", 6},
		{"tcp", "127.0.0.1:443", 4},
		{"tcp", "[::1]:443", 6},
	}
	for _, test := range tests {
		if got, err := darwinNetworkFamily(test.network, test.address); err != nil || got != test.want {
			t.Errorf("darwinNetworkFamily(%q, %q)=(%d, %v), want %d", test.network, test.address, got, err, test.want)
		}
	}
	if _, err := darwinNetworkFamily("tcp", "example.invalid:443"); err == nil {
		t.Fatal("darwinNetworkFamily accepted ambiguous family")
	}
}

func TestDarwinBinderAppliesInterfaceIndexForBothFamilies(t *testing.T) {
	interfaceValue, err := net.InterfaceByName("lo0")
	if err != nil {
		t.Fatal(err)
	}
	binder, err := newSocketBinder("lo0")
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name       string
		domain     int
		network    string
		level      int
		optionName int
	}{
		{"IPv4", unix.AF_INET, "tcp4", unix.IPPROTO_IP, unix.IP_BOUND_IF},
		{"IPv6", unix.AF_INET6, "tcp6", unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fd, err := unix.Socket(test.domain, unix.SOCK_STREAM, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer unix.Close(fd)
			if err := binder(uintptr(fd), test.network, ""); err != nil {
				t.Fatalf("bind socket: %v", err)
			}
			got, err := unix.GetsockoptInt(fd, test.level, test.optionName)
			if err != nil {
				t.Fatalf("read bound interface: %v", err)
			}
			if got != interfaceValue.Index {
				t.Fatalf("bound interface index=%d, want %d", got, interfaceValue.Index)
			}
		})
	}
}
