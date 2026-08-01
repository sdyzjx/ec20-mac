//go:build darwin

package device

import (
	"os"
	"testing"
)

func TestDarwinECMControllerFailsClosedForMissingInterface(t *testing.T) {
	controller := newECMNetworkController("en9999")
	if controller == nil || !networkControllerIsExternallyManaged(controller) {
		t.Fatalf("unexpected ECM controller: %#v", controller)
	}
	if controller.IsConnected() || controller.GetPrivateIP() != "" ||
		controller.GetPrivateIPv6() != "" {
		t.Fatal("missing interface was reported as connected")
	}
	if err := controller.Connect(); err == nil {
		t.Fatal("Connect unexpectedly fell back from a missing interface")
	}
	if v4, v6 := controller.GetPublicIPv4AndV6NoCache(); v4 != "" || v6 != "" {
		t.Fatalf("missing interface returned public addresses v4=%q v6=%q", v4, v6)
	}
}

func TestDarwinECMLiveInterface(t *testing.T) {
	interfaceName := os.Getenv("VOHIVE_ECM_INTERFACE")
	if interfaceName == "" {
		t.Skip("set VOHIVE_ECM_INTERFACE for the live ECM acceptance test")
	}
	controller := newECMNetworkController(interfaceName)
	if err := controller.Connect(); err != nil {
		t.Fatalf("live ECM Connect: %v", err)
	}
	if controller.GetPrivateIP() == "" {
		t.Fatal("live ECM interface has no IPv4 address")
	}
	v4, _ := controller.GetPublicIPv4AndV6NoCache()
	if v4 == "" {
		t.Fatal("live ECM interface did not produce a bound public IPv4 result")
	}
	if err := controller.Disconnect(); err == nil {
		t.Fatal("externally managed ECM disconnect must not report false success")
	}
	if err := controller.RotateIP(); err == nil {
		t.Fatal("unsupported ECM rotation must not report false success")
	}
}
