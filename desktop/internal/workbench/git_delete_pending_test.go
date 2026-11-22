package workbench

import (
	"context"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// pendingGitDeletion holds a write until the test has sent real input to the workbench.
type pendingGitDeletion struct {
	Kernel
	started chan struct{}
	release chan struct{}
}

func (k *pendingGitDeletion) wait(ctx context.Context) error {
	close(k.started)
	select {
	case <-k.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (k *pendingGitDeletion) GitDeleteRemoteBranch(ctx context.Context, root string, ref core.GitReference) error {
	if err := k.wait(ctx); err != nil {
		return err
	}
	return k.Kernel.GitDeleteRemoteBranch(ctx, root, ref)
}

func (k *pendingGitDeletion) GitRemoveWorktree(ctx context.Context, root, path string, force bool) error {
	if err := k.wait(ctx); err != nil {
		return err
	}
	return k.Kernel.GitRemoveWorktree(ctx, root, path, force)
}

func startPendingGitDeletion(t *testing.T, h *harness, confirm string) *pendingGitDeletion {
	t.Helper()
	k := &pendingGitDeletion{Kernel: h.app.kernel, started: make(chan struct{}), release: make(chan struct{})}
	h.app.kernel = k
	t.Cleanup(h.app.project.cancel)
	clickDuringGitDeletion(t, h, center(h.popupHit(confirm)))
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	select {
	case <-k.started:
	case <-deadline.C:
		t.Fatal("the Git deletion did not start")
	}
	return k
}

func clickDuringGitDeletion(t *testing.T, h *harness, point gfx.Point) {
	t.Helper()
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
}

func assertProjectCanToggleDuringGitDeletion(t *testing.T, h *harness) {
	t.Helper()
	before := h.app.chrome.isOpen(catalogIndex[itemProject])
	clickDuringGitDeletion(t, h, center(h.button(itemProject)))
	if h.app.chrome.isOpen(catalogIndex[itemProject]) == before {
		t.Error("the Project button did not respond to the first click while Git was running")
	}
}

func TestGitDeletionKeepsWorkbenchInteractive(t *testing.T) {
	t.Run("remote branch", func(t *testing.T) {
		h, _, dir, other := branchDeleteFixture(t)
		h.publishBranch(t, dir, other, "delete-in-background")
		h.logRefMenu("origin/delete-in-background")
		h.click(center(h.popupHit(h.app.text.Branch.Delete)))
		k := startPendingGitDeletion(t, h, h.app.text.Branch.DeleteButton)

		if h.app.branch.dialog != branchDialogNone || !h.app.branch.busy {
			t.Error("the confirmation must close while the branch deletion is still busy")
		}
		assertProjectCanToggleDuringGitDeletion(t, h)
		close(k.release)
		h.await("remote branch deletion", func() bool { return !h.app.branch.busy })
		if remoteHeads(t, dir, "delete-in-background") != "" {
			t.Fatal("the remote branch was not deleted")
		}
	})

	t.Run("worktree", func(t *testing.T) {
		dir, linked := newWorktreeRepository(t)
		h := newHarness(t, gitKernel{core.NewClient()})
		w := h.openWorktrees(t, dir)
		h.selectWorktreeAt(t, linked)
		h.clickNamed(h.app.text.Worktrees.Remove)
		k := startPendingGitDeletion(t, h, h.app.text.Worktrees.RemoveButton)

		if w.dialog != worktreeDialogNone || !w.busy {
			t.Error("the confirmation must close while the worktree removal is still busy")
		}
		assertProjectCanToggleDuringGitDeletion(t, h)
		close(k.release)
		h.awaitWorktreeWrite("worktree removal", w, func() bool { return len(w.list) == 1 })
	})
}

func TestGitDeletionFailureLeavesNewBranchDialogOpen(t *testing.T) {
	h, _, dir, other := branchDeleteFixture(t)
	h.publishBranch(t, dir, other, "protected")
	bare := gitRun(t, dir, "remote", "get-url", "origin")
	gitRun(t, bare, "config", "receive.denyDeletes", "true")
	h.logRefMenu("origin/protected")
	h.click(center(h.popupHit(h.app.text.Branch.Delete)))
	k := startPendingGitDeletion(t, h, h.app.text.Branch.DeleteButton)

	clickDuringGitDeletion(t, h, center(h.popupHit(h.app.text.Git.NewBranch)))
	if h.app.branch.dialog != branchDialogCreate {
		t.Fatal("the New Branch dialog did not open while the deletion was running")
	}
	h.app.branch.name.SetText("new-draft")
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if got := h.app.branch.name.Text(); got != "new-draft" {
		t.Fatalf("branch draft before deletion completed = %q, want new-draft", got)
	}
	close(k.release)
	h.await("the failed deletion", func() bool { return !h.app.branch.busy })

	if h.app.branch.dialog != branchDialogCreate || h.app.branch.name.Text() != "new-draft" {
		t.Fatalf("after deletion failed: dialog %v, draft %q", h.app.branch.dialog, h.app.branch.name.Text())
	}
	if entries := h.app.notifications.list; len(entries) == 0 || entries[0].kind != ui.ToastError {
		t.Fatalf("the failed deletion did not report an error, last notice = %q", lastNotice(h))
	}
}
