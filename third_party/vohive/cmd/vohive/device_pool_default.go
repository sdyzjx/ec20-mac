//go:build !darwin

package main

import (
	"github.com/1239t/vohive/internal/config"
	"github.com/1239t/vohive/internal/device"
)

func newDevicePool(cfg *config.Config) (*device.Pool, error) {
	return device.NewPool(cfg), nil
}
