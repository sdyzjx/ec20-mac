//go:build !linux

package ipsec

// Linux MSG_ERRQUEUE has no portable socket equivalent. Non-Linux builds do
// not publish the optional PMTU/ICMP reachability events; callers must rely on
// their normal I/O and liveness failure paths.
func (s *SocketManager) startErrorListener() {}
