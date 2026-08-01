//go:build darwin

package device

import "testing"

func TestDarwinHardwareSnapshotTokenDetectsRevisionAndDaemonEpoch(t *testing.T) {
	base := tokenForHardwareSnapshot(HardwareSnapshot{Epoch: "daemon-a", Revision: 7})
	if darwinHardwareSnapshotChanged(base, base) {
		t.Fatal("identical snapshot token reported a change")
	}
	if !darwinHardwareSnapshotChanged(base,
		tokenForHardwareSnapshot(HardwareSnapshot{Epoch: "daemon-a", Revision: 8})) {
		t.Fatal("revision change was not detected")
	}
	if !darwinHardwareSnapshotChanged(base,
		tokenForHardwareSnapshot(HardwareSnapshot{Epoch: "daemon-b", Revision: 7})) {
		t.Fatal("daemon epoch change was not detected")
	}
}
