//go:build darwin

package modem

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1239t/vohive/internal/config"
)

func TestDarwinPrepareSerialPortAcceptsCharacterDevice(t *testing.T) {
	manager, err := New(config.DeviceConfig{ID: "darwin-port", DeviceBackend: "at", ATPort: "/dev/null"})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.prepareSerialPortForOpen("/dev/null"); err != nil {
		t.Fatalf("prepareSerialPortForOpen(/dev/null): %v", err)
	}
}

func TestDarwinPrepareSerialPortRejectsRegularFileAndSymlink(t *testing.T) {
	manager, err := New(config.DeviceConfig{ID: "darwin-port", DeviceBackend: "at", ATPort: "/dev/null"})
	if err != nil {
		t.Fatal(err)
	}
	regular := filepath.Join(t.TempDir(), "not-a-device")
	if err := os.WriteFile(regular, []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := manager.prepareSerialPortForOpen(regular); err == nil || !strings.Contains(err.Error(), "absolute /dev") {
		t.Fatalf("regular file error=%v, want /dev rejection", err)
	}

	symlink := filepath.Join("/dev", "vohive-test-symlink")
	// Creating entries below /dev is neither required nor safe in a unit test;
	// a temporary symlink is already rejected by the absolute /dev boundary.
	temporaryLink := filepath.Join(t.TempDir(), filepath.Base(symlink))
	if err := os.Symlink("/dev/null", temporaryLink); err != nil {
		t.Fatal(err)
	}
	if err := manager.prepareSerialPortForOpen(temporaryLink); err == nil {
		t.Fatal("Darwin preflight unexpectedly accepted a symlink")
	}
}

func TestDarwinManagerStartFailsBeforeOpeningNonDevice(t *testing.T) {
	regular := filepath.Join(t.TempDir(), "not-a-device")
	if err := os.WriteFile(regular, []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}
	manager, err := New(config.DeviceConfig{ID: "darwin-port", DeviceBackend: "at", ATPort: regular})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Start(); err == nil || !strings.Contains(err.Error(), "预检失败") {
		t.Fatalf("Start error=%v, want Darwin preflight failure", err)
	}
	lease, err := acquireSerialPortLease(regular, "test-reacquire")
	if err != nil {
		t.Fatalf("failed Start leaked its lease: %v", err)
	}
	lease.Release()
}
