package modem

import (
	"testing"
)

func TestIsRetryableSerialOpenErr(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{name: "busy", err: assertErr("device or resource busy"), want: true},
		{name: "temp unavailable", err: assertErr("temporarily unavailable"), want: true},
		{name: "permission", err: assertErr("permission denied"), want: false},
		{name: "nil", err: nil, want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isRetryableSerialOpenErr(tc.err)
			if got != tc.want {
				t.Fatalf("isRetryableSerialOpenErr(%v)=%v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

type assertErr string

func (e assertErr) Error() string { return string(e) }
