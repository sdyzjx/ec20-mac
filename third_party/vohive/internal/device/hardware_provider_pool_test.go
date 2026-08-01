package device

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/1239t/vohive/internal/config"
)

type fakeHardwareProvider struct {
	mu       sync.Mutex
	snapshot HardwareSnapshot
	err      error
	calls    int
	lastCtx  context.Context
}

type retryHardwareProvider struct {
	mu    sync.Mutex
	calls int
}

func (p *retryHardwareProvider) Snapshot(context.Context) (HardwareSnapshot, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls++
	if p.calls == 1 {
		return HardwareSnapshot{}, context.DeadlineExceeded
	}
	return HardwareSnapshot{Epoch: "recovered", Modems: []CompatibleModem{}}, nil
}

func (f *fakeHardwareProvider) Snapshot(ctx context.Context) (HardwareSnapshot, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.lastCtx = ctx
	if f.err != nil {
		return HardwareSnapshot{}, f.err
	}
	return f.snapshot, nil
}

func (f *fakeHardwareProvider) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func TestNewPoolWithHardwareProviderUsesSnapshotAndClonesSlices(t *testing.T) {
	provider := &fakeHardwareProvider{snapshot: HardwareSnapshot{
		Epoch:    "provider-epoch",
		Revision: 41,
		Modems: []CompatibleModem{{
			USBPath: "ec20d:attach-a",
			ATPort:  "/dev/ttys009",
			ATPorts: []string{"/dev/ttys009"},
		}},
	}}
	pool := NewPool(nil, WithHardwareProvider(provider))
	defer pool.cancel()
	if !pool.UsesHardwareProvider() {
		t.Fatal("Pool did not retain the injected HardwareProvider")
	}

	type contextKey string
	ctx := context.WithValue(context.Background(), contextKey("request"), "preserved")
	snapshot, err := pool.DiscoverHardware(ctx)
	if err != nil {
		t.Fatalf("DiscoverHardware: %v", err)
	}
	if snapshot.Epoch != "provider-epoch" || snapshot.Revision != 41 || len(snapshot.Modems) != 1 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
	if provider.lastCtx != ctx {
		t.Fatal("DiscoverHardware did not forward its context")
	}
	snapshot.Modems[0].ATPorts[0] = "/dev/ttys999"
	if provider.snapshot.Modems[0].ATPorts[0] != "/dev/ttys009" {
		t.Fatal("DiscoverHardware returned a provider-owned ATPorts slice")
	}
}

func TestCollectRescanHardwareUsesProviderSnapshot(t *testing.T) {
	provider := &fakeHardwareProvider{snapshot: HardwareSnapshot{
		Modems: []CompatibleModem{{USBPath: "ec20d:attach-a", ATPort: "/dev/ttys009"}},
	}}
	pool := NewPool(nil, WithHardwareProvider(provider))
	defer pool.cancel()

	hardware, err := pool.collectRescanHardwareContext(context.Background(),
		[]QMIDevice{{ControlPath: "/dev/legacy-must-not-be-used"}},
		BuildWorkerDiscoveryIndex(nil, false))
	if err != nil {
		t.Fatalf("collectRescanHardwareContext: %v", err)
	}
	if len(hardware) != 1 || hardware[0].USBPath != "ec20d:attach-a" {
		t.Fatalf("unexpected provider hardware: %#v", hardware)
	}
	if provider.callCount() != 1 {
		t.Fatalf("provider calls=%d, want 1", provider.callCount())
	}
}

func TestRescanHardwareProviderErrorDoesNotEvictWorkers(t *testing.T) {
	want := errors.New("provider unavailable")
	provider := &fakeHardwareProvider{err: want}
	pool := NewPool(nil, WithHardwareProvider(provider))
	defer pool.cancel()
	worker := &Worker{ID: "existing-worker"}
	pool.workers[worker.ID] = worker

	err := pool.RescanAndReconnect()
	if !errors.Is(err, want) {
		t.Fatalf("RescanAndReconnect error=%v, want provider error", err)
	}
	if pool.GetWorker(worker.ID) != worker {
		t.Fatal("provider failure mutated the existing worker set")
	}
}

func TestRescanHardwareProviderTimeoutReleasesLockForRetry(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(configPath, []byte("devices: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := config.InitGlobalManager(configPath); err != nil {
		t.Fatal(err)
	}

	provider := &retryHardwareProvider{}
	pool := NewPool(nil, WithHardwareProvider(provider))
	defer pool.cancel()

	if err := pool.RescanAndReconnect(); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("first RescanAndReconnect error=%v, want deadline", err)
	}
	if err := pool.RescanAndReconnect(); err != nil {
		t.Fatalf("retry RescanAndReconnect: %v", err)
	}
	provider.mu.Lock()
	calls := provider.calls
	provider.mu.Unlock()
	if calls != 2 {
		t.Fatalf("provider calls=%d, want 2", calls)
	}
}

func TestHardwareProviderCanceledContextDoesNotScan(t *testing.T) {
	provider := &fakeHardwareProvider{}
	pool := NewPool(nil, WithHardwareProvider(provider))
	defer pool.cancel()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := pool.DiscoverHardware(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("DiscoverHardware error=%v, want context.Canceled", err)
	}
	if provider.callCount() != 0 {
		t.Fatalf("provider calls=%d, want 0", provider.callCount())
	}
}

func TestAuthoritativeEmptyProviderSnapshotEvictsOfflineWorker(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	configBody := "devices:\n- id: configured-at\n  device_backend: at\n  modem_imei: \"999999999999999\"\n"
	if err := os.WriteFile(configPath, []byte(configBody), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := config.InitGlobalManager(configPath); err != nil {
		t.Fatal(err)
	}
	provider := &fakeHardwareProvider{snapshot: HardwareSnapshot{
		Epoch:  "provider-epoch",
		Modems: []CompatibleModem{},
	}}
	pool := NewPool(&config.Config{}, WithHardwareProvider(provider))
	defer pool.cancel()
	worker := &Worker{ID: "configured-at", stop: make(chan struct{})}
	pool.workers[worker.ID] = worker

	if err := pool.RescanAndReconnect(); err != nil {
		t.Fatalf("RescanAndReconnect: %v", err)
	}
	if pool.GetWorker(worker.ID) != nil {
		t.Fatal("authoritative empty snapshot did not mark the configured worker offline")
	}
}

func TestWithNilHardwareProviderKeepsLegacyMode(t *testing.T) {
	pool := NewPool(nil, WithHardwareProvider(nil))
	defer pool.cancel()
	if pool.UsesHardwareProvider() {
		t.Fatal("nil HardwareProvider replaced the legacy discovery path")
	}
}
