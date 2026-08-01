//go:build !linux && !darwin

package modem

// Other supported serial platforms retain the previous open behavior without
// Linux process takeover. Their serial library decides whether the endpoint is
// available.
func (m *Manager) prepareSerialPortForOpen(string) error {
	return nil
}
