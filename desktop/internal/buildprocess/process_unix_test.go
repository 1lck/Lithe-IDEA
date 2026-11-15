//go:build !windows

package buildprocess

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// startHelper starts the helper in mode with grace as the stop time, waits for it to report
// that it started and returns it with its collected output. The stop time is restored when
// the test ends.
func startHelper(t *testing.T, ctx context.Context, mode string, grace time.Duration) (*Process, func() string) {
	t.Helper()
	previous := StopGrace()
	SetStopGrace(grace)
	t.Cleanup(func() { SetStopGrace(previous) })
	var mu sync.Mutex
	var output strings.Builder
	started := make(chan struct{})
	var once sync.Once
	process, err := Start(ctx, processSpec(t, mode), func(_ Stream, text string) {
		mu.Lock()
		output.WriteString(text)
		mu.Unlock()
		if strings.Contains(text, "started") {
			once.Do(func() { close(started) })
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		process.Kill()
		_ = process.Wait()
	})
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("the helper did not report that it started")
	}
	return process, func() string {
		mu.Lock()
		defer mu.Unlock()
		return output.String()
	}
}

// waitWithin waits for the process to end, failing the test when it is still running at
// the bound.
func waitWithin(t *testing.T, process *Process, bound time.Duration) error {
	t.Helper()
	wait := make(chan error, 1)
	go func() { wait <- process.Wait() }()
	select {
	case err := <-wait:
		return err
	case <-time.After(bound):
		t.Fatalf("the process was still running %v later", bound)
		return nil
	}
}

// TestProcessStopLetsTheTreeEndWithinItsGrace checks that Stop first asks: a program that
// handles the request saves its work and exits on its own, long before the grace ends.
func TestProcessStopLetsTheTreeEndWithinItsGrace(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	process, output := startHelper(t, ctx, "trap-term", 15*time.Second)
	process.Stop()
	if err := waitWithin(t, process, 10*time.Second); err != nil {
		t.Fatalf("the program that exited on its own reported %v", err)
	}
	if !strings.Contains(output(), "saved") {
		t.Fatalf("the program was not asked to stop: %q", output())
	}
}

// TestProcessStopKillsATreeThatOutlivesItsGrace checks that a program ignoring the request
// is killed once the grace has passed, and not before.
func TestProcessStopKillsATreeThatOutlivesItsGrace(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	grace := 300 * time.Millisecond
	process, _ := startHelper(t, ctx, "ignore-term", grace)
	stopped := time.Now()
	process.Stop()
	// A second Stop neither kills at once nor restarts the wait.
	process.Stop()
	if err := waitWithin(t, process, 10*time.Second); err == nil {
		t.Fatal("the killed program reported success")
	}
	if elapsed := time.Since(stopped); elapsed < grace {
		t.Fatalf("the program was killed after %v, before its grace of %v", elapsed, grace)
	}
}

// TestProcessKillEndsATreeInItsGrace checks that stopping a program a second time with Kill
// does not wait for the rest of its grace.
func TestProcessKillEndsATreeInItsGrace(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	process, _ := startHelper(t, ctx, "ignore-term", time.Minute)
	process.Stop()
	process.Kill()
	if err := waitWithin(t, process, 5*time.Second); err == nil {
		t.Fatal("the killed program reported success")
	}
}
