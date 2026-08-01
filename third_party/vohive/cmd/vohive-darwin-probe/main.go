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

	"github.com/1239t/vohive/internal/platform/ec20d"
)

const defaultTimeout = 3 * time.Second

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
	snapshot, err := client.DiscoverPTY(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "vohive-darwin-probe: %v\n", err)
		return 1
	}

	if *jsonOutput {
		encoder := json.NewEncoder(stdout)
		encoder.SetEscapeHTML(true)
		encoder.SetIndent("", "  ")
		if err := encoder.Encode(snapshot); err != nil {
			fmt.Fprintf(stderr, "vohive-darwin-probe: encode output: %v\n", err)
			return 1
		}
		return 0
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

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}
