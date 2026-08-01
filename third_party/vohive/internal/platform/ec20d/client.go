package ec20d

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	maximumRecordBytes = 1024 * 1024
	clientName         = "vohive-darwin"
	clientVersion      = "0.1"
)

var (
	ErrRecordTooLarge = errors.New("ec20d response exceeds the 1 MiB record limit")
	ErrUnsupportedAPI = errors.New("ec20d returned an unsupported protocol version")
)

type dialContextFunc func(context.Context, string, string) (net.Conn, error)

type Client struct {
	socketPath   string
	dial         dialContextFunc
	authenticate func(net.Conn, string) error
	verifyPTY    func(string) error
}

func NewClient(socketPath string) (*Client, error) {
	socketPath = strings.TrimSpace(socketPath)
	if socketPath == "" || !filepath.IsAbs(socketPath) || strings.ContainsAny(socketPath, "\r\n\x00") {
		return nil, fmt.Errorf("ec20d socket path must be a non-empty absolute path")
	}
	socketPath = filepath.Clean(socketPath)
	return &Client{
		socketPath:   socketPath,
		dial:         (&net.Dialer{}).DialContext,
		authenticate: authenticateEndpoint,
		verifyPTY:    authenticatePTYEndpoint,
	}, nil
}

type requestEnvelope struct {
	Schema     string         `json:"schema"`
	APIVersion string         `json:"api_version"`
	ID         string         `json:"id"`
	Method     string         `json:"method"`
	Params     map[string]any `json:"params"`
}

type responseEnvelope struct {
	Schema     string          `json:"schema"`
	APIVersion string          `json:"api_version"`
	ID         string          `json:"id"`
	OK         bool            `json:"ok"`
	Result     json.RawMessage `json:"result"`
	Error      *RemoteError    `json:"error"`
}

type RemoteError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

func (e *RemoteError) Error() string {
	if e == nil {
		return "ec20d returned an unspecified error"
	}
	if e.Message == "" {
		return "ec20d: " + e.Code
	}
	return "ec20d " + e.Code + ": " + e.Message
}

func (c *Client) DiscoverPTY(ctx context.Context) (PTYSnapshot, error) {
	if c == nil || c.dial == nil || c.authenticate == nil || c.verifyPTY == nil {
		return PTYSnapshot{}, fmt.Errorf("ec20d client is not initialized")
	}
	if err := ctx.Err(); err != nil {
		return PTYSnapshot{}, err
	}

	conn, err := c.dial(ctx, "unix", c.socketPath)
	if err != nil {
		return PTYSnapshot{}, contextError(ctx, fmt.Errorf("connect to ec20d: %w", err))
	}
	defer conn.Close()
	if err := c.authenticate(conn, c.socketPath); err != nil {
		return PTYSnapshot{}, contextError(ctx, fmt.Errorf("authenticate ec20d endpoint: %w", err))
	}

	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return PTYSnapshot{}, contextError(ctx, fmt.Errorf("set ec20d deadline: %w", err))
		}
	}
	stopCancellation := context.AfterFunc(ctx, func() {
		_ = conn.SetDeadline(time.Now())
	})
	defer stopCancellation()

	reader := bufio.NewReaderSize(conn, 64*1024)
	hello := Hello{}
	if err := roundTrip(conn, reader, "hello-1", "system.hello", map[string]any{
		"client":         clientName,
		"client_version": clientVersion,
	}, &hello); err != nil {
		return PTYSnapshot{}, contextError(ctx, err)
	}
	if err := ctx.Err(); err != nil {
		return PTYSnapshot{}, err
	}
	if hello.Server != "ec20d" || hello.DaemonInstanceID == "" ||
		!contains(hello.Capabilities, "devices.list") {
		return PTYSnapshot{}, fmt.Errorf("ec20d handshake did not provide a valid devices.list epoch")
	}
	if !contains(hello.Capabilities, "at.pty") {
		return PTYSnapshot{}, fmt.Errorf("ec20d did not advertise at.pty")
	}

	snapshot := Snapshot{}
	if err := roundTrip(conn, reader, "list-2", "devices.list", map[string]any{}, &snapshot); err != nil {
		return PTYSnapshot{}, contextError(ctx, err)
	}
	if err := ctx.Err(); err != nil {
		return PTYSnapshot{}, err
	}
	devices, err := validatedPTYDevices(snapshot, hello.DaemonInstanceID, c.verifyPTY)
	if err != nil {
		return PTYSnapshot{}, err
	}
	return PTYSnapshot{
		Epoch:    hello.DaemonInstanceID,
		Revision: snapshot.Revision,
		Devices:  devices,
	}, nil
}

func roundTrip(conn net.Conn, reader *bufio.Reader, id, method string, params map[string]any, result any) error {
	record, err := json.Marshal(requestEnvelope{
		Schema:     Schema,
		APIVersion: APIVersion,
		ID:         id,
		Method:     method,
		Params:     params,
	})
	if err != nil {
		return fmt.Errorf("encode %s request: %w", method, err)
	}
	if len(record)+1 > maximumRecordBytes {
		return ErrRecordTooLarge
	}
	record = append(record, '\n')
	if err := writeAll(conn, record); err != nil {
		return fmt.Errorf("write %s request: %w", method, err)
	}

	wireResponse, err := readRecord(reader, maximumRecordBytes)
	if err != nil {
		return fmt.Errorf("read %s response: %w", method, err)
	}
	var response responseEnvelope
	if err := json.Unmarshal(wireResponse, &response); err != nil {
		return fmt.Errorf("decode %s response: %w", method, err)
	}
	responseMajor, responseVersionOK := apiMajor(response.APIVersion)
	supportedMajor, supportedVersionOK := apiMajor(APIVersion)
	if response.Schema != Schema || !responseVersionOK || !supportedVersionOK || responseMajor != supportedMajor {
		return ErrUnsupportedAPI
	}
	if response.ID != id {
		return fmt.Errorf("ec20d response id %q does not match request %q", response.ID, id)
	}
	if !response.OK {
		if response.Error == nil {
			return &RemoteError{Code: "unknown", Message: "missing error object"}
		}
		return response.Error
	}
	if response.Error != nil || len(response.Result) == 0 || bytes.Equal(response.Result, []byte("null")) {
		return fmt.Errorf("ec20d returned a malformed successful response")
	}
	if err := json.Unmarshal(response.Result, result); err != nil {
		return fmt.Errorf("decode %s result: %w", method, err)
	}
	return nil
}

func writeAll(writer io.Writer, payload []byte) error {
	for len(payload) != 0 {
		written, err := writer.Write(payload)
		if written > 0 {
			payload = payload[written:]
		}
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

func readRecord(reader *bufio.Reader, limit int) ([]byte, error) {
	var record []byte
	for {
		fragment, err := reader.ReadSlice('\n')
		if len(record)+len(fragment) > limit ||
			(len(record)+len(fragment) == limit && !bytes.HasSuffix(fragment, []byte{'\n'})) {
			return nil, ErrRecordTooLarge
		}
		record = append(record, fragment...)
		if err == nil {
			break
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return nil, err
	}
	if len(record) == 0 || record[len(record)-1] != '\n' {
		return nil, io.ErrUnexpectedEOF
	}
	record = record[:len(record)-1]
	if len(bytes.TrimSpace(record)) == 0 {
		return nil, fmt.Errorf("ec20d returned an empty record")
	}
	return record, nil
}

func apiMajor(version string) (uint64, bool) {
	components := strings.Split(version, ".")
	if len(components) != 2 || !unsignedDecimal(components[0]) || !unsignedDecimal(components[1]) {
		return 0, false
	}
	major, err := strconv.ParseUint(components[0], 10, 64)
	if err != nil {
		return 0, false
	}
	if _, err := strconv.ParseUint(components[1], 10, 64); err != nil {
		return 0, false
	}
	return major, true
}

func unsignedDecimal(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func contextError(ctx context.Context, fallback error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return fallback
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func validatedPTYDevices(snapshot Snapshot, epoch string, verifyPTY func(string) error) ([]PTYDevice, error) {
	if snapshot.Revision == 0 {
		return nil, fmt.Errorf("ec20d returned an invalid zero revision")
	}
	seenInstances := make(map[string]struct{}, len(snapshot.Devices))
	seenPaths := make(map[string]struct{}, len(snapshot.Devices))
	devices := make([]PTYDevice, 0, len(snapshot.Devices))
	for _, device := range snapshot.Devices {
		if device.AT.Transport != "pty" {
			continue
		}
		if device.InstanceID == "" || device.Generation == 0 {
			return nil, fmt.Errorf("ec20d returned a PTY with an invalid attach identity")
		}
		if _, duplicate := seenInstances[device.InstanceID]; duplicate {
			return nil, fmt.Errorf("ec20d returned duplicate instance id %q", device.InstanceID)
		}
		seenInstances[device.InstanceID] = struct{}{}
		if device.Identity.VendorID != 0x2c7c || device.Identity.ProductID != 0x0125 ||
			device.Identity.USBLocationID == "" ||
			device.USB.Configuration != 1 || device.USB.ATInterfaceNumber != 2 ||
			device.USB.NetworkInterfaceNumber != 4 || device.AT.InterfaceNumber != 2 {
			return nil, fmt.Errorf("ec20d PTY %q failed the EC20 interface safety contract", device.InstanceID)
		}
		if device.Lifecycle.State != "ready" || !device.AT.Available {
			continue
		}
		if device.AT.RPCDeviceID != nil || !contains(device.Capabilities, "management.at") {
			return nil, fmt.Errorf("ec20d PTY %q has an inconsistent transport capability", device.InstanceID)
		}
		if device.AT.Path == nil || !validPTYPath(*device.AT.Path) {
			return nil, fmt.Errorf("ec20d PTY %q has an unsafe device path", device.InstanceID)
		}
		if err := verifyPTY(*device.AT.Path); err != nil {
			return nil, fmt.Errorf("ec20d PTY %q failed endpoint authentication: %w", device.InstanceID, err)
		}
		if device.AT.Ownership != "cooperative_single_client" {
			return nil, fmt.Errorf("ec20d PTY %q has unsupported ownership %q", device.InstanceID, device.AT.Ownership)
		}
		if _, duplicate := seenPaths[*device.AT.Path]; duplicate {
			return nil, fmt.Errorf("ec20d returned duplicate PTY path %q", *device.AT.Path)
		}
		seenPaths[*device.AT.Path] = struct{}{}
		devices = append(devices, PTYDevice{
			InstanceID:    device.InstanceID,
			Generation:    device.Generation,
			AttachmentKey: attachmentKey(epoch, device),
			LocationID:    device.Identity.USBLocationID,
			RegistryID:    device.USB.RegistryID,
			Path:          *device.AT.Path,
			Ownership:     device.AT.Ownership,
		})
	}
	return devices, nil
}

func attachmentKey(epoch string, device Device) string {
	attachIdentity := device.InstanceID
	if device.USB.RegistryID != nil && strings.TrimSpace(*device.USB.RegistryID) != "" {
		attachIdentity = strings.TrimSpace(*device.USB.RegistryID)
	}
	payload := epoch + "\x00" + attachIdentity + "\x00" + strconv.FormatUint(device.Generation, 10)
	digest := sha256.Sum256([]byte(payload))
	return fmt.Sprintf("ec20d:%x", digest)
}

func validPTYPath(path string) bool {
	const prefix = "/dev/ttys"
	if !strings.HasPrefix(path, prefix) || len(path) == len(prefix) || filepath.Clean(path) != path {
		return false
	}
	for _, character := range path[len(prefix):] {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}
