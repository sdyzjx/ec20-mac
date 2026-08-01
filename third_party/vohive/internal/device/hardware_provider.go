package device

import (
	"context"
	"fmt"
)

// HardwareSnapshot is one provider-scoped view of the currently attached
// modems. Epoch and Revision are opaque change tokens owned by that provider;
// neither they nor any runtime path in Modems are persistent device identity.
type HardwareSnapshot struct {
	Epoch    string
	Revision uint64
	Modems   []CompatibleModem
}

// HardwareProvider supplies platform-specific modem discovery without making
// the device pool depend on Linux sysfs, udev, or a Darwin IPC implementation.
// Snapshot implementations must honor context cancellation.
type HardwareProvider interface {
	Snapshot(context.Context) (HardwareSnapshot, error)
}

// PoolOption configures immutable Pool dependencies before background work is
// started. Options must not mutate a running Pool.
type PoolOption func(*Pool)

// WithHardwareProvider makes Pool discovery use one platform-owned snapshot
// source. Passing nil leaves the legacy Linux discovery path in place.
func WithHardwareProvider(provider HardwareProvider) PoolOption {
	return func(pool *Pool) {
		if pool != nil && provider != nil {
			pool.hardwareProvider = provider
		}
	}
}

func cloneCompatibleModems(modems []CompatibleModem) []CompatibleModem {
	cloned := make([]CompatibleModem, len(modems))
	for index := range modems {
		cloned[index] = modems[index]
		cloned[index].ATPorts = append([]string(nil), modems[index].ATPorts...)
	}
	return cloned
}

// DiscoverHardware returns a caller-owned, read-only platform snapshot. When
// no provider was injected it preserves the current Linux QMI+sysfs behavior.
func (p *Pool) DiscoverHardware(ctx context.Context) (HardwareSnapshot, error) {
	if p == nil {
		return HardwareSnapshot{}, fmt.Errorf("device pool is nil")
	}
	if ctx == nil {
		return HardwareSnapshot{}, fmt.Errorf("hardware discovery requires a context")
	}
	if err := ctx.Err(); err != nil {
		return HardwareSnapshot{}, err
	}
	if p.hardwareProvider != nil {
		snapshot, err := p.hardwareProvider.Snapshot(ctx)
		if err != nil {
			return HardwareSnapshot{}, err
		}
		if err := ctx.Err(); err != nil {
			return HardwareSnapshot{}, err
		}
		snapshot.Modems = cloneCompatibleModems(snapshot.Modems)
		return snapshot, nil
	}

	qmiDevices, qmiError := discoverQMIDevicesFn()
	if err := ctx.Err(); err != nil {
		return HardwareSnapshot{}, err
	}
	if qmiError != nil {
		qmiDevices = nil
	}
	modems, compatibleError := DiscoverCompatibleModemsFromQMI(qmiDevices)
	if compatibleError != nil {
		if qmiError != nil {
			return HardwareSnapshot{}, fmt.Errorf("QMI discovery: %v; compatible discovery: %w", qmiError, compatibleError)
		}
		return HardwareSnapshot{}, compatibleError
	}
	return HardwareSnapshot{Modems: cloneCompatibleModems(modems)}, nil
}

func (p *Pool) UsesHardwareProvider() bool {
	return p != nil && p.hardwareProvider != nil
}
