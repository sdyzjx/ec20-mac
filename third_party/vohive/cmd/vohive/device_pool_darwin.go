//go:build darwin

package main

import (
	"os"
	"path/filepath"

	"github.com/1239t/vohive/internal/config"
	"github.com/1239t/vohive/internal/device"
	"github.com/1239t/vohive/internal/platform/ec20d"
)

func newDevicePool(cfg *config.Config) (*device.Pool, error) {
	socketPath := ec20dSocketPath()
	client, err := ec20d.NewClient(socketPath)
	if err != nil {
		return nil, err
	}
	provider, err := device.NewEC20DHardwareProvider(client)
	if err != nil {
		return nil, err
	}
	return device.NewPool(cfg, device.WithHardwareProvider(provider)), nil
}

func ec20dSocketPath() string {
	socketPath := os.Getenv("EC20D_SOCKET")
	if socketPath == "" {
		socketPath = filepath.Join(os.TempDir(), "ec20d.sock")
	}
	return socketPath
}
