//go:build darwin

package device

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/1239t/vohive/internal/netprobe"
)

const ecmPublicProbeTimeout = 12 * time.Second

type ecmNetworkController struct {
	interfaceName string
}

func newECMNetworkController(interfaceName string) NetworkController {
	return &ecmNetworkController{interfaceName: strings.TrimSpace(interfaceName)}
}

func (c *ecmNetworkController) ExternallyManaged() bool { return true }

func (c *ecmNetworkController) Connect() error {
	if !c.IsConnected() {
		return fmt.Errorf("ECM interface %s is not active or has no usable address", c.interfaceName)
	}
	return nil
}

func (c *ecmNetworkController) Disconnect() error {
	return fmt.Errorf("ECM disconnect is firmware-managed and is not available through the Darwin data-plane controller")
}

func (c *ecmNetworkController) RotateIP() error {
	return fmt.Errorf("ECM IP rotation requires a modem PDP reconnect and is not implemented")
}

func (c *ecmNetworkController) IsConnected() bool {
	_, _, connected := c.privateAddresses()
	return connected
}

func (c *ecmNetworkController) GetPrivateIP() string {
	v4, _, _ := c.privateAddresses()
	return v4
}

func (c *ecmNetworkController) GetPrivateIPv6() string {
	_, v6, _ := c.privateAddresses()
	return v6
}

func (c *ecmNetworkController) GetPublicIPv4AndV6NoCache() (string, string) {
	if !c.IsConnected() {
		return "", ""
	}
	prober := netprobe.New(netprobe.Config{
		Interface: c.interfaceName,
		URLs: []string{
			"https://1.1.1.1/cdn-cgi/trace",
			"https://[2606:4700:4700::1111]/cdn-cgi/trace",
		},
		Timeout: ecmPublicProbeTimeout,
	})
	ctx, cancel := context.WithTimeout(context.Background(), ecmPublicProbeTimeout)
	defer cancel()
	type result struct {
		family netprobe.Family
		value  string
	}
	results := make(chan result, 2)
	for _, family := range []netprobe.Family{netprobe.FamilyV4, netprobe.FamilyV6} {
		go func(family netprobe.Family) {
			results <- result{family: family, value: prober.Probe(ctx, family)}
		}(family)
	}
	var v4, v6 string
	for range 2 {
		got := <-results
		if got.family == netprobe.FamilyV4 {
			v4 = got.value
		} else {
			v6 = got.value
		}
	}
	return v4, v6
}

func (c *ecmNetworkController) privateAddresses() (string, string, bool) {
	if c == nil || c.interfaceName == "" {
		return "", "", false
	}
	iface, err := net.InterfaceByName(c.interfaceName)
	if err != nil || iface.Index <= 0 || iface.Flags&net.FlagUp == 0 ||
		iface.Flags&net.FlagRunning == 0 {
		return "", "", false
	}
	addresses, err := iface.Addrs()
	if err != nil {
		return "", "", false
	}
	var v4, v6 string
	for _, address := range addresses {
		host := address.String()
		if slash := strings.LastIndexByte(host, '/'); slash >= 0 {
			host = host[:slash]
		}
		if zone := strings.LastIndexByte(host, '%'); zone >= 0 {
			host = host[:zone]
		}
		ip := net.ParseIP(host)
		if ip == nil || ip.IsLoopback() || ip.IsUnspecified() {
			continue
		}
		if ip4 := ip.To4(); ip4 != nil && v4 == "" {
			v4 = ip4.String()
		} else if ip.To4() == nil && !ip.IsLinkLocalUnicast() && v6 == "" {
			v6 = ip.String()
		}
	}
	return v4, v6, v4 != "" || v6 != ""
}
