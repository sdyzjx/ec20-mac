package netbind

import (
	"errors"
	"strings"
	"syscall"
	"testing"
)

type fakeRawConn struct {
	fd         uintptr
	controlErr error
	called     bool
}

func (f *fakeRawConn) Control(callback func(uintptr)) error {
	f.called = true
	if f.controlErr == nil {
		callback(f.fd)
	}
	return f.controlErr
}

func (*fakeRawConn) Read(func(uintptr) bool) error  { return nil }
func (*fakeRawConn) Write(func(uintptr) bool) error { return nil }

func TestControlEmptyInterfaceDoesNotInstallCallback(t *testing.T) {
	if control := Control("  "); control != nil {
		t.Fatal("Control installed a callback for an empty interface")
	}
}

func TestControlPropagatesRawConnectionFailure(t *testing.T) {
	control := Control(loopbackInterfaceName(t))
	want := errors.New("test raw control failure")
	raw := &fakeRawConn{controlErr: want}
	err := control("tcp4", "127.0.0.1:9", raw)
	if !errors.Is(err, want) || !raw.called {
		t.Fatalf("Control error=%v called=%v", err, raw.called)
	}
}

func TestControlRejectsUnknownInterface(t *testing.T) {
	control := Control("vohive-interface-that-does-not-exist")
	err := control("tcp4", "127.0.0.1:9", &fakeRawConn{})
	if err == nil || !strings.Contains(err.Error(), "interface") {
		t.Fatalf("Control error=%v, want interface lookup/bind failure", err)
	}
}

func TestControlRejectsNilRawConnection(t *testing.T) {
	control := Control(loopbackInterfaceName(t))
	if err := control("tcp4", "127.0.0.1:9", nil); err == nil {
		t.Fatal("Control accepted a nil RawConn")
	}
}

var _ syscall.RawConn = (*fakeRawConn)(nil)
