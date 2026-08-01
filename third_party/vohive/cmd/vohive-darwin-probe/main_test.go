package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/1239t/vohive/internal/device"
)

func TestDefaultSocketPathUsesEnvironment(t *testing.T) {
	t.Setenv("EC20D_SOCKET", "/tmp/custom-ec20d.sock")
	if got := defaultSocketPath(); got != "/tmp/custom-ec20d.sock" {
		t.Fatalf("defaultSocketPath()=%q", got)
	}
}

func TestNewPoolDiagnosticSnapshotExcludesIdentityAndControlFields(t *testing.T) {
	got := newPoolDiagnosticSnapshot(device.HardwareSnapshot{
		Epoch:    "daemon-epoch",
		Revision: 9,
		Modems: []device.CompatibleModem{{
			USBPath:        "ec20d:attach-a",
			IMEI:           "must-not-be-copied",
			VendorID:       0x2c7c,
			ProductID:      0x0125,
			DriverName:     "ec20d-pty",
			ATPort:         "/dev/ttys009",
			NetInterface:   "en11",
			ControlPath:    "must-not-be-copied",
			Mode:           "at",
			NetworkCapable: false,
		}},
	})
	want := poolDiagnosticSnapshot{
		Epoch:    "daemon-epoch",
		Revision: 9,
		Devices: []poolDiagnosticDevice{{
			AttachmentKey:  "ec20d:attach-a",
			VendorIDHex:    "2c7c",
			ProductIDHex:   "0125",
			DriverName:     "ec20d-pty",
			Path:           "/dev/ttys009",
			InterfaceName:  "en11",
			Mode:           "at",
			NetworkCapable: false,
		}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("newPoolDiagnosticSnapshot()=%#v, want %#v", got, want)
	}
}

func TestDefaultSocketPathUsesTemporaryDirectory(t *testing.T) {
	t.Setenv("EC20D_SOCKET", "")
	if got, want := defaultSocketPath(), filepath.Join(os.TempDir(), "ec20d.sock"); got != want {
		t.Fatalf("defaultSocketPath()=%q, want %q", got, want)
	}
}
