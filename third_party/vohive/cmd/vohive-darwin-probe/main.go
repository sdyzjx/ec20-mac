// vohive-darwin-probe is a read-only bring-up tool for the macOS DeviceProvider.
// It consumes ec20d metadata only; it never opens the returned PTY or sends AT.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/1239t/vohive/internal/device"
	"github.com/1239t/vohive/internal/platform/ec20d"
)

const defaultTimeout = 3 * time.Second

type poolDiagnosticSnapshot struct {
	Epoch    string                 `json:"epoch"`
	Revision uint64                 `json:"revision"`
	Devices  []poolDiagnosticDevice `json:"devices"`
}

type poolDiagnosticDevice struct {
	AttachmentKey  string `json:"attachment_key"`
	VendorIDHex    string `json:"vendor_id_hex"`
	ProductIDHex   string `json:"product_id_hex"`
	DriverName     string `json:"driver_name"`
	Path           string `json:"path"`
	Mode           string `json:"mode"`
	NetworkCapable bool   `json:"network_capable"`
}

func defaultSocketPath() string {
	if configured := os.Getenv("EC20D_SOCKET"); configured != "" {
		return configured
	}
	return filepath.Join(os.TempDir(), "ec20d.sock")
}

func run(arguments []string, stdout, stderr *os.File) int {
	flags := flag.NewFlagSet("vohive-darwin-probe", flag.ContinueOnError)
	flags.SetOutput(stderr)
	socketPath := flags.String("socket", defaultSocketPath(), "absolute ec20d Unix socket path")
	jsonOutput := flags.Bool("json", false, "print the minimized, non-sensitive PTY snapshot as JSON")
	poolMode := flags.Bool("pool", false, "also exercise the Vohive HardwareProvider and Pool mapping")
	timeout := flags.Duration("timeout", defaultTimeout, "overall discovery deadline")
	if err := flags.Parse(arguments); err != nil {
		return 64
	}
	if flags.NArg() != 0 || *timeout <= 0 {
		flags.Usage()
		return 64
	}

	client, err := ec20d.NewClient(*socketPath)
	if err != nil {
		fmt.Fprintf(stderr, "vohive-darwin-probe: %v\n", err)
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	if *poolMode {
		provider, err := device.NewEC20DHardwareProvider(client)
		if err != nil {
			fmt.Fprintf(stderr, "vohive-darwin-probe: %v\n", err)
			return 1
		}
		pool := device.NewPool(nil, device.WithHardwareProvider(provider))
		snapshot, err := pool.DiscoverHardware(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "vohive-darwin-probe: %v\n", err)
			return 1
		}
		diagnostic := newPoolDiagnosticSnapshot(snapshot)
		if *jsonOutput {
			return encodeJSON(diagnostic, stdout, stderr)
		}
		fmt.Fprintf(stdout, "vohive Darwin pool: %d device(s)\n", len(diagnostic.Devices))
		for _, modem := range diagnostic.Devices {
			fmt.Fprintf(stdout, "attachment=%s at=%s driver=%s mode=%s network=%t\n",
				modem.AttachmentKey, modem.Path, modem.DriverName, modem.Mode, modem.NetworkCapable)
		}
		return 0
	}

	snapshot, err := client.DiscoverPTY(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "vohive-darwin-probe: %v\n", err)
		return 1
	}

	if *jsonOutput {
		return encodeJSON(snapshot, stdout, stderr)
	}

	fmt.Fprintf(stdout, "vohive Darwin provider: %d PTY device(s)\n", len(snapshot.Devices))
	for _, device := range snapshot.Devices {
		fmt.Fprintf(stdout,
			"instance=%s generation=%d location=%s at=%s ownership=%s\n",
			device.InstanceID,
			device.Generation,
			device.LocationID,
			device.Path,
			device.Ownership)
	}
	return 0
}

func encodeJSON(value any, stdout, stderr *os.File) int {
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(true)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		fmt.Fprintf(stderr, "vohive-darwin-probe: encode output: %v\n", err)
		return 1
	}
	return 0
}

func newPoolDiagnosticSnapshot(snapshot device.HardwareSnapshot) poolDiagnosticSnapshot {
	diagnostic := poolDiagnosticSnapshot{
		Epoch:    snapshot.Epoch,
		Revision: snapshot.Revision,
		Devices:  make([]poolDiagnosticDevice, len(snapshot.Modems)),
	}
	for index, modem := range snapshot.Modems {
		diagnostic.Devices[index] = poolDiagnosticDevice{
			AttachmentKey:  modem.USBPath,
			VendorIDHex:    fmt.Sprintf("%04x", modem.VendorID),
			ProductIDHex:   fmt.Sprintf("%04x", modem.ProductID),
			DriverName:     modem.DriverName,
			Path:           modem.ATPort,
			Mode:           modem.Mode,
			NetworkCapable: modem.NetworkCapable,
		}
	}
	return diagnostic
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}
