package device

import "testing"

func TestIPHealthyAcceptsV6Only(t *testing.T) {
	if !ipHealthy("", "2001:db8::1") {
		t.Fatal("v6-only should be considered healthy when v6 is present")
	}
}

func TestIPHealthyRejectsMissingAddresses(t *testing.T) {
	if ipHealthy(" ", "\t") {
		t.Fatal("blank v4/v6 should be considered unhealthy")
	}
}

func TestPublicIPHealthyForVersionRequiresRequestedFamily(t *testing.T) {
	tests := []struct {
		name      string
		v4        string
		v6        string
		version   string
		wantReady bool
	}{
		{name: "v4 ready", v4: "203.0.113.1", version: "v4", wantReady: true},
		{name: "v4 rejects v6 only", v6: "2001:db8::1", version: "v4", wantReady: false},
		{name: "v6 ready", v6: "2001:db8::1", version: "v6", wantReady: true},
		{name: "dual requires both", v4: "203.0.113.1", version: "v4v6", wantReady: false},
		{name: "dual ready", v4: "203.0.113.1", v6: "2001:db8::1", version: "v4v6", wantReady: true},
		{name: "default is v4", v4: "203.0.113.1", wantReady: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := publicIPHealthyForVersion(tt.v4, tt.v6, tt.version); got != tt.wantReady {
				t.Fatalf("publicIPHealthyForVersion(%q, %q, %q) = %v, want %v", tt.v4, tt.v6, tt.version, got, tt.wantReady)
			}
		})
	}
}
