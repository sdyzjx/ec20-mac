package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultSocketPathUsesEnvironment(t *testing.T) {
	t.Setenv("EC20D_SOCKET", "/tmp/custom-ec20d.sock")
	if got := defaultSocketPath(); got != "/tmp/custom-ec20d.sock" {
		t.Fatalf("defaultSocketPath()=%q", got)
	}
}

func TestDefaultSocketPathUsesTemporaryDirectory(t *testing.T) {
	t.Setenv("EC20D_SOCKET", "")
	if got, want := defaultSocketPath(), filepath.Join(os.TempDir(), "ec20d.sock"); got != want {
		t.Fatalf("defaultSocketPath()=%q, want %q", got, want)
	}
}
