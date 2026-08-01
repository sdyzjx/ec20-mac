package netbind

import (
	"fmt"
	"strings"
	"syscall"
)

type socketBinder func(fd uintptr, network, address string) error

// Control returns a net.Dialer.Control callback that binds every socket to the
// requested interface. A non-empty interface always fails closed: lookup or
// setsockopt errors are returned to DialContext instead of falling back to the
// system default route.
func Control(interfaceName string) func(network, address string, raw syscall.RawConn) error {
	interfaceName = strings.TrimSpace(interfaceName)
	if interfaceName == "" {
		return nil
	}
	binder, prepareError := newSocketBinder(interfaceName)
	return func(network, address string, raw syscall.RawConn) error {
		if prepareError != nil {
			return prepareError
		}
		if raw == nil {
			return fmt.Errorf("bind %s: socket control is unavailable", interfaceName)
		}
		var bindError error
		if err := raw.Control(func(fd uintptr) {
			bindError = binder(fd, network, address)
		}); err != nil {
			return fmt.Errorf("bind %s: access socket: %w", interfaceName, err)
		}
		if bindError != nil {
			return fmt.Errorf("bind %s: %w", interfaceName, bindError)
		}
		return nil
	}
}
