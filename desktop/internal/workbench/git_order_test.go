package workbench

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// gitStatusGate controls the completion order without sleeping or depending on Git speed.
// Its embedded kernel still serves the real headless workbench's other requests.
type gitStatusGate struct {
	Kernel
	requests chan chan gitStatusAnswer
}
type gitStatusAnswer struct {
	status core.GitStatus
	err    error
}

func (k *gitStatusGate) GitStatus(ctx context.Context, _ string) (core.GitStatus, error) {
	answer := make(chan gitStatusAnswer, 1)
	select {
	case k.requests <- answer:
	case <-ctx.Done():
		return core.GitStatus{}, ctx.Err()
	}
	select {
	case got := <-answer:
		return got.status, got.err
	case <-ctx.Done():
		return core.GitStatus{}, ctx.Err()
	}
}
func (k *gitStatusGate) next(t *testing.T) chan gitStatusAnswer {
	t.Helper()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case answer := <-k.requests:
		return answer
	case <-timer.C:
		t.Fatal("Git status request did not start")
		return nil
	}
}
func gitOrderHarness(t *testing.T) (*harness, *gitStatusGate) {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	k := &gitStatusGate{Kernel: h.app.kernel, requests: make(chan chan gitStatusAnswer, 4)}
	h.app.kernel = k
	// Runs before harness cleanup, so assertion failures also release every pending read.
	t.Cleanup(h.app.project.cancel)
	return h, k
}
func gitOrderStatus(p *project, branch string, changes int) core.GitStatus {
	return core.GitStatus{RepositoryRoot: p.root, Branch: branch, Changes: make([]core.GitChange, changes)}
}
func assertGitOrder(t *testing.T, p *project, branch string, changes int) {
	t.Helper()
	count, ok := p.git.changeCount()
	if p.git.branch() != branch || count != changes || !ok {
		t.Fatalf("Git status = %q/%d (repository %v), want %q/%d", p.git.branch(), count, ok, branch, changes)
	}
}

func TestGitStatusLatestRequestWins(t *testing.T) {
	for _, staleError := range []bool{false, true} {
		name := "success"
		if staleError {
			name = "failure"
		}
		t.Run(name, func(t *testing.T) {
			h, k := gitOrderHarness(t)
			p := h.app.project
			h.app.loadGit(p)
			older := k.next(t)
			h.app.loadGit(p)
			newer := k.next(t)
			newer <- gitStatusAnswer{status: gitOrderStatus(p, "new", 2)}
			h.await("new status", func() bool { return p.git.branch() == "new" })
			answer := gitStatusAnswer{status: gitOrderStatus(p, "old", 1)}
			if staleError {
				answer.err = errors.New("old status failed")
			}
			older <- answer
			h.settle()
			assertGitOrder(t, p, "new", 2)
		})
	}
}

func TestGitStatusLatestFailureIsNotReplacedByOlderSuccess(t *testing.T) {
	h, k := gitOrderHarness(t)
	p := h.app.project
	h.app.loadGit(p)
	older := k.next(t)
	h.app.loadGit(p)
	newer := k.next(t)
	failure := errors.New("latest status failed")
	newer <- gitStatusAnswer{err: failure}
	h.await("latest failure", func() bool { return p.git.err == failure })
	older <- gitStatusAnswer{status: gitOrderStatus(p, "old", 1)}
	h.settle()
	if p.git.err != failure || !p.git.loaded {
		t.Fatalf("latest failure was replaced: %+v", p.git)
	}
}

func TestGitStatusOperationResultInvalidatesPendingRead(t *testing.T) {
	h, k := gitOrderHarness(t)
	p := h.app.project
	h.app.loadGit(p)
	older := k.next(t)
	// Branch writes and sync operations both publish through setGit.
	h.app.setGit(p, gitState{loaded: true, status: gitOrderStatus(p, "operation", 3)}, p.gitStatusGeneration.Add(1))
	older <- gitStatusAnswer{status: gitOrderStatus(p, "old", 1)}
	h.settle()
	assertGitOrder(t, p, "operation", 3)
}

func TestGitStatusBranchAndSyncInvalidatePendingRead(t *testing.T) {
	for _, operation := range []string{"branch", "sync"} {
		t.Run(operation, func(t *testing.T) {
			h, k := gitOrderHarness(t)
			p := h.app.project
			h.app.loadGit(p)
			older := k.next(t)
			if operation == "branch" {
				h.app.runBranchWrite(p, "branch_checkout", func(reason string) string { return reason },
					func(context.Context, Kernel, string) error { return nil }, func(*App, core.GitStatus) {})
			} else {
				h.app.runSyncAt(p, p.root, "git_fetch", "fetch", func(reason string) string { return reason },
					func(context.Context, Kernel, string) (func(*App), error) { return nil, nil })
			}
			afterWrite := k.next(t)
			afterWrite <- gitStatusAnswer{status: gitOrderStatus(p, "operation", 3)}
			h.await("operation status", func() bool { return p.git.branch() == "operation" })
			older <- gitStatusAnswer{status: gitOrderStatus(p, "old", 1)}
			h.settle()
			assertGitOrder(t, p, "operation", 3)
		})
	}
}

func TestGitStatusClosedProjectCannotOverwriteReopenedProject(t *testing.T) {
	h, k := gitOrderHarness(t)
	old := h.app.project
	root := old.root
	h.app.loadGit(old)
	pending := k.next(t)
	// Queue the successful result, but close the project before applying it.
	pending <- gitStatusAnswer{status: gitOrderStatus(old, "stale", 1)}
	h.app.wait()
	h.app.closeProject()
	h.await("closed project", func() bool { return h.app.project == nil })
	h.app.kernel = &testKernel{Client: core.NewClient(), status: core.GitStatus{RepositoryRoot: root, Branch: "reopened", Changes: make([]core.GitChange, 2)}}
	h.open(root)
	if h.app.project == old {
		t.Fatal("reopen reused closed project")
	}
	assertGitOrder(t, h.app.project, "reopened", 2)
}

func TestGitStatusNewReadAfterOperationReadWins(t *testing.T) {
	for _, operation := range []string{"branch", "sync"} {
		for _, latestFirst := range []bool{false, true} {
			order := "operation-first"
			if latestFirst {
				order = "latest-first"
			}
			t.Run(operation+"/"+order, func(t *testing.T) {
				h, k := gitOrderHarness(t)
				p := h.app.project
				if operation == "branch" {
					h.app.runBranchWrite(p, "branch_checkout", func(reason string) string { return reason }, func(context.Context, Kernel, string) error { return nil }, func(*App, core.GitStatus) {})
				} else {
					h.app.runSyncAt(p, p.root, "git_fetch", "fetch", func(reason string) string { return reason }, func(context.Context, Kernel, string) (func(*App), error) { return nil, nil })
				}
				operationRead := k.next(t)
				h.app.loadGit(p)
				latestRead := k.next(t)
				if latestFirst {
					latestRead <- gitStatusAnswer{status: gitOrderStatus(p, "latest", 4)}
					h.await("latest status", func() bool { return p.git.branch() == "latest" })
					operationRead <- gitStatusAnswer{status: gitOrderStatus(p, "old-operation", 1)}
				} else {
					operationRead <- gitStatusAnswer{status: gitOrderStatus(p, "old-operation", 1)}
					h.await("operation completion", func() bool { return !h.app.branch.busy && !p.log.sync.busy })
					latestRead <- gitStatusAnswer{status: gitOrderStatus(p, "latest", 4)}
				}
				h.settle()
				assertGitOrder(t, p, "latest", 4)
			})
		}
	}
}

func TestGitStatusNestedBranchReadDoesNotInvalidateProject(t *testing.T) {
	h, k := gitOrderHarness(t)
	p := h.app.project
	h.app.loadGit(p)
	projectRead := k.next(t)
	h.app.branch.repo = t.TempDir()
	h.app.runBranchWrite(p, "branch_checkout", func(reason string) string { return reason }, func(context.Context, Kernel, string) error { return nil }, func(*App, core.GitStatus) {})
	nestedRead := k.next(t)
	nestedRead <- gitStatusAnswer{status: core.GitStatus{RepositoryRoot: h.app.branch.repo, Branch: "nested"}}
	h.await("nested branch completion", func() bool { return !h.app.branch.busy })
	projectRead <- gitStatusAnswer{status: gitOrderStatus(p, "project", 2)}
	h.settle()
	assertGitOrder(t, p, "project", 2)
}

func TestGitStatusOperationReadFailureKeepsLastPublishedState(t *testing.T) {
	for _, operation := range []string{"branch", "sync"} {
		t.Run(operation, func(t *testing.T) {
			h, k := gitOrderHarness(t)
			p := h.app.project
			h.app.setGit(p, gitState{loaded: true, status: gitOrderStatus(p, "last-known", 2)}, p.gitStatusGeneration.Add(1))
			h.settle()
			h.app.loadGit(p)
			older := k.next(t)
			done := false
			if operation == "branch" {
				h.app.runBranchWrite(p, "branch_checkout", func(reason string) string { return reason }, func(context.Context, Kernel, string) error { return nil }, func(*App, core.GitStatus) { done = true })
			} else {
				h.app.runSyncAt(p, p.root, "git_fetch", "fetch", func(reason string) string { return reason }, func(context.Context, Kernel, string) (func(*App), error) { return func(*App) { done = true }, nil })
			}
			afterWrite := k.next(t)
			afterWrite <- gitStatusAnswer{err: errors.New("post-write status failed")}
			h.await("operation read failure", func() bool { return !h.app.branch.busy && !p.log.sync.busy })
			// Preserve the existing operation outcome: branch requires the status to finish;
			// sync's successful work still calls done even when its refresh failed.
			if done != (operation == "sync") {
				t.Fatalf("%s done=%v", operation, done)
			}
			older <- gitStatusAnswer{status: gitOrderStatus(p, "old", 1)}
			h.settle()
			assertGitOrder(t, p, "last-known", 2)
		})
	}
}
