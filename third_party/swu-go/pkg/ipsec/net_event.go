package ipsec

// NetEvent describes a network signal observed by the socket transport.
// Linux additionally publishes PMTU and ICMP reachability events from its
// error queue; NAT port changes are portable and originate in the read loop.
type NetEvent struct {
	Type    NetEventType
	PMTU    uint32
	Reason  string
	OldPort int
	NewPort int
}

type NetEventType int

const (
	EventPathMTU NetEventType = iota
	EventNetworkDown
	EventNATPortChanged
)
