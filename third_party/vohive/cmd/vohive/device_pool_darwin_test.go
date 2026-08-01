//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1239t/vohive/internal/config"
)

func TestEC20DSocketPathUsesEnvironment(t *testing.T) {
	want := filepath.Join(t.TempDir(), "custom-ec20d.sock")
	t.Setenv("EC20D_SOCKET", want)
	if got := ec20dSocketPath(); got != want {
		t.Fatalf("ec20dSocketPath()=%q, want %q", got, want)
	}
}

func TestEC20DSocketPathUsesTemporaryDirectory(t *testing.T) {
	t.Setenv("EC20D_SOCKET", "")
	want := filepath.Join(os.TempDir(), "ec20d.sock")
	if got := ec20dSocketPath(); got != want {
		t.Fatalf("ec20dSocketPath()=%q, want %q", got, want)
	}
}

func TestNewDevicePoolDarwinInjectsEC20DProvider(t *testing.T) {
	t.Setenv("EC20D_SOCKET", filepath.Join(t.TempDir(), "ec20d.sock"))
	pool, err := newDevicePool(&config.Config{})
	if err != nil {
		t.Fatalf("newDevicePool: %v", err)
	}
	t.Cleanup(func() { _ = pool.Shutdown() })
	if !pool.UsesHardwareProvider() {
		t.Fatal("Darwin device pool did not inject the ec20d hardware provider")
	}
}
