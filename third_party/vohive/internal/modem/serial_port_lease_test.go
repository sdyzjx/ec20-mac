package modem

import (
	"strings"
	"testing"
	"time"
)

func TestSerialPortLeaseRejectsConcurrentOwnerAndAllowsReacquire(t *testing.T) {
	first, err := acquireSerialPortLease(" /dev/ttys0aa ", "manager:first")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(first.Release)

	if _, err := acquireSerialPortLease("/dev/ttys0aa", "probe:second"); err == nil || !strings.Contains(err.Error(), "manager:first") {
		t.Fatalf("second lease error=%v, want current owner", err)
	}
	first.Release()
	second, err := acquireSerialPortLease("/dev/ttys0aa", "probe:second")
	if err != nil {
		t.Fatalf("reacquire after release: %v", err)
	}
	second.Release()
}

func TestSerialPortLeaseAllowsDifferentEndpoints(t *testing.T) {
	first, err := acquireSerialPortLease("/dev/ttys0ab", "manager:first")
	if err != nil {
		t.Fatal(err)
	}
	defer first.Release()
	second, err := acquireSerialPortLease("/dev/ttys0ac", "manager:second")
	if err != nil {
		t.Fatal(err)
	}
	second.Release()
}

func TestSerialPortLeaseRejectsEmptyInputs(t *testing.T) {
	if _, err := acquireSerialPortLease(" ", "owner"); err == nil {
		t.Fatal("empty port unexpectedly accepted")
	}
	if _, err := acquireSerialPortLease("/dev/ttys0ad", " "); err == nil {
		t.Fatal("empty owner unexpectedly accepted")
	}
}

func TestIMEIProbeCannotOpenManagerLeasedPort(t *testing.T) {
	lease, err := acquireSerialPortLease("/dev/vohive-nonexistent", "manager:active")
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Release()

	if _, err := ProbeIMEI("/dev/vohive-nonexistent", time.Millisecond); err == nil || !strings.Contains(err.Error(), "manager:active") {
		t.Fatalf("ProbeIMEI error=%v, want active manager lease", err)
	}
}

func TestSerialATCannotOpenManagerLeasedPort(t *testing.T) {
	lease, err := acquireSerialPortLease("/dev/vohive-nonexistent-at", "manager:active")
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Release()

	if _, err := NewSerialAT("/dev/vohive-nonexistent-at", 115200, 8, 1, "N"); err == nil || !strings.Contains(err.Error(), "manager:active") {
		t.Fatalf("NewSerialAT error=%v, want active manager lease", err)
	}
}
