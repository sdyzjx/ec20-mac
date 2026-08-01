package main

import (
	"context"
	"errors"
	"time"
)

func retryWithDelays(ctx context.Context, delays []time.Duration, operation func(attempt int) error) error {
	if operation == nil {
		return errors.New("retry operation is nil")
	}
	if len(delays) == 0 {
		return errors.New("retry delays are empty")
	}
	var lastErr error
	for index, delay := range delays {
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				return ctx.Err()
			case <-timer.C:
			}
		} else if err := ctx.Err(); err != nil {
			return err
		}
		lastErr = operation(index + 1)
		if lastErr == nil {
			return nil
		}
	}
	return lastErr
}
