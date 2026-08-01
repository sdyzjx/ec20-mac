//go:build linux

package netbind

import "golang.org/x/sys/unix"

func newSocketBinder(interfaceName string) (socketBinder, error) {
	return func(fd uintptr, _, _ string) error {
		return unix.SetsockoptString(int(fd), unix.SOL_SOCKET, unix.SO_BINDTODEVICE, interfaceName)
	}, nil
}
