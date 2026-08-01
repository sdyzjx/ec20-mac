package device

import (
	"context"
	"fmt"
	"time"

	"github.com/1239t/vohive/internal/platform/ec20d"
)

const (
	ec20dPTYVendorID   uint16 = 0x2c7c
	ec20dPTYProductID  uint16 = 0x0125
	ec20dPTYDriverName        = "ec20d-pty"
	ec20dPTYMode              = "at"

	defaultEC20DHardwareSnapshotTimeout = 3 * time.Second
)

type ec20dPTYDiscoverer interface {
	DiscoverPTY(context.Context) (ec20d.PTYSnapshot, error)
}

// EC20DHardwareProvider adapts ec20d's validated, minimized PTY snapshot to
// Vohive's platform-neutral CompatibleModem model. It consumes metadata only:
// it never opens the returned PTY and never sends AT commands.
type EC20DHardwareProvider struct {
	client          ec20dPTYDiscoverer
	snapshotTimeout time.Duration
}

var _ HardwareProvider = (*EC20DHardwareProvider)(nil)

// NewEC20DHardwareProvider creates a Darwin metadata adapter around an ec20d
// protocol client. Each Snapshot gets a three-second ceiling unless its caller
// supplies an earlier deadline or cancellation. The client already enforces
// the EC20 VID/PID and interface safety contract before returning a PTYSnapshot.
func NewEC20DHardwareProvider(client *ec20d.Client) (*EC20DHardwareProvider, error) {
	if client == nil {
		return nil, fmt.Errorf("ec20d hardware provider requires a client")
	}
	return newEC20DHardwareProvider(client)
}

func newEC20DHardwareProvider(client ec20dPTYDiscoverer) (*EC20DHardwareProvider, error) {
	return newEC20DHardwareProviderWithTimeout(client, defaultEC20DHardwareSnapshotTimeout)
}

func newEC20DHardwareProviderWithTimeout(client ec20dPTYDiscoverer, timeout time.Duration) (*EC20DHardwareProvider, error) {
	if client == nil {
		return nil, fmt.Errorf("ec20d hardware provider requires a client")
	}
	if timeout <= 0 {
		return nil, fmt.Errorf("ec20d hardware provider requires a positive snapshot timeout")
	}
	return &EC20DHardwareProvider{
		client:          client,
		snapshotTimeout: timeout,
	}, nil
}

// Snapshot preserves ec20d's daemon epoch and revision while translating each
// attach-scoped PTY record. IMEI remains empty so the adapter cannot turn a
// metadata-only discovery pass into an implicit serial probe.
func (p *EC20DHardwareProvider) Snapshot(ctx context.Context) (HardwareSnapshot, error) {
	if p == nil || p.client == nil {
		return HardwareSnapshot{}, fmt.Errorf("ec20d hardware provider is not initialized")
	}
	if ctx == nil {
		return HardwareSnapshot{}, fmt.Errorf("ec20d hardware provider requires a context")
	}

	timeout := p.snapshotTimeout
	if timeout <= 0 {
		timeout = defaultEC20DHardwareSnapshotTimeout
	}
	snapshotCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	snapshot, err := p.client.DiscoverPTY(snapshotCtx)
	if err != nil {
		return HardwareSnapshot{}, fmt.Errorf("discover ec20d PTY hardware: %w", err)
	}

	modems := make([]CompatibleModem, len(snapshot.Devices))
	for index, device := range snapshot.Devices {
		mode := ec20dPTYMode
		netInterface := ""
		networkCapable := false
		if device.Network != nil {
			mode = device.Network.Mode
			netInterface = device.Network.InterfaceName
			networkCapable = true
		}
		modems[index] = CompatibleModem{
			USBPath:        device.AttachmentKey,
			VendorID:       ec20dPTYVendorID,
			ProductID:      ec20dPTYProductID,
			DriverName:     ec20dPTYDriverName,
			ATPorts:        []string{device.Path},
			ATPort:         device.Path,
			NetInterface:   netInterface,
			Mode:           mode,
			TransportType:  ec20dPTYMode,
			NetworkCapable: networkCapable,
		}
	}

	return HardwareSnapshot{
		Epoch:    snapshot.Epoch,
		Revision: snapshot.Revision,
		Modems:   modems,
	}, nil
}
