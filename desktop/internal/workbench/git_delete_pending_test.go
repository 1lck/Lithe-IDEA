package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	k.awaitStart(t)
	return k
}

func (k *pendingGitDeletion) awaitStart(t *testing.T) {
	t.Helper()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	select {
	case <-k.started:
	case <-deadline.C:
		t.Fatal("the Git deletion did not start")
	}
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

// The embedded client preserves the optional repository discovery and selection interfaces.
type pendingLocalBranchDelete struct {
	*gitKernel
	gate *pendingGitDeletion
}

func (k *pendingLocalBranchDelete) GitDeleteBranch(ctx context.Context, root string, ref core.GitReference) (core.GitBranchDeletion, error) {
	if err := k.gate.wait(ctx); err != nil {
		return core.GitBranchDeletion{}, err
	}
	return k.gitKernel.GitDeleteBranch(ctx, root, ref)
}

func TestGitDeletionReviewNamesOriginalRepositoryAfterLogSwitch(t *testing.T) {
	parent := newWorkspaceFolder(t, "alpha", "beta")
	alpha, beta := filepath.Join(parent, "alpha"), filepath.Join(parent, "beta")
	makeUnmergedBranch(t, alpha, "backup")
	makeUnmergedBranch(t, beta, "backup")
	gate := &pendingGitDeletion{started: make(chan struct{}), release: make(chan struct{})}
	h := newHarness(t, &pendingLocalBranchDelete{gitKernel: &gitKernel{core.NewClient()}, gate: gate})
	p := h.openWorkspaceFolder(parent)
	alphaID, betaID := repositoryID(t, p, "alpha"), repositoryID(t, p, "beta")
	alphaRepo, ok := p.nested.repo(alphaID)
	if !ok {
		t.Fatal("the alpha repository was not discovered")
	}
	h.app.layout.gitTab = gitTabLog
	if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		h.click(center(h.button(itemGit)))
	}
	h.settleUntil("alpha's backup and beta's references", func() bool {
		_, backup := p.log.findReference("refs/heads/backup")
		_, read := p.nested.references[betaID]
		return p.logRepoID() == alphaID && !p.log.loading && backup && read
	})
	h.settle()
	h.logRefMenu("backup")
	h.click(center(h.popupHit(h.app.text.Branch.Delete)))
	t.Cleanup(p.cancel)
	clickDuringGitDeletion(t, h, center(h.popupHit(h.app.text.Branch.DeleteButton)))
	gate.awaitStart(t)

	v := &h.app.logView
	row := slices.IndexFunc(v.refItems, func(r logRefRow) bool {
		return r.kind == logRefForeign && r.repo == betaID && r.short == "backup"
	})
	if row < 0 {
		t.Fatal("beta backup is not listed")
	}
	clickDuringGitDeletion(t, h, center(h.topHit(v.refs.RowID(row))))
	h.await("beta's log", func() bool { return p.logRepoID() == betaID && !p.log.loading })
	close(gate.release)
	h.await("ordinary deletion result", func() bool { return !h.app.branch.busy })
	if h.app.branch.dialog != branchDialogNone {
		t.Fatal("alpha's result opened a dialog over beta's log")
	}
	openGitDeletionNotice(t, h)
	lang := h.app.language()
	h.clickNamed(i18n.Shared(lang, "desktop.branch.reviewForceDelete"))
	name := i18n.SharedFormat(lang, "desktop.branch.deleteRepository", map[string]string{"repository": "alpha"})
	var pathOnConfirmation bool
	for _, hit := range h.driver.Snapshot().Hits {
		pathOnConfirmation = pathOnConfirmation || hit.Label == alphaRepo.root
	}
	if h.app.branch.dialog != branchDialogForceDelete || !h.shows(name) || !pathOnConfirmation || p.logRepoID() != betaID {
		t.Fatal("force confirmation should identify alpha by name and full path without changing beta's log")
	}
	if gitRun(t, alpha, "branch", "--list", "backup") == "" {
		t.Fatal("opening the review deleted alpha's branch")
	}
	h.clickNamed(i18n.Shared(lang, "desktop.branch.forceDelete"))
	h.await("forced deletion", func() bool { return !h.app.branch.busy })
	if gitRun(t, alpha, "branch", "--list", "backup") != "" || gitRun(t, beta, "branch", "--list", "backup") == "" {
		t.Fatal("force deletion did not affect exactly the reviewed branch in alpha")
	}
}

func TestGitDeletionMixedResultsCanBeOpenedAfterBranchDraft(t *testing.T) {
	h, p, dir, other := branchDeleteFixture(t)
	makeUnmergedBranch(t, dir, "unmerged")
	gitRun(t, dir, "branch", "merged")
	h.publishBranch(t, dir, other, "protected")
	bare := gitRun(t, dir, "remote", "get-url", "origin")
	gitRun(t, bare, "config", "receive.denyDeletes", "true")
	h.clickLogRef("merged")
	h.markLogRefs("unmerged", "origin/protected")
	h.clickNamed(h.app.text.Git.DeleteBranch)
	k := startPendingGitDeletion(t, h, h.app.text.Branch.DeleteButton)

	openBranchDraftDuringGitDeletion(t, h)
	close(k.release)
	h.await("mixed deletion result", func() bool { return !h.app.branch.busy && !p.log.loading })
	finishBranchDraftAfterGitDeletion(t, h)

	openGitDeletionNotice(t, h)
	lang := h.app.language()
	if h.app.branch.dialog != branchDialogDeleteUnmerged ||
		!h.shows("merged") || !h.shows("unmerged") || !h.shows("origin/protected") ||
		!h.shows(i18n.Shared(lang, "desktop.branch.deleteResultUnmerged")) ||
		!h.shows(i18n.Shared(lang, "desktop.branch.deleteResultFailed")) {
		t.Fatal("the notice did not recover all branch outcomes and the force review")
	}
}

func TestGitDeletionWorktreeReviewWaitsForBranchDraft(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	k, w := startDirtyWorktreeRemovalWithBranchDraft(t, h, dir, linked)

	close(k.release)
	h.await("worktree refusal", func() bool { return !w.busy })
	if w.dialog != worktreeDialogNone {
		t.Fatal("the worktree review opened over the branch draft")
	}
	finishBranchDraftAfterGitDeletion(t, h)

	// Restore the real client before the explicitly confirmed force operation.
	h.app.kernel = k.Kernel
	openGitDeletionNotice(t, h)
	if w.dialog != worktreeDialogReview || w.target.Path != linked {
		t.Fatal("the notice did not recover the review for the original worktree")
	}
	h.clickNamed(h.app.text.Worktrees.ReviewForce)
	if w.dialog != worktreeDialogForce {
		t.Fatal("review must still lead to a separate force confirmation")
	}
	h.clickNamed(h.app.text.Worktrees.ForceButton)
	h.awaitWorktreeWrite("confirmed worktree removal", w, func() bool { return len(w.list) == 1 })
}

func startDirtyWorktreeRemovalWithBranchDraft(t *testing.T, h *harness, dir, linked string) (*pendingGitDeletion, *worktreeState) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(linked, "draft.txt"), []byte("draft\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	w := h.openWorktrees(t, dir)
	h.selectWorktreeAt(t, linked)
	h.clickNamed(h.app.text.Worktrees.Remove)
	k := startPendingGitDeletion(t, h, h.app.text.Worktrees.RemoveButton)
	p := h.app.project
	clickDuringGitDeletion(t, h, center(h.hitLabeled(h.app.text.Git.Log)))
	h.await("Git Log", func() bool { return h.app.layout.gitTab == gitTabLog && p.log.started && !p.log.loading })
	openBranchDraftDuringGitDeletion(t, h)

	return k, w
}

func openBranchDraftDuringGitDeletion(t *testing.T, h *harness) {
	t.Helper()
	clickDuringGitDeletion(t, h, center(h.popupHit(h.app.text.Git.NewBranch)))
	if h.app.branch.dialog != branchDialogCreate {
		t.Fatal("the new branch dialog did not open while deletion was running")
	}
	h.app.branch.name.SetText("new-draft")
}

func finishBranchDraftAfterGitDeletion(t *testing.T, h *harness) {
	t.Helper()
	if h.app.branch.dialog != branchDialogCreate || h.app.branch.name.Text() != "new-draft" {
		t.Fatal("the result interrupted the branch draft")
	}
	h.clickNamed(h.app.text.Branch.Cancel)
}

func openGitDeletionNotice(t *testing.T, h *harness) {
	t.Helper()
	entries := h.app.notifications.list
	if len(entries) == 0 || entries[0].act == nil {
		t.Fatal("the deletion result has no review action")
	}
	h.clickNamed(entries[0].actLabel)
}

func TestGitDeletionDoesNotForceRemoveReplacementWorktree(t *testing.T) {
	for _, stage := range []string{"before-reopening", "before-confirming"} {
		t.Run(stage, func(t *testing.T) {
			dir, linked := newWorktreeRepository(t)
			h := newHarness(t, gitKernel{core.NewClient()})
			k, w := startDirtyWorktreeRemovalWithBranchDraft(t, h, dir, linked)
			close(k.release)
			h.await("worktree refusal", func() bool { return !w.busy })
			finishBranchDraftAfterGitDeletion(t, h)
			h.app.kernel = k.Kernel

			if stage == "before-confirming" {
				openGitDeletionNotice(t, h)
				h.clickNamed(h.app.text.Worktrees.ReviewForce)
				if w.dialog != worktreeDialogForce {
					t.Fatal("the original checkout's force confirmation did not open")
				}
			}

			// Reuse the path outside the workbench while the Log tab is visible, so the
			// cached Worktrees list still describes the checkout whose removal failed.
			draft := replaceReviewedWorktree(t, dir, linked)
			h.settle()
			if cached, ok := w.find(linked); !ok || cached.Branch != "refs/heads/feature" {
				t.Fatal("the fixture must still show the original checkout in its cached list")
			}

			if stage == "before-reopening" {
				openGitDeletionNotice(t, h)
			} else {
				h.clickNamed(h.app.text.Worktrees.ForceButton)
			}
			h.await("stale review or removal result", func() bool { return !w.busy })
			if got, err := os.ReadFile(draft); err != nil || string(got) != "new untracked work" {
				t.Fatalf("replacement checkout's draft = %q, err = %v", got, err)
			}
			if w.dialog != worktreeDialogNone ||
				lastNotice(h) != i18n.Shared(h.app.language(), "desktop.worktree.removeSelectionChanged") {
				t.Fatal("the old review should close and explain that the checkout changed")
			}
		})
	}
}

// replaceReviewedWorktree simulates an external Git operation at the original path.
func replaceReviewedWorktree(t *testing.T, dir, linked string) string {
	t.Helper()
	gitRun(t, dir, "worktree", "remove", "--force", linked)
	gitRun(t, dir, "worktree", "add", "-b", "replacement", linked)
	gitRun(t, linked, "commit", "--allow-empty", "-m", "replacement checkout")
	draft := filepath.Join(linked, "replacement-draft.txt")
	if err := os.WriteFile(draft, []byte("new untracked work"), 0o600); err != nil {
		t.Fatal(err)
	}
	return draft
}
