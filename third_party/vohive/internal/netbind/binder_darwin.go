//go:build darwin

package netbind

import (
	"fmt"
	"net"
	"strings"

	"golang.org/x/sys/unix"
)

func newSocketBinder(interfaceName string) (socketBinder, error) {
	interfaceValue, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return nil, fmt.Errorf("resolve interface: %w", err)
	}
	if interfaceValue.Index <= 0 {
		return nil, fmt.Errorf("interface has invalid index %d", interfaceValue.Index)
	}
	index := interfaceValue.Index
	return func(fd uintptr, network, address string) error {
		family, err := darwinNetworkFamily(network, address)
		if err != nil {
			return err
		}
		switch family {
		case 4:
			return unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, index)
		case 6:
			return unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, index)
		default:
			return fmt.Errorf("unsupported address family")
		}
	}, nil
}

func darwinNetworkFamily(network, address string) (int, error) {
	network = strings.ToLower(strings.TrimSpace(network))
	if strings.HasSuffix(network, "4") {
		return 4, nil
	}
	if strings.HasSuffix(network, "6") {
		return 6, nil
	}
	host, _, err := net.SplitHostPort(address)
	if err == nil {
		if ip := net.ParseIP(strings.Trim(host, "[]")); ip != nil {
			if ip.To4() != nil {
				return 4, nil
			}
			return 6, nil
		}
	}
	return 0, fmt.Errorf("cannot determine address family for network %q address %q", network, address)
}
