//go:build linux

package netbind

import "testing"

func loopbackInterfaceName(*testing.T) string { return "lo" }
