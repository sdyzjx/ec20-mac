package modem

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func installIMEIProbeTestDouble(t *testing.T, probe func(string, time.Duration) (string, error)) {
	t.Helper()

	imeiProbeMissMu.Lock()
	previousProbe := probeIMEIUncachedFn
	probeIMEIUncachedFn = probe
	imeiCache.mu.Lock()
	imeiCache.m = nil
	imeiCache.mu.Unlock()
	imeiProbeMissMu.Unlock()

	t.Cleanup(func() {
		imeiProbeMissMu.Lock()
		probeIMEIUncachedFn = previousProbe
		imeiCache.mu.Lock()
		imeiCache.m = nil
		imeiCache.mu.Unlock()
		imeiProbeMissMu.Unlock()
	})
}

func TestProbeIMEICachedForAttachmentSerializesAllCacheMisses(t *testing.T) {
	var inFlight atomic.Int32
	var maxInFlight atomic.Int32
	var calls atomic.Int32
	installIMEIProbeTestDouble(t, func(port string, _ time.Duration) (string, error) {
		calls.Add(1)
		current := inFlight.Add(1)
		for {
			maximum := maxInFlight.Load()
			if current <= maximum || maxInFlight.CompareAndSwap(maximum, current) {
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
		inFlight.Add(-1)
		return fmt.Sprintf("imei-%s", port), nil
	})

	const count = 8
	var wg sync.WaitGroup
	errors := make(chan error, count)
	for index := 0; index < count; index++ {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			_, err := ProbeIMEICachedForAttachment(
				fmt.Sprintf("attachment-%d", index),
				fmt.Sprintf("/dev/ttys%03d", index),
				time.Second,
			)
			errors <- err
		}(index)
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatalf("ProbeIMEICachedForAttachment: %v", err)
		}
	}
	if got := maxInFlight.Load(); got != 1 {
		t.Fatalf("maximum uncached probes in flight = %d, want 1", got)
	}
	if got := calls.Load(); got != count {
		t.Fatalf("uncached probe calls = %d, want %d", got, count)
	}
}

func TestProbeIMEICachedForAttachmentCoalescesConcurrentProbe(t *testing.T) {
	var calls atomic.Int32
	entered := make(chan struct{})
	release := make(chan struct{})
	installIMEIProbeTestDouble(t, func(string, time.Duration) (string, error) {
		if calls.Add(1) == 1 {
			close(entered)
		}
		<-release
		return "867383058993207", nil
	})

	const count = 12
	results := make(chan string, count)
	errors := make(chan error, count)
	var wg sync.WaitGroup
	for index := 0; index < count; index++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			imei, err := ProbeIMEICachedForAttachment("attachment-a", "/dev/ttys009", time.Second)
			results <- imei
			errors <- err
		}()
	}

	<-entered
	close(release)
	wg.Wait()
	close(results)
	close(errors)

	for err := range errors {
		if err != nil {
			t.Fatalf("ProbeIMEICachedForAttachment: %v", err)
		}
	}
	for imei := range results {
		if imei != "867383058993207" {
			t.Fatalf("IMEI = %q, want cached result", imei)
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("uncached probe calls = %d, want 1", got)
	}
}

func TestProbeIMEICachedForAttachmentDoesNotReuseAcrossAttachments(t *testing.T) {
	var calls atomic.Int32
	installIMEIProbeTestDouble(t, func(string, time.Duration) (string, error) {
		switch calls.Add(1) {
		case 1:
			return "111111111111111", nil
		case 2:
			return "222222222222222", nil
		default:
			return "unexpected-extra-probe", nil
		}
	})

	first, err := ProbeIMEICachedForAttachment("attachment-a", "/dev/ttys009", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ProbeIMEICachedForAttachment("attachment-b", "/dev/ttys009", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	firstAgain, err := ProbeIMEICachedForAttachment("attachment-a", "/dev/ttys009", time.Second)
	if err != nil {
		t.Fatal(err)
	}

	if first != "111111111111111" || second != "222222222222222" || firstAgain != first {
		t.Fatalf("unexpected attachment cache results: first=%q second=%q firstAgain=%q", first, second, firstAgain)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("uncached probe calls = %d, want 2", got)
	}
}

func TestProbeIMEICachedForAttachmentIncludesPortInCacheKey(t *testing.T) {
	var calls atomic.Int32
	installIMEIProbeTestDouble(t, func(port string, _ time.Duration) (string, error) {
		calls.Add(1)
		return "imei-for-" + port, nil
	})

	first, err := ProbeIMEICachedForAttachment("attachment-a", "/dev/ttys009", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ProbeIMEICachedForAttachment("attachment-a", "/dev/ttys010", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatalf("different ports shared one cache entry: %q", first)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("uncached probe calls = %d, want 2", got)
	}
}

func TestProbeIMEICachedForAttachmentRequiresAttachmentAndPort(t *testing.T) {
	var calls atomic.Int32
	installIMEIProbeTestDouble(t, func(string, time.Duration) (string, error) {
		calls.Add(1)
		return "867383058993207", nil
	})

	if _, err := ProbeIMEICachedForAttachment(" ", "/dev/ttys009", time.Second); err == nil {
		t.Fatal("empty attachment key unexpectedly accepted")
	}
	if _, err := ProbeIMEICachedForAttachment("attachment-a", " ", time.Second); err == nil {
		t.Fatal("empty AT port unexpectedly accepted")
	}
	if got := calls.Load(); got != 0 {
		t.Fatalf("uncached probe calls = %d, want 0", got)
	}
}

func TestProbeIMEICachedKeepsLegacyPortCacheBehavior(t *testing.T) {
	var calls atomic.Int32
	installIMEIProbeTestDouble(t, func(string, time.Duration) (string, error) {
		calls.Add(1)
		return "867383058993207", nil
	})

	first, err := ProbeIMEICached(" /dev/ttys009 ", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ProbeIMEICached("/dev/ttys009", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if first != "867383058993207" || second != first {
		t.Fatalf("legacy cached results = %q, %q", first, second)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("uncached probe calls = %d, want 1", got)
	}
}
