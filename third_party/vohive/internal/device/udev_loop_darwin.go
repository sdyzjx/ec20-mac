//go:build darwin

package device

import (
	"context"
	"time"

	"github.com/1239t/vohive/pkg/logger"
)

const defaultDarwinHardwarePollInterval = time.Second

type darwinHardwareSnapshotToken struct {
	epoch    string
	revision uint64
}

func tokenForHardwareSnapshot(snapshot HardwareSnapshot) darwinHardwareSnapshotToken {
	return darwinHardwareSnapshotToken{epoch: snapshot.Epoch, revision: snapshot.Revision}
}

func darwinHardwareSnapshotChanged(previous, current darwinHardwareSnapshotToken) bool {
	return previous.epoch != current.epoch || previous.revision != current.revision
}

// Darwin has no netlink/udev source. The authenticated ec20d provider owns the
// IOKit snapshot and a monotonically increasing revision, so polling that small
// metadata surface is enough to drive the existing debounced rescan path. No
// PTY is opened and no AT command is sent here.
func (w *UdevWatcher) loop() {
	if w == nil || w.pool == nil || !w.pool.UsesHardwareProvider() {
		logger.Info("Darwin hot-plug polling requires a platform hardware provider")
		return
	}

	ctx := w.pool.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	ticker := time.NewTicker(defaultDarwinHardwarePollInterval)
	defer ticker.Stop()

	var previous darwinHardwareSnapshotToken
	havePrevious := false
	lastError := ""
	logger.Info("Darwin modem hot-plug polling started")
	for {
		select {
		case <-w.stop:
			logger.Info("Darwin modem hot-plug polling stopped")
			return
		case <-ctx.Done():
			return
		case <-ticker.C:
			snapshot, err := w.pool.DiscoverHardware(ctx)
			if err != nil {
				if message := err.Error(); message != lastError {
					logger.Warn("Darwin hardware snapshot failed", "err", err)
					lastError = message
				}
				continue
			}
			lastError = ""
			current := tokenForHardwareSnapshot(snapshot)
			if !havePrevious {
				previous = current
				havePrevious = true
				continue
			}
			if darwinHardwareSnapshotChanged(previous, current) {
				logger.Info("Darwin modem snapshot changed",
					"old_revision", previous.revision,
					"new_revision", current.revision,
					"daemon_changed", previous.epoch != current.epoch)
				previous = current
				w.scheduleRescan()
			}
		}
	}
}
