//go:build !linux

package qmicore

import (
	"fmt"
	"runtime"
	"strings"
)

func detectQMIControlDeviceHoldersPlatform(controlDevice string) (qmiControlDeviceHolders, error) {
	if strings.TrimSpace(controlDevice) == "" {
		return qmiControlDeviceHolders{}, nil
	}
	return qmiControlDeviceHolders{Unknown: true},
		fmt.Errorf("QMI control-device holder detection is unsupported on %s", runtime.GOOS)
}
