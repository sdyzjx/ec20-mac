//go:build darwin

package modem

import (
	"os"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/1239t/vohive/internal/config"
)

func TestDarwinManagerEC20DMockPTYLifecycle(t *testing.T) {
	if os.Getenv("VOHIVE_EC20D_MOCK_ONLY") != "ec20d-mock-no-usb" {
		t.Skip("requires the guarded ec20d --mock integration harness")
	}
	portPath := os.Getenv("VOHIVE_EC20D_MOCK_PTY")
	if !regexp.MustCompile(`^/dev/ttys[0-9a-f]+$`).MatchString(portPath) {
		t.Fatalf("invalid guarded mock PTY path: %q", portPath)
	}
	info, err := os.Lstat(portPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeCharDevice == 0 || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("mock PTY is not a direct character device: mode=%s", info.Mode())
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Geteuid() {
		t.Fatalf("mock PTY owner uid=%v, want euid=%d", stat, os.Geteuid())
	}

	manager, err := New(config.DeviceConfig{
		ID:            "darwin-ec20d-mock",
		DeviceBackend: "at",
		ATPort:        portPath,
		ManagePort:    portPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Start(); err != nil {
		t.Fatalf("Manager.Start: %v", err)
	}
	managerRunning := true
	defer func() {
		if managerRunning {
			manager.StopAndWait(3 * time.Second)
		}
	}()

	if !manager.WaitReady(4 * time.Second) {
		t.Fatal("Manager did not complete mock initialization")
	}
	response, err := manager.ExecuteAT("AT", 2*time.Second)
	if err != nil {
		t.Fatalf("Manager.ExecuteAT: %v", err)
	}
	if !strings.Contains(response, "AT") {
		t.Fatalf("mock response=%q, want command echo", response)
	}
	if _, err := ProbeIMEI(portPath, 100*time.Millisecond); err == nil || !strings.Contains(err.Error(), "manager:darwin-ec20d-mock") {
		t.Fatalf("concurrent IMEI probe error=%v, want Manager lease", err)
	}

	if !manager.StopAndWait(3 * time.Second) {
		t.Fatal("Manager did not stop and join its loops")
	}
	managerRunning = false

	oneShot, err := NewSerialAT(portPath, 115200, 8, 1, "N")
	if err != nil {
		t.Fatalf("Manager leaked PTY lease after Stop: %v", err)
	}
	defer oneShot.Close()
	oneShotResponse, err := oneShot.Execute("AT", 2*time.Second)
	if err != nil {
		t.Fatalf("SerialAT after Manager Stop: %v (response=%q)", err, oneShotResponse)
	}
	if !strings.Contains(oneShotResponse, "OK") {
		t.Fatalf("SerialAT response=%q, want OK", oneShotResponse)
	}
}
