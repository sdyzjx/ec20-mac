package ec20d

// The protocol version is owned by the macOS companion service.  A client may
// accept newer minor API versions, but never a different schema major.
const (
	Schema     = "ec20.vohive/1"
	APIVersion = "1.0"
)

type Hello struct {
	Server           string   `json:"server"`
	ServerVersion    string   `json:"server_version"`
	DaemonInstanceID string   `json:"daemon_instance_id"`
	Capabilities     []string `json:"capabilities"`
}

type Snapshot struct {
	Revision uint64   `json:"revision"`
	Devices  []Device `json:"devices"`
}

// PTYSnapshot carries the daemon epoch as well as its revision.  Current ec20d
// revisions are not yet a complete hot-plug signal, so consumers must also
// compare the daemon epoch, attachment key and runtime path.
type PTYSnapshot struct {
	Epoch    string      `json:"epoch"`
	Revision uint64      `json:"revision"`
	Devices  []PTYDevice `json:"devices"`
}

type Device struct {
	InstanceID   string          `json:"instance_id"`
	Generation   uint64          `json:"generation"`
	StableID     *string         `json:"stable_id"`
	Identity     DeviceIdentity  `json:"identity"`
	Lifecycle    DeviceLifecycle `json:"lifecycle"`
	USB          USBTopology     `json:"usb"`
	AT           ATTransport     `json:"at"`
	Network      NetworkState    `json:"network"`
	Capabilities []string        `json:"capabilities"`
}

type DeviceIdentity struct {
	IMEI            *string `json:"imei"`
	USBSerialNumber *string `json:"usb_serial_number"`
	USBLocationID   string  `json:"usb_location_id"`
	VendorID        uint16  `json:"vendor_id"`
	ProductID       uint16  `json:"product_id"`
	VendorIDHex     string  `json:"vendor_id_hex"`
	ProductIDHex    string  `json:"product_id_hex"`
	Manufacturer    string  `json:"manufacturer"`
	Model           *string `json:"model"`
	Firmware        *string `json:"firmware"`
}

type DeviceLifecycle struct {
	State  string  `json:"state"`
	Reason *string `json:"reason"`
}

type USBTopology struct {
	Configuration          uint8   `json:"configuration"`
	ATInterfaceNumber      uint8   `json:"at_interface_number"`
	NetworkInterfaceNumber uint8   `json:"network_interface_number"`
	RegistryID             *string `json:"registry_id"`
}

type ATTransport struct {
	Transport       string  `json:"transport"`
	Path            *string `json:"path"`
	RPCDeviceID     *string `json:"rpc_device_id"`
	InterfaceNumber uint8   `json:"interface_number"`
	Ownership       string  `json:"ownership"`
	Available       bool    `json:"available"`
}

type NetworkState struct {
	Mode           string   `json:"mode"`
	DataPlane      *string  `json:"data_plane"`
	ControlPlane   string   `json:"control_plane"`
	InterfaceName  *string  `json:"interface_name"`
	InterfaceIndex *int     `json:"interface_index"`
	LinkState      string   `json:"link_state"`
	Addresses      []string `json:"addresses"`
	ManagedBy      *string  `json:"managed_by"`
}

// PTYDevice is the deliberately small surface consumed by the first Darwin
// DeviceProvider.  It excludes IMEI, firmware and other values that should not
// be printed by diagnostics or persisted as a runtime-path identity.
type PTYDevice struct {
	InstanceID    string  `json:"instance_id"`
	Generation    uint64  `json:"generation"`
	AttachmentKey string  `json:"attachment_key"`
	LocationID    string  `json:"location_id"`
	RegistryID    *string `json:"registry_id,omitempty"`
	Path          string  `json:"path"`
	Ownership     string  `json:"ownership"`
}
