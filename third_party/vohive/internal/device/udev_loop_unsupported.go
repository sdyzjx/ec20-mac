//go:build !linux && !darwin

package device

import (
	"runtime"

	"github.com/1239t/vohive/pkg/logger"
)

func (w *UdevWatcher) loop() {
	logger.Info("udev hot-plug source is unavailable on this platform; a platform hardware provider is required",
		"platform", runtime.GOOS)
}
