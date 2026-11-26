package localshell

import (
	"sync"
	"testing"
	"testing/synctest"
	"time"
)

func TestClosingAtRecentLinuxPromptGivesJobsTimeToExec(t *testing.T) {
	for _, age := range []time.Duration{0, 60 * time.Millisecond, time.Second} {
		t.Run(age.String(), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				const grace = 100 * time.Millisecond
				var signaled time.Time
				shell := resizeTestShell(backend{
					promptToken: "test",
					hangup:      func() { signaled = time.Now() },
				})
				shell.space = sync.NewCond(&shell.mu)
				liveShells.Acquire()
				defer close(shell.done)
				shell.sawMark('B')
				time.Sleep(age)
				closedAt := time.Now()
				want := closedAt.Add(max(0, grace-age))
				shell.Close()
				if !time.Now().Equal(closedAt) {
					t.Fatal("Close blocked during the grace period")
				}
				time.Sleep(max(0, grace-age))
				synctest.Wait()
				if !signaled.Equal(want) {
					t.Fatalf("hangup at %v, want %v for prompt age %v", signaled, want, age)
				}
			})
		})
	}
}

func TestQueuedCommandDuringCloseWaitsForItsOwnPrompt(t *testing.T) {
	const ms = time.Millisecond
	for _, tc := range []struct {
		name    string
		prompts []time.Duration // measured from Close
		want    time.Duration
	}{
		{"command returns to prompt", []time.Duration{320 * ms}, 420 * ms},
		{"command never returns to prompt", nil, time.Second},
		{"successive prompts near deadline", []time.Duration{950 * ms, 1040 * ms}, 1100 * ms},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				signals := make(chan time.Time, 2)
				shell := resizeTestShell(backend{
					promptToken: "test",
					hangup:      func() { signals <- time.Now() },
					kill:        func() {},
				})
				shell.space = sync.NewCond(&shell.mu)
				liveShells.Acquire()
				defer close(shell.done)

				shell.sawMark('B')
				start := time.Now()
				shell.Close()
				time.Sleep(20 * ms)
				shell.sawMark('C')
				for _, at := range tc.prompts {
					time.Sleep(time.Until(start.Add(at)))
					shell.sawMark('B')
				}
				time.Sleep(time.Until(start.Add(tc.want)))
				synctest.Wait()
				if len(signals) != 1 {
					t.Fatalf("got %d hangups by %v, want one", len(signals), tc.want)
				}
				if got := (<-signals).Sub(start); got != tc.want {
					t.Fatalf("hangup after %v, want %v", got, tc.want)
				}
			})
		})
	}
}
