package qmicore

import "strings"

type qmiControlDeviceHolder struct {
	PID     int
	Command string
}

type qmiControlDeviceHolders struct {
	Holders []qmiControlDeviceHolder
	Unknown bool
}

func (h qmiControlDeviceHolders) onlyQMIProxy() bool {
	if len(h.Holders) == 0 {
		return false
	}
	for _, holder := range h.Holders {
		command := strings.ToLower(strings.TrimSpace(holder.Command))
		if !strings.Contains(command, "qmi-proxy") {
			return false
		}
	}
	return true
}

var detectQMIControlDeviceHolders = detectQMIControlDeviceHoldersPlatform
