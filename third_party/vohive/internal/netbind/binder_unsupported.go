//go:build !darwin && !linux

package netbind

import (
	"fmt"
	"runtime"
)

func newSocketBinder(string) (socketBinder, error) {
	return nil, fmt.Errorf("interface-bound sockets are unsupported on %s", runtime.GOOS)
}
