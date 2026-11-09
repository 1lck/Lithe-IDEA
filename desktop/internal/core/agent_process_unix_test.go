//go:build !windows

package core

import (
	"errors"
	"syscall"
	"testing"
	"time"
)

func assertAgentFixtureStopped(t *testing.T, pid int) {
	t.Helper()
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		err := syscall.Kill(pid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		if err != nil && !errors.Is(err, syscall.EPERM) {
			t.Fatalf("check fixture process: %v", err)
		}
		select {
		case <-deadline.C:
			t.Fatalf("fixture process %d remains after session close", pid)
		case <-tick.C:
		}
	}
}
