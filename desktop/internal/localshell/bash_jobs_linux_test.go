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
	synctest.Test(t, func(t *testing.T) {
		signals := make(chan struct{}, 2)
		shell := resizeTestShell(backend{
			promptToken: "test",
			hangup:      func() { signals <- struct{}{} },
		})
		shell.space = sync.NewCond(&shell.mu)
		liveShells.Acquire()
		defer close(shell.done)
		shell.sawMark('B')
		shell.Close()
		synctest.Wait()
		time.Sleep(20 * time.Millisecond)
		shell.sawMark('C')
		time.Sleep(300 * time.Millisecond)
		synctest.Wait()
		if len(signals) != 0 {
			t.Fatal("sent a hangup while the next prompt hook was running")
		}
		shell.sawMark('B')
		time.Sleep(jobExecGrace - time.Millisecond)
		synctest.Wait()
		if len(signals) != 0 {
			t.Fatal("sent a hangup before the latest prompt's grace expired")
		}
		time.Sleep(time.Millisecond)
		synctest.Wait()
		if len(signals) != 1 {
			t.Fatalf("sent %d hangups after the latest prompt settled, want one", len(signals))
		}
	})
}
