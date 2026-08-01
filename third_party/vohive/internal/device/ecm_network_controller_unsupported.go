//go:build !darwin

package device

func newECMNetworkController(string) NetworkController { return nil }
