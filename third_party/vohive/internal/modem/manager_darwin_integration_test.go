//go:build darwin

package modem

import (
	"os"
	"os/exec"
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
	urcStates := make(chan string, 1)
	manager.SetSIMStatusHandler(func(_ *bool, state string) {
		select {
		case urcStates <- state:
		default:
		}
	})
	ec20ctlPath := os.Getenv("VOHIVE_EC20CTL_BIN")
	socketPath := os.Getenv("VOHIVE_EC20D_MOCK_SOCKET")
	if ec20ctlPath == "" || socketPath == "" {
		t.Fatal("guarded mock URC injector environment is missing")
	}
	if output, err := exec.Command(ec20ctlPath, "--socket", socketPath, "mock-urc", "+CPIN: READY").CombinedOutput(); err != nil {
		t.Fatalf("inject mock URC: %v (%s)", err, output)
	}
	select {
	case state := <-urcStates:
		if state != "READY" {
			t.Fatalf("SIM URC state=%q, want READY", state)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Manager did not dispatch the injected SIM URC")
	}

	smsReceived := make(chan struct {
		sender  string
		content string
	}, 1)
	manager.SetSMSCallback(func(sender, content string, _ time.Time) {
		smsReceived <- struct {
			sender  string
			content string
		}{sender: sender, content: content}
	})
	if output, err := exec.Command(ec20ctlPath, "--socket", socketPath, "mock-urc", `+CMTI: "ME",7`).CombinedOutput(); err != nil {
		t.Fatalf("inject mock CMTI: %v (%s)", err, output)
	}
	select {
	case sms := <-smsReceived:
		if sms.sender == "" || sms.content == "" {
			t.Fatalf("decoded incoming SMS sender=%q content=%q", sms.sender, sms.content)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Manager did not read and dispatch the injected incoming SMS")
	}

	ussdResult := make(chan *USSDResult, 1)
	ussdError := make(chan error, 1)
	go func() {
		result, err := manager.ExecuteUSSD("*123#", 2*time.Second)
		if err != nil {
			ussdError <- err
			return
		}
		ussdResult <- result
	}()
	time.Sleep(100 * time.Millisecond)
	if output, err := exec.Command(ec20ctlPath, "--socket", socketPath, "mock-urc", `+CUSD: 0,"Mock balance",15`).CombinedOutput(); err != nil {
		t.Fatalf("inject mock CUSD: %v (%s)", err, output)
	}
	select {
	case result := <-ussdResult:
		if result == nil || result.Text != "Mock balance" || result.Status != 0 {
			t.Fatalf("USSD result=%#v", result)
		}
	case err := <-ussdError:
		t.Fatalf("ExecuteUSSD: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("Manager did not dispatch the injected USSD response")
	}

	ring := make(chan struct{}, 1)
	clip := make(chan string, 1)
	hangup := make(chan struct{}, 1)
	manager.SetRingCallback(func() { ring <- struct{}{} })
	manager.SetClipCallback(func(number string) { clip <- number })
	manager.SetHangupCallback(func() { hangup <- struct{}{} })
	for _, urc := range []string{"RING", `+CLIP: "+12025550123",145`, "NO CARRIER"} {
		if output, err := exec.Command(ec20ctlPath, "--socket", socketPath, "mock-urc", urc).CombinedOutput(); err != nil {
			t.Fatalf("inject mock call URC %q: %v (%s)", urc, err, output)
		}
	}
	select {
	case <-ring:
	case <-time.After(2 * time.Second):
		t.Fatal("Manager did not dispatch RING")
	}
	select {
	case number := <-clip:
		if number != "+12025550123" {
			t.Fatalf("CLIP number=%q", number)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Manager did not dispatch CLIP")
	}
	select {
	case <-hangup:
	case <-time.After(2 * time.Second):
		t.Fatal("Manager did not dispatch NO CARRIER")
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
