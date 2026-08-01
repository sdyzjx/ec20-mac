package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/1239t/vohive/internal/config"
	"github.com/1239t/vohive/internal/device"
	"github.com/gin-gonic/gin"
)

type apiHardwareProvider struct {
	snapshot device.HardwareSnapshot
	err      error
	calls    int
}

func (p *apiHardwareProvider) Snapshot(ctx context.Context) (device.HardwareSnapshot, error) {
	p.calls++
	if err := ctx.Err(); err != nil {
		return device.HardwareSnapshot{}, err
	}
	if p.err != nil {
		return device.HardwareSnapshot{}, p.err
	}
	return p.snapshot, nil
}

func TestHandleDeviceMgmtDiscoveredUsesPoolHardwareProvider(t *testing.T) {
	gin.SetMode(gin.TestMode)
	path := writeDeviceMgmtDiscoveryConfig(t, "server:\n  port: \":7575\"\ndevices: []")
	if err := config.InitGlobalManager(path); err != nil {
		t.Fatal(err)
	}
	provider := &apiHardwareProvider{snapshot: device.HardwareSnapshot{
		Epoch:    "daemon-epoch",
		Revision: 7,
		Modems: []device.CompatibleModem{{
			USBPath:        "ec20d:attach-a",
			VendorID:       0x2c7c,
			ProductID:      0x0125,
			DriverName:     "ec20d-pty",
			ATPorts:        []string{"/dev/ttys009"},
			ATPort:         "/dev/ttys009",
			Mode:           "at",
			TransportType:  "at",
			NetworkCapable: false,
		}},
	}}
	pool := device.NewPool(&config.Config{}, device.WithHardwareProvider(provider))

	recorder := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(recorder)
	ginContext.Request = httptest.NewRequest(http.MethodGet, "/api/devices/discovered", nil)
	(&Server{pool: pool, configPath: path}).handleDeviceMgmtDiscovered(ginContext)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response discoveredDevicesResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Devices) != 1 {
		t.Fatalf("devices=%#v", response.Devices)
	}
	got := response.Devices[0]
	if got.USBPath != "ec20d:attach-a" || got.ATPort != "/dev/ttys009" ||
		got.DriverName != "ec20d-pty" || got.VendorID != 0x2c7c || got.ProductID != 0x0125 ||
		got.NetworkCapable || got.Mode != "at" {
		t.Fatalf("unexpected provider device: %#v", got)
	}
	if provider.calls != 1 {
		t.Fatalf("provider calls=%d, want 1", provider.calls)
	}
}

func TestHandleDeviceMgmtDiscoveredProviderWithIMEIUsesAttachmentScopedEnrichment(t *testing.T) {
	gin.SetMode(gin.TestMode)
	path := writeDeviceMgmtDiscoveryConfig(t, "server:\n  port: \":7575\"\ndevices: []")
	if err := config.InitGlobalManager(path); err != nil {
		t.Fatal(err)
	}
	provider := &apiHardwareProvider{snapshot: device.HardwareSnapshot{
		Modems: []device.CompatibleModem{{
			USBPath:    "ec20d:attach-a",
			ATPort:     "/dev/ttys009",
			ATPorts:    []string{"/dev/ttys009"},
			DriverName: "ec20d-pty",
			Mode:       "at",
		}},
	}}
	pool := device.NewPool(&config.Config{}, device.WithHardwareProvider(provider))

	originalEnrich := enrichDiscoveredCompatibleModemFn
	t.Cleanup(func() { enrichDiscoveredCompatibleModemFn = originalEnrich })
	enrichCalls := 0
	var enrichedModem device.CompatibleModem
	var enrichedOptions device.CompatibleModemEnrichOptions
	enrichDiscoveredCompatibleModemFn = func(modem device.CompatibleModem, options device.CompatibleModemEnrichOptions) (device.CompatibleModem, string) {
		enrichCalls++
		enrichedModem = modem
		enrichedOptions = options
		modem.IMEI = "867123456789012"
		return modem, modem.IMEI
	}

	recorder := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(recorder)
	ginContext.Request = httptest.NewRequest(http.MethodGet, "/api/devices/discovered?with_imei=1", nil)
	(&Server{pool: pool, configPath: path}).handleDeviceMgmtDiscovered(ginContext)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response discoveredDevicesResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if enrichCalls != 1 || len(response.Devices) != 1 || response.Devices[0].IMEI != "867123456789012" {
		t.Fatalf("calls=%d response=%#v", enrichCalls, response)
	}
	if enrichedModem.USBPath != "ec20d:attach-a" || enrichedModem.ATPort != "/dev/ttys009" {
		t.Fatalf("enrichment lost attachment identity: %#v", enrichedModem)
	}
	if !enrichedOptions.EnableATProbe || enrichedOptions.ATProbeTimeout != 900*time.Millisecond || enrichedOptions.EnableQMIIMEIProbe {
		t.Fatalf("unexpected provider enrichment options: %#v", enrichedOptions)
	}
}

func TestHandleDeviceMgmtDiscoveredProviderEmptySnapshotIsAuthoritative(t *testing.T) {
	gin.SetMode(gin.TestMode)
	provider := &apiHardwareProvider{snapshot: device.HardwareSnapshot{
		Epoch:  "daemon-epoch",
		Modems: []device.CompatibleModem{},
	}}
	pool := device.NewPool(&config.Config{}, device.WithHardwareProvider(provider))

	recorder := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(recorder)
	ginContext.Request = httptest.NewRequest(http.MethodGet, "/api/devices/discovered", nil)
	(&Server{pool: pool}).handleDeviceMgmtDiscovered(ginContext)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		Devices []discoveredDevice `json:"devices"`
		Error   string             `json:"error"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Devices == nil || len(body.Devices) != 0 || body.Error != "" {
		t.Fatalf("authoritative empty response=%#v", body)
	}
}

func TestHandleDeviceMgmtDiscoveredReportsProviderFailure(t *testing.T) {
	gin.SetMode(gin.TestMode)
	provider := &apiHardwareProvider{err: errors.New("ec20d unavailable")}
	pool := device.NewPool(&config.Config{}, device.WithHardwareProvider(provider))

	recorder := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(recorder)
	ginContext.Request = httptest.NewRequest(http.MethodGet, "/api/devices/discovered", nil)
	(&Server{pool: pool}).handleDeviceMgmtDiscovered(ginContext)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503 body=%s", recorder.Code, recorder.Body.String())
	}
	if provider.calls != 1 {
		t.Fatalf("provider calls=%d, want 1", provider.calls)
	}
}

func TestHandleDeviceMgmtDiscoveredPropagatesRequestCancellationToProvider(t *testing.T) {
	gin.SetMode(gin.TestMode)
	provider := &apiHardwareProvider{}
	pool := device.NewPool(&config.Config{}, device.WithHardwareProvider(provider))

	request := httptest.NewRequest(http.MethodGet, "/api/devices/discovered", nil)
	ctx, cancel := context.WithCancel(request.Context())
	cancel()
	request = request.WithContext(ctx)
	recorder := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(recorder)
	ginContext.Request = request
	(&Server{pool: pool}).handleDeviceMgmtDiscovered(ginContext)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503", recorder.Code)
	}
	if provider.calls != 0 {
		t.Fatalf("provider calls=%d, want 0 for pre-canceled request", provider.calls)
	}
}
