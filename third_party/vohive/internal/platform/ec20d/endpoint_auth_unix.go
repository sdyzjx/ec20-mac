//go:build darwin || linux

package ec20d

import (
	"fmt"
	"net"
	"os"
	"syscall"
)

// authenticateEndpoint ties the protocol handshake to a local, same-euid
// ec20d endpoint. The application must still place the socket in a private
// runtime directory (or use launchd socket activation) before shipping.
func authenticateEndpoint(conn net.Conn, socketPath string) error {
	info, err := os.Lstat(socketPath)
	if err != nil {
		return fmt.Errorf("inspect socket: %w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("configured endpoint is not a Unix socket")
	}
	if permissions := info.Mode().Perm(); permissions != 0o600 {
		return fmt.Errorf("socket permissions are %04o, want 0600", permissions)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("socket ownership metadata is unavailable")
	}
	expectedUID := uint32(os.Geteuid())
	if stat.Uid != expectedUID {
		return fmt.Errorf("socket uid is %d, want effective uid %d", stat.Uid, expectedUID)
	}

	uid, err := peerUID(conn)
	if err != nil {
		return fmt.Errorf("read peer credentials: %w", err)
	}
	if uid != expectedUID {
		return fmt.Errorf("peer uid is %d, want effective uid %d", uid, expectedUID)
	}
	return nil
}

func authenticatePTYEndpoint(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect PTY: %w", err)
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return fmt.Errorf("path is not a character device")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("PTY ownership metadata is unavailable")
	}
	expectedUID := uint32(os.Geteuid())
	if stat.Uid != expectedUID {
		return fmt.Errorf("PTY uid is %d, want effective uid %d", stat.Uid, expectedUID)
	}
	return nil
}
