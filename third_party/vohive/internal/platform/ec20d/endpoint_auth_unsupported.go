//go:build !darwin && !linux

package ec20d

import (
	"fmt"
	"net"
)

func authenticateEndpoint(net.Conn, string) error {
	return fmt.Errorf("ec20d endpoint authentication is unsupported on this platform")
}

func authenticatePTYEndpoint(string) error {
	return fmt.Errorf("ec20d PTY authentication is unsupported on this platform")
}
