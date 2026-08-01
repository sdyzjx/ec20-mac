package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestRetryWithDelaysConverges(t *testing.T) {
	wantErr := errors.New("not ready")
	attempts := 0
	err := retryWithDelays(context.Background(), []time.Duration{0, 0, 0}, func(attempt int) error {
		attempts++
		if attempt < 3 {
			return wantErr
		}
		return nil
	})
	if err != nil {
		t.Fatalf("retryWithDelays() error = %v", err)
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}
}

func TestRetryWithDelaysReturnsLastError(t *testing.T) {
	wantErr := errors.New("still unavailable")
	err := retryWithDelays(context.Background(), []time.Duration{0, 0}, func(int) error {
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("retryWithDelays() error = %v, want %v", err, wantErr)
	}
}

func TestRetryWithDelaysHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	err := retryWithDelays(ctx, []time.Duration{time.Second}, func(int) error {
		called = true
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("retryWithDelays() error = %v, want context.Canceled", err)
	}
	if called {
		t.Fatal("operation called after cancellation")
	}
}

func TestRetryWithDelaysRejectsEmptySchedule(t *testing.T) {
	called := false
	err := retryWithDelays(context.Background(), nil, func(int) error {
		called = true
		return nil
	})
	if err == nil {
		t.Fatal("retryWithDelays() error = nil, want empty schedule error")
	}
	if called {
		t.Fatal("operation called with an empty schedule")
	}
}
