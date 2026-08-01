//go:build linux

package ec20d

import (
	"fmt"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func peerUID(conn net.Conn) (uint32, error) {
	syscallConn, ok := conn.(syscall.Conn)
	if !ok {
		return 0, fmt.Errorf("connection does not expose a socket descriptor")
	}
	raw, err := syscallConn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var credentialError error
	if err := raw.Control(func(fd uintptr) {
		credential, err := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		if err != nil {
			credentialError = err
			return
		}
		uid = credential.Uid
	}); err != nil {
		return 0, err
	}
	if credentialError != nil {
		return 0, credentialError
	}
	return uid, nil
}
