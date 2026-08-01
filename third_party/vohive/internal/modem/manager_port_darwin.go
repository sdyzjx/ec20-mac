//go:build darwin

package modem

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// prepareSerialPortForOpen validates the endpoint but never runs fuser and
// never signals another process. If another process owns the serial endpoint,
// serial.Open must fail closed and the caller reports the conflict.
func (m *Manager) prepareSerialPortForOpen(portPath string) error {
	cleaned := filepath.Clean(strings.TrimSpace(portPath))
	if !filepath.IsAbs(cleaned) || cleaned == "/dev" || !strings.HasPrefix(cleaned, "/dev/") {
		return fmt.Errorf("Darwin serial endpoint must be an absolute /dev path")
	}
	info, err := os.Lstat(cleaned)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("Darwin serial endpoint must not be a symlink")
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return fmt.Errorf("Darwin serial endpoint is not a character device")
	}
	return nil
}
