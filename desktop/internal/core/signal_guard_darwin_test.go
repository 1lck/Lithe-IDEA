package core

import (
	"context"
	"os"
	"os/exec"
	"testing"
	"time"
)

// Integration: the real Core Agent initializes Tokio's SIGCHLD handler, then
// Go starts more child processes. A handler lacking SA_ONSTACK can crash the
// entire process asynchronously rather than produce a normal test failure.
func TestCoreAgentKeepsGoChildSignalStack(t *testing.T) {
	before, onstack := childSignalFlags()
	if before < 0 || before&onstack == 0 {
		t.Fatalf("initial SIGCHLD flags = %#x; SA_ONSTACK = %#x", before, onstack)
	}
	session, _ := openAgentFixture(t)
	session.Close()
	after, _ := childSignalFlags()
	if after < 0 || after&onstack == 0 {
		t.Fatalf("Core Agent changed SIGCHLD flags from %#x to %#x without SA_ONSTACK %#x", before, after, onstack)
	}
	// Exercise actual child exits after the handler is installed, including Git
	// invoked by both Go and Core; helpers enforce individual deadlines.
	requireGit(t)
	repo := newRepository(t)
	for range 8 {
		runGit(t, repo, "status", "--porcelain")
		if _, err := NewClient().GitStatus(testContext(t), repo); err != nil {
			t.Fatalf("Core Git status after Agent startup: %v", err)
		}
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
