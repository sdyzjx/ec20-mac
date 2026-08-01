package device

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/1239t/vohive/internal/platform/ec20d"
)

type fakeEC20DPTYDiscoverer struct {
	snapshot ec20d.PTYSnapshot
	err      error
	called   int
	context  context.Context
}

type stalledEC20DPTYDiscoverer struct {
	context context.Context
	entered chan struct{}
}

func (f *stalledEC20DPTYDiscoverer) DiscoverPTY(ctx context.Context) (ec20d.PTYSnapshot, error) {
	f.context = ctx
	if f.entered != nil {
		close(f.entered)
	}
	<-ctx.Done()
	return ec20d.PTYSnapshot{}, ctx.Err()
}

func TestNewEC20DHardwareProviderAcceptsProtocolClient(t *testing.T) {
	client, err := ec20d.NewClient("/tmp/ec20d-provider-test.sock")
	if err != nil {
		t.Fatalf("ec20d.NewClient: %v", err)
	}
	provider, err := NewEC20DHardwareProvider(client)
	if err != nil {
		t.Fatalf("NewEC20DHardwareProvider: %v", err)
	}
	if provider.client != client {
		t.Fatal("NewEC20DHardwareProvider did not retain the protocol client")
	}
	if provider.snapshotTimeout < 2*time.Second || provider.snapshotTimeout > 4*time.Second {
		t.Fatalf("default snapshot timeout=%s, want approximately 3s", provider.snapshotTimeout)
	}
}

func (f *fakeEC20DPTYDiscoverer) DiscoverPTY(ctx context.Context) (ec20d.PTYSnapshot, error) {
	f.called++
	f.context = ctx
	if f.err != nil {
		return ec20d.PTYSnapshot{}, f.err
	}
	if err := ctx.Err(); err != nil {
		return ec20d.PTYSnapshot{}, err
	}
	return f.snapshot, nil
}

func TestEC20DHardwareProviderMapsValidatedPTYSnapshot(t *testing.T) {
	registryID := "4295764900"
	fake := &fakeEC20DPTYDiscoverer{snapshot: ec20d.PTYSnapshot{
		Epoch:    "daemon-epoch-a",
		Revision: 17,
		Devices: []ec20d.PTYDevice{
			{
				InstanceID:    "usb-03120000-1",
				Generation:    1,
				AttachmentKey: "ec20d:attach-a",
				LocationID:    "03120000",
				RegistryID:    &registryID,
				Path:          "/dev/ttys009",
				Ownership:     "cooperative_single_client",
			},
			{
				InstanceID:    "usb-04120000-2",
				Generation:    2,
				AttachmentKey: "ec20d:attach-b",
				LocationID:    "04120000",
				Path:          "/dev/ttys010",
				Ownership:     "cooperative_single_client",
			},
		},
	}}
	provider, err := newEC20DHardwareProvider(fake)
	if err != nil {
		t.Fatalf("newEC20DHardwareProvider: %v", err)
	}

	type contextKey string
	key := contextKey("test")
	ctx := context.WithValue(context.Background(), key, "preserved")
	got, err := provider.Snapshot(ctx)
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if fake.called != 1 || fake.context == nil || fake.context.Value(key) != "preserved" {
		t.Fatalf("DiscoverPTY did not receive the caller context values: called=%d context=%v", fake.called, fake.context)
	}
	if deadline, ok := fake.context.Deadline(); !ok || time.Until(deadline) <= 0 || time.Until(deadline) > 4*time.Second {
		t.Fatalf("DiscoverPTY context deadline=(%v,%v), want finite default deadline", deadline, ok)
	}
	if got.Epoch != fake.snapshot.Epoch || got.Revision != fake.snapshot.Revision {
		t.Fatalf("snapshot identity=(%q,%d), want (%q,%d)",
			got.Epoch, got.Revision, fake.snapshot.Epoch, fake.snapshot.Revision)
	}

	want := []CompatibleModem{
		{
			USBPath:        "ec20d:attach-a",
			VendorID:       0x2c7c,
			ProductID:      0x0125,
			DriverName:     "ec20d-pty",
			ATPorts:        []string{"/dev/ttys009"},
			ATPort:         "/dev/ttys009",
			Mode:           "at",
			TransportType:  "at",
			NetworkCapable: false,
		},
		{
			USBPath:        "ec20d:attach-b",
			VendorID:       0x2c7c,
			ProductID:      0x0125,
			DriverName:     "ec20d-pty",
			ATPorts:        []string{"/dev/ttys010"},
			ATPort:         "/dev/ttys010",
			Mode:           "at",
			TransportType:  "at",
			NetworkCapable: false,
		},
	}
	if !reflect.DeepEqual(got.Modems, want) {
		t.Fatalf("Snapshot modems = %#v, want %#v", got.Modems, want)
	}
	for index, modem := range got.Modems {
		if modem.IMEI != "" || modem.ControlPath != "" || modem.NetInterface != "" || modem.AudioDevice != "" {
			t.Fatalf("modem %d unexpectedly contains actively discovered data: %#v", index, modem)
		}
	}
}

func TestEC20DHardwareProviderReturnsIndependentATPortSlices(t *testing.T) {
	fake := &fakeEC20DPTYDiscoverer{snapshot: ec20d.PTYSnapshot{
		Epoch:    "daemon-epoch-a",
		Revision: 1,
		Devices: []ec20d.PTYDevice{
			{AttachmentKey: "ec20d:attach-a", Path: "/dev/ttys009"},
			{AttachmentKey: "ec20d:attach-b", Path: "/dev/ttys010"},
		},
	}}
	provider, err := newEC20DHardwareProvider(fake)
	if err != nil {
		t.Fatal(err)
	}

	snapshot, err := provider.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	snapshot.Modems[0].ATPorts[0] = "/dev/ttys999"
	if snapshot.Modems[1].ATPorts[0] != "/dev/ttys010" {
		t.Fatalf("ATPorts slices alias: %#v", snapshot.Modems)
	}
	if fake.snapshot.Devices[0].Path != "/dev/ttys009" {
		t.Fatalf("provider mutated ec20d input snapshot: %#v", fake.snapshot.Devices[0])
	}
}

func TestEC20DHardwareProviderPreservesEmptySnapshotIdentity(t *testing.T) {
	fake := &fakeEC20DPTYDiscoverer{snapshot: ec20d.PTYSnapshot{
		Epoch:    "daemon-epoch-empty",
		Revision: 23,
		Devices:  []ec20d.PTYDevice{},
	}}
	provider, err := newEC20DHardwareProvider(fake)
	if err != nil {
		t.Fatal(err)
	}

	snapshot, err := provider.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Epoch != "daemon-epoch-empty" || snapshot.Revision != 23 || len(snapshot.Modems) != 0 {
		t.Fatalf("unexpected empty snapshot: %#v", snapshot)
	}
	if snapshot.Modems == nil {
		t.Fatal("empty successful snapshot should carry a non-nil modem slice")
	}
}

func TestEC20DHardwareProviderPropagatesClientError(t *testing.T) {
	wantErr := &ec20d.RemoteError{Code: "busy", Message: "test busy", Retryable: true}
	provider, err := newEC20DHardwareProvider(&fakeEC20DPTYDiscoverer{err: wantErr})
	if err != nil {
		t.Fatal(err)
	}

	_, gotErr := provider.Snapshot(context.Background())
	var remote *ec20d.RemoteError
	if !errors.As(gotErr, &remote) || remote != wantErr {
		t.Fatalf("Snapshot error=%v, want wrapped RemoteError", gotErr)
	}
}

func TestEC20DHardwareProviderHonorsCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	fake := &fakeEC20DPTYDiscoverer{}
	provider, err := newEC20DHardwareProvider(fake)
	if err != nil {
		t.Fatal(err)
	}

	_, gotErr := provider.Snapshot(ctx)
	if !errors.Is(gotErr, context.Canceled) {
		t.Fatalf("Snapshot error=%v, want context.Canceled", gotErr)
	}
	if fake.called != 1 || fake.context == nil || !errors.Is(fake.context.Err(), context.Canceled) {
		t.Fatalf("canceled context was not forwarded: called=%d context=%v", fake.called, fake.context)
	}
}

func TestEC20DHardwareProviderDeadlineStopsStalledClient(t *testing.T) {
	stall := &stalledEC20DPTYDiscoverer{}
	provider, err := newEC20DHardwareProviderWithTimeout(stall, 25*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}

	result := make(chan error, 1)
	go func() {
		_, snapshotErr := provider.Snapshot(context.Background())
		result <- snapshotErr
	}()

	select {
	case snapshotErr := <-result:
		if !errors.Is(snapshotErr, context.DeadlineExceeded) {
			t.Fatalf("Snapshot error=%v, want context.DeadlineExceeded", snapshotErr)
		}
	case <-time.After(time.Second):
		t.Fatal("Snapshot remained blocked after its provider deadline")
	}
	if stall.context == nil {
		t.Fatal("stalled client did not receive a context")
	}
	if _, ok := stall.context.Deadline(); !ok {
		t.Fatal("stalled client context did not have a deadline")
	}
}

func TestEC20DHardwareProviderCallerDeadlineWins(t *testing.T) {
	stall := &stalledEC20DPTYDiscoverer{}
	provider, err := newEC20DHardwareProviderWithTimeout(stall, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	callerDeadline, _ := ctx.Deadline()

	result := make(chan error, 1)
	go func() {
		_, snapshotErr := provider.Snapshot(ctx)
		result <- snapshotErr
	}()

	select {
	case snapshotErr := <-result:
		if !errors.Is(snapshotErr, context.DeadlineExceeded) {
			t.Fatalf("Snapshot error=%v, want caller context deadline", snapshotErr)
		}
	case <-time.After(time.Second):
		t.Fatal("Snapshot ignored the caller's shorter deadline")
	}
	observedDeadline, ok := stall.context.Deadline()
	if !ok || observedDeadline.After(callerDeadline) {
		t.Fatalf("client deadline=(%v,%v), caller deadline=%v", observedDeadline, ok, callerDeadline)
	}
}

func TestEC20DHardwareProviderCallerCancelWins(t *testing.T) {
	stall := &stalledEC20DPTYDiscoverer{entered: make(chan struct{})}
	provider, err := newEC20DHardwareProviderWithTimeout(stall, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	result := make(chan error, 1)
	go func() {
		_, snapshotErr := provider.Snapshot(ctx)
		result <- snapshotErr
	}()

	select {
	case <-stall.entered:
		cancel()
	case <-time.After(time.Second):
		t.Fatal("stalled client was not called")
	}
	select {
	case snapshotErr := <-result:
		if !errors.Is(snapshotErr, context.Canceled) {
			t.Fatalf("Snapshot error=%v, want caller context cancellation", snapshotErr)
		}
	case <-time.After(time.Second):
		t.Fatal("Snapshot ignored caller cancellation")
	}
}

func TestEC20DHardwareProviderRejectsMissingDependencies(t *testing.T) {
	if _, err := NewEC20DHardwareProvider(nil); err == nil {
		t.Fatal("NewEC20DHardwareProvider(nil) unexpectedly succeeded")
	}
	if _, err := newEC20DHardwareProvider(nil); err == nil {
		t.Fatal("newEC20DHardwareProvider(nil) unexpectedly succeeded")
	}
	if _, err := newEC20DHardwareProviderWithTimeout(&fakeEC20DPTYDiscoverer{}, 0); err == nil {
		t.Fatal("newEC20DHardwareProviderWithTimeout(..., 0) unexpectedly succeeded")
	}

	var provider *EC20DHardwareProvider
	if _, err := provider.Snapshot(context.Background()); err == nil {
		t.Fatal("nil provider Snapshot unexpectedly succeeded")
	}

	provider = &EC20DHardwareProvider{client: &fakeEC20DPTYDiscoverer{}}
	if _, err := provider.Snapshot(nil); err == nil {
		t.Fatal("Snapshot(nil) unexpectedly succeeded")
	}
}
