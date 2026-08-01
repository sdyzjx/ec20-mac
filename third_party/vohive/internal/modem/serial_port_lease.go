package modem

import (
	"fmt"
	"path/filepath"
	"strings"
	"sync"
)

// serialPortLease is an in-process ownership boundary. It prevents Vohive's
// Manager, discovery probes, and one-shot AT clients from concurrently opening
// the same cooperative PTY. Cross-process ownership still belongs to the Host
// App/ec20d lifecycle and the operating system's serial open result.
type serialPortLease struct {
	key   string
	owner string
	once  sync.Once
}

var serialPortLeases struct {
	sync.Mutex
	owners map[string]string
}

func normalizeSerialPortLeaseKey(portPath string) (string, error) {
	portPath = strings.TrimSpace(portPath)
	if portPath == "" {
		return "", fmt.Errorf("serial port path is empty")
	}
	return filepath.Clean(portPath), nil
}

func acquireSerialPortLease(portPath, owner string) (*serialPortLease, error) {
	key, err := normalizeSerialPortLeaseKey(portPath)
	if err != nil {
		return nil, err
	}
	owner = strings.TrimSpace(owner)
	if owner == "" {
		return nil, fmt.Errorf("serial port lease owner is empty")
	}

	serialPortLeases.Lock()
	defer serialPortLeases.Unlock()
	if serialPortLeases.owners == nil {
		serialPortLeases.owners = make(map[string]string)
	}
	if current, occupied := serialPortLeases.owners[key]; occupied {
		return nil, fmt.Errorf("serial port %s is already leased by %s", key, current)
	}
	serialPortLeases.owners[key] = owner
	return &serialPortLease{key: key, owner: owner}, nil
}

func (lease *serialPortLease) Release() {
	if lease == nil {
		return
	}
	lease.once.Do(func() {
		serialPortLeases.Lock()
		if serialPortLeases.owners[lease.key] == lease.owner {
			delete(serialPortLeases.owners, lease.key)
		}
		serialPortLeases.Unlock()
	})
}
