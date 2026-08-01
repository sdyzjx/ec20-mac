package ec20d

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type responseScript func(requestEnvelope) (map[string]any, error)

func newScriptedClient(t *testing.T, script responseScript) (*Client, <-chan error) {
	t.Helper()
	client, err := NewClient("/tmp/ec20d-test.sock")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	serverResult := make(chan error, 1)
	client.dial = func(context.Context, string, string) (net.Conn, error) {
		clientConn, serverConn := net.Pipe()
		go func() {
			defer serverConn.Close()
			reader := bufio.NewReader(serverConn)
			for requestIndex := 0; requestIndex < 2; requestIndex++ {
				record, readErr := reader.ReadBytes('\n')
				if readErr != nil {
					serverResult <- readErr
					return
				}
				var request requestEnvelope
				if decodeErr := json.Unmarshal(record, &request); decodeErr != nil {
					serverResult <- decodeErr
					return
				}
				if request.Schema != Schema || request.APIVersion != APIVersion {
					serverResult <- fmt.Errorf("unexpected request protocol: %#v", request)
					return
				}
				response, scriptErr := script(request)
				if scriptErr != nil {
					serverResult <- scriptErr
					return
				}
				wire, marshalErr := json.Marshal(response)
				if marshalErr != nil {
					serverResult <- marshalErr
					return
				}
				wire = append(wire, '\n')
				if writeErr := writeAll(serverConn, wire); writeErr != nil {
					serverResult <- writeErr
					return
				}
				if request.Method == "devices.list" {
					serverResult <- nil
					return
				}
			}
			serverResult <- fmt.Errorf("script did not receive devices.list")
		}()
		return clientConn, nil
	}
	client.authenticate = func(net.Conn, string) error { return nil }
	client.verifyPTY = func(string) error { return nil }
	return client, serverResult
}

func successResponse(id string, result any) map[string]any {
	return map[string]any{
		"schema":      Schema,
		"api_version": APIVersion,
		"id":          id,
		"ok":          true,
		"result":      result,
	}
}

func stringPointer(value string) *string {
	return &value
}

func validDevice(path string) Device {
	return Device{
		InstanceID: "usb-03120000-1",
		Generation: 1,
		Identity: DeviceIdentity{
			USBLocationID: "03120000",
			VendorID:      0x2c7c,
			ProductID:     0x0125,
		},
		Lifecycle: DeviceLifecycle{State: "ready"},
		USB: USBTopology{
			Configuration:          1,
			ATInterfaceNumber:      2,
			NetworkInterfaceNumber: 4,
			RegistryID:             stringPointer("4295764900"),
		},
		AT: ATTransport{
			Transport:       "pty",
			Path:            stringPointer(path),
			InterfaceNumber: 2,
			Ownership:       "cooperative_single_client",
			Available:       true,
		},
		Capabilities: []string{"management.at"},
	}
}

func standardScript(device Device) responseScript {
	return func(request requestEnvelope) (map[string]any, error) {
		switch request.Method {
		case "system.hello":
			return successResponse(request.ID, Hello{
				Server:           "ec20d",
				ServerVersion:    "0.1.0",
				DaemonInstanceID: "daemon-test",
				Capabilities:     []string{"devices.list", "at.pty", "future.capability"},
			}), nil
		case "devices.list":
			return successResponse(request.ID, Snapshot{
				Revision: 7,
				Devices:  []Device{device},
			}), nil
		default:
			return nil, fmt.Errorf("unexpected method %q", request.Method)
		}
	}
}

func waitForServer(t *testing.T, result <-chan error) {
	t.Helper()
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("scripted server: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("scripted server did not finish")
	}
}

func TestDiscoverPTYValidatesAndMinimizesSnapshot(t *testing.T) {
	client, serverResult := newScriptedClient(t, standardScript(validDevice("/dev/ttys009")))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	snapshot, err := client.DiscoverPTY(ctx)
	if err != nil {
		t.Fatalf("DiscoverPTY: %v", err)
	}
	waitForServer(t, serverResult)
	if snapshot.Epoch != "daemon-test" || snapshot.Revision != 7 {
		t.Fatalf("unexpected snapshot identity: %#v", snapshot)
	}
	if len(snapshot.Devices) != 1 {
		t.Fatalf("len(devices)=%d, want 1", len(snapshot.Devices))
	}
	got := snapshot.Devices[0]
	if got.InstanceID != "usb-03120000-1" || got.Generation != 1 ||
		got.LocationID != "03120000" || got.Path != "/dev/ttys009" ||
		got.RegistryID == nil || *got.RegistryID != "4295764900" ||
		!strings.HasPrefix(got.AttachmentKey, "ec20d:") || len(got.AttachmentKey) != 70 {
		t.Fatalf("unexpected PTY device: %#v", got)
	}
}

func TestAttachmentKeyChangesAcrossDaemonAndAttachIdentity(t *testing.T) {
	base := validDevice("/dev/ttys009")
	baseKey := attachmentKey("daemon-a", base)
	if got := attachmentKey("daemon-b", base); got == baseKey {
		t.Fatal("attachment key did not change with daemon epoch")
	}
	replacement := base
	replacement.USB.RegistryID = stringPointer("4295764901")
	if got := attachmentKey("daemon-a", replacement); got == baseKey {
		t.Fatal("attachment key did not change with registry identity")
	}
	replacement = base
	replacement.Generation++
	if got := attachmentKey("daemon-a", replacement); got == baseKey {
		t.Fatal("attachment key did not change with generation")
	}
}

func TestDiscoverPTYRejectsMissingCapability(t *testing.T) {
	script := func(request requestEnvelope) (map[string]any, error) {
		if request.Method != "system.hello" {
			return nil, fmt.Errorf("unexpected method %q", request.Method)
		}
		return successResponse(request.ID, Hello{
			Server:           "ec20d",
			DaemonInstanceID: "daemon-test",
			Capabilities:     []string{"devices.list"},
		}), nil
	}
	client, _ := newScriptedClient(t, script)
	_, err := client.DiscoverPTY(context.Background())
	if err == nil || !strings.Contains(err.Error(), "at.pty") {
		t.Fatalf("DiscoverPTY error=%v, want missing at.pty", err)
	}
}

func TestDiscoverPTYReturnsTypedRemoteError(t *testing.T) {
	script := func(request requestEnvelope) (map[string]any, error) {
		return map[string]any{
			"schema":      Schema,
			"api_version": APIVersion,
			"id":          request.ID,
			"ok":          false,
			"error": RemoteError{
				Code:      "busy",
				Message:   "test busy",
				Retryable: true,
			},
		}, nil
	}
	client, _ := newScriptedClient(t, script)
	_, err := client.DiscoverPTY(context.Background())
	var remote *RemoteError
	if !errors.As(err, &remote) || remote.Code != "busy" || !remote.Retryable {
		t.Fatalf("DiscoverPTY error=%v, want retryable busy RemoteError", err)
	}
}

func TestDiscoverPTYRejectsMalformedProtocolResponses(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "wrong schema",
			mutate: func(response map[string]any) {
				response["schema"] = "ec20.vohive/2"
			},
		},
		{
			name: "wrong response id",
			mutate: func(response map[string]any) {
				response["id"] = "other-id"
			},
		},
	}
	for _, version := range []string{"1", "1.x", "1.0.0", "1.-1", "+1.0", " 1.0"} {
		version := version
		tests = append(tests, struct {
			name   string
			mutate func(map[string]any)
		}{
			name: "malformed API " + version,
			mutate: func(response map[string]any) {
				response["api_version"] = version
			},
		})
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			script := func(request requestEnvelope) (map[string]any, error) {
				response := successResponse(request.ID, Hello{
					Server:           "ec20d",
					DaemonInstanceID: "daemon-test",
					Capabilities:     []string{"devices.list", "at.pty"},
				})
				test.mutate(response)
				return response, nil
			}
			client, _ := newScriptedClient(t, script)
			if _, err := client.DiscoverPTY(context.Background()); err == nil {
				t.Fatal("DiscoverPTY unexpectedly accepted malformed protocol response")
			}
		})
	}
}

func TestDiscoverPTYReturnsContextCancellationFromBlockedRead(t *testing.T) {
	client, err := NewClient("/tmp/ec20d-test.sock")
	if err != nil {
		t.Fatal(err)
	}
	requestSeen := make(chan struct{})
	serverDone := make(chan struct{})
	client.dial = func(context.Context, string, string) (net.Conn, error) {
		clientConn, serverConn := net.Pipe()
		go func() {
			defer close(serverDone)
			defer serverConn.Close()
			_, _ = bufio.NewReader(serverConn).ReadBytes('\n')
			close(requestSeen)
			_, _ = io.Copy(io.Discard, serverConn)
		}()
		return clientConn, nil
	}
	client.authenticate = func(net.Conn, string) error { return nil }
	client.verifyPTY = func(string) error { return nil }

	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, discoverErr := client.DiscoverPTY(ctx)
		result <- discoverErr
	}()
	<-requestSeen
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("DiscoverPTY error=%v, want context.Canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("DiscoverPTY did not unblock after cancellation")
	}
	<-serverDone
}

func TestDiscoverPTYRejectsUnsafePathAndInterface(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Device)
	}{
		{
			name: "path outside dev",
			mutate: func(device *Device) {
				device.AT.Path = stringPointer("/tmp/ttys009")
			},
		},
		{
			name: "network interface exposed as AT",
			mutate: func(device *Device) {
				device.AT.InterfaceNumber = 4
			},
		},
		{
			name: "claims exclusive ownership",
			mutate: func(device *Device) {
				device.AT.Ownership = "exclusive_client"
			},
		},
		{
			name: "mixed RPC identity",
			mutate: func(device *Device) {
				device.AT.RPCDeviceID = stringPointer("usb-03120000-1")
			},
		},
		{
			name: "missing management capability",
			mutate: func(device *Device) {
				device.Capabilities = nil
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			device := validDevice("/dev/ttys009")
			test.mutate(&device)
			client, serverResult := newScriptedClient(t, standardScript(device))
			if _, err := client.DiscoverPTY(context.Background()); err == nil {
				t.Fatal("DiscoverPTY unexpectedly accepted invalid PTY")
			}
			waitForServer(t, serverResult)
		})
	}
}

func TestDiscoverPTYRejectsOversizedRecord(t *testing.T) {
	client, err := NewClient("/tmp/ec20d-test.sock")
	if err != nil {
		t.Fatal(err)
	}
	client.dial = func(context.Context, string, string) (net.Conn, error) {
		clientConn, serverConn := net.Pipe()
		go func() {
			defer serverConn.Close()
			_, _ = bufio.NewReader(serverConn).ReadBytes('\n')
			payload := strings.Repeat("x", maximumRecordBytes+1) + "\n"
			_ = writeAll(serverConn, []byte(payload))
		}()
		return clientConn, nil
	}
	client.authenticate = func(net.Conn, string) error { return nil }
	client.verifyPTY = func(string) error { return nil }
	_, err = client.DiscoverPTY(context.Background())
	if !errors.Is(err, ErrRecordTooLarge) {
		t.Fatalf("DiscoverPTY error=%v, want ErrRecordTooLarge", err)
	}
}

func TestReadRecordRejectsExactLimitWithoutNewline(t *testing.T) {
	reader := bufio.NewReaderSize(strings.NewReader(strings.Repeat("x", maximumRecordBytes)), 64*1024)
	if _, err := readRecord(reader, maximumRecordBytes); !errors.Is(err, ErrRecordTooLarge) {
		t.Fatalf("readRecord error=%v, want ErrRecordTooLarge", err)
	}
}

func TestReadRecordAcceptsExactLimitIncludingNewline(t *testing.T) {
	payload := strings.Repeat("x", maximumRecordBytes-1) + "\n"
	reader := bufio.NewReaderSize(strings.NewReader(payload), 64*1024)
	record, err := readRecord(reader, maximumRecordBytes)
	if err != nil {
		t.Fatalf("readRecord: %v", err)
	}
	if len(record) != maximumRecordBytes-1 {
		t.Fatalf("len(record)=%d", len(record))
	}
}

func TestEndpointAuthenticationRequiresSameUserPrivateSocket(t *testing.T) {
	testDirectory, err := os.MkdirTemp("/tmp", "ec20d-auth.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(testDirectory) })
	socketPath := filepath.Join(testDirectory, "ec20d.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(socketPath, 0o600); err != nil {
		t.Fatal(err)
	}
	accepted := make(chan net.Conn, 1)
	acceptError := make(chan error, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			acceptError <- acceptErr
			return
		}
		accepted <- conn
	}()
	clientConn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()
	select {
	case serverConn := <-accepted:
		defer serverConn.Close()
	case err := <-acceptError:
		t.Fatal(err)
	case <-time.After(2 * time.Second):
		t.Fatal("listener did not accept connection")
	}
	if err := authenticateEndpoint(clientConn, socketPath); err != nil {
		t.Fatalf("authenticateEndpoint: %v", err)
	}
	if err := os.Chmod(socketPath, 0o660); err != nil {
		t.Fatal(err)
	}
	if err := authenticateEndpoint(clientConn, socketPath); err == nil {
		t.Fatal("authenticateEndpoint accepted group-writable socket")
	}
}

func TestValidPTYPathUsesDarwinHexGrammar(t *testing.T) {
	for _, path := range []string{"/dev/ttys0", "/dev/ttys009", "/dev/ttys00a", "/dev/ttysdeadbeef"} {
		if !validPTYPath(path) {
			t.Errorf("validPTYPath(%q)=false", path)
		}
	}
	for _, path := range []string{"/dev/ttys", "/dev/ttysABC", "/dev/ttys../x", "/dev/ttys00g", "/tmp/ttys009"} {
		if validPTYPath(path) {
			t.Errorf("validPTYPath(%q)=true", path)
		}
	}
}

func TestNewClientRequiresAbsolutePath(t *testing.T) {
	for _, path := range []string{"", "relative.sock", "relative/ec20d.sock"} {
		if _, err := NewClient(path); err == nil {
			t.Fatalf("NewClient(%q) unexpectedly succeeded", path)
		}
	}
}
