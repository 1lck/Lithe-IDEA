package core

import (
	"context"
	"os"
	"os/exec"
	"testing"
	"time"
)

// Integration: Go and Core both start child processes. A SIGCHLD handler lacking
// SA_ONSTACK can crash the entire process asynchronously rather than produce a
// normal test failure, so the flags are checked after real child exits.
func TestCoreChildProcessesKeepGoSignalStack(t *testing.T) {
	before, onstack := childSignalFlags()
	if before < 0 || before&onstack == 0 {
		t.Fatalf("initial SIGCHLD flags = %#x; SA_ONSTACK = %#x", before, onstack)
	}
	// Git invoked by both Go and Core; helpers enforce individual deadlines.
	requireGit(t)
	repo := newRepository(t)
	for range 8 {
		runGit(t, repo, "status", "--porcelain")
		if _, err := NewClient().GitStatus(testContext(t), repo); err != nil {
			t.Fatalf("Core Git status: %v", err)
		}
	}
	after, _ := childSignalFlags()
	if after < 0 || after&onstack == 0 {
		t.Fatalf("SIGCHLD flags changed from %#x to %#x without SA_ONSTACK %#x", before, after, onstack)
	}
}

func TestSignalGuardLeavesOtherSignalActionsUnchanged(t *testing.T) {
	const marker = "LITHE_TEST_SIGNAL_GUARD_CHILD"
	if os.Getenv(marker) == "1" {
		if result := testUnrelatedSignal(); result != 0 {
			t.Fatalf("unrelated signal disposition changed (probe %d)", result)
		}
		if result := testIgnoredChildSignal(); result != 0 {
			t.Fatalf("ignored SIGCHLD disposition changed (probe %d)", result)
		}
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSignalGuardLeavesOtherSignalActionsUnchanged$")
	command.Env = append(os.Environ(), marker+"=1")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("isolated signal action probe: %v\n%s", err, output)
	}
}
