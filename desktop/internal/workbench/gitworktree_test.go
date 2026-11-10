package workbench

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// newWorktreeRepository is newTestRepository with a linked worktree on the branch feature,
// checked out beside it. It returns the repository and the linked checkout's canonical path,
// the path Git lists it by.
func newWorktreeRepository(t *testing.T) (string, string) {
	t.Helper()
	dir := newTestRepository(t)
	linked := filepath.Join(t.TempDir(), "feature-checkout")
	gitRun(t, dir, "worktree", "add", "-b", "feature", linked)
	resolved, err := filepath.EvalSymlinks(linked)
	if err != nil {
		t.Fatal(err)
	}
	return dir, resolved
}

// openWorktrees opens dir and shows the Worktrees tab of the Git tool window until the
// worktrees and their changes have been read.
func (h *harness) openWorktrees(t *testing.T, dir string) *worktreeState {
	t.Helper()
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	h.app.layout.gitTab = 1
	h.app.invalidator.Invalidate()
	h.settle()
	w := &p.worktrees
	if !w.started {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	if !w.started {
		t.Fatal("the Worktrees tab is not shown")
	}
	h.await("the worktrees and their changes", func() bool { return w.loaded && w.countsKnown })
	return w
}

// selectWorktreeAt shows the details of the worktree registered at path, as a click on its
// row does.
func (h *harness) selectWorktreeAt(t *testing.T, path string) {
	t.Helper()
	p := h.app.project
	if _, ok := p.worktrees.find(path); !ok {
		t.Fatalf("no worktree at %s in %+v", path, p.worktrees.list)
	}
	h.app.selectWorktree(p, path)
	h.app.invalidator.Invalidate()
	h.settle()
}

// awaitWorktreeWrite waits until the write in flight finished and the list was read again.
func (h *harness) awaitWorktreeWrite(what string, w *worktreeState, done func() bool) {
	h.t.Helper()
	h.await(what, func() bool { return !w.busy && !w.loading && w.countsKnown && done() })
}

func TestWorktreesListThePrimaryAndTheLinkedCheckouts(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	text := &h.app.text.Worktrees
	if len(w.list) != 2 {
		t.Fatalf("worktrees = %+v, want the primary and the linked one", w.list)
	}
	h.await("the linked worktree's row", func() bool {
		return h.shows(filepath.Base(linked)) && h.shows(text.BranchOf("feature")) && h.shows(text.Count(2))
	})
	current, ok := w.find(w.selected)
	if !ok || !current.IsPrimary || !current.IsCurrent {
		t.Fatalf("the selection is %q, want the open primary worktree", w.selected)
	}
	// The primary worktree carries the repository; its removal is offered with the reason it
	// cannot be done.
	h.await("why the primary worktree cannot be removed", func() bool {
		_, ok := h.findPageHit(text.RemovePrimary)
		return ok
	})
	if w.counts[current.Path] == 0 {
		t.Fatalf("counts = %v, want the primary worktree's modified file counted", w.counts)
	}
}

func TestWorktreesRemoveACleanLinkedCheckout(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	text := &h.app.text.Worktrees
	h.selectWorktreeAt(t, linked)

	h.clickNamed(text.Remove)
	h.settle()
	if w.dialog != worktreeDialogRemove || w.target.Path != linked {
		t.Fatalf("dialog = %v for %q, want the removal of %q", w.dialog, w.target.Path, linked)
	}
	h.clickNamed(text.RemoveButton)
	h.awaitWorktreeWrite("the removal", w, func() bool { return len(w.list) == 1 })
	if w.dialog != worktreeDialogNone {
		t.Fatalf("dialog = %v after the removal, want none", w.dialog)
	}
	if _, err := os.Stat(linked); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the checkout is still there: %v", err)
	}
}

func TestWorktreesRemovalOfAChangedCheckoutAsksToForce(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	if err := os.WriteFile(filepath.Join(linked, "draft.txt"), []byte("draft\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	text := &h.app.text.Worktrees
	h.selectWorktreeAt(t, linked)

	h.clickNamed(text.Remove)
	h.settle()
	h.clickNamed(text.RemoveButton)
	h.await("Git's refusal under review", func() bool { return !w.busy && w.dialog == worktreeDialogReview })
	if w.refusal == "" {
		t.Fatal("the review shows no reason")
	}
	h.settle()
	h.clickNamed(text.ReviewForce)
	h.settle()
	if w.dialog != worktreeDialogForce {
		t.Fatalf("dialog = %v, want the forced removal's confirmation", w.dialog)
	}
	h.clickNamed(text.ForceButton)
	h.awaitWorktreeWrite("the forced removal", w, func() bool { return len(w.list) == 1 })
	if _, err := os.Stat(linked); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the checkout is still there: %v", err)
	}
}

func TestWorktreesLockAndUnlock(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	text := &h.app.text.Worktrees
	h.selectWorktreeAt(t, linked)
	locked := func(want bool) func() bool {
		return func() bool {
			worktree, ok := w.find(linked)
			return ok && worktree.IsLocked == want
		}
	}

	h.clickNamed(text.Lock)
	h.awaitWorktreeWrite("the lock", w, locked(true))
	h.await("the removal blocked by the lock", func() bool {
		_, ok := h.findPageHit(text.RemoveLocked)
		return ok
	})
	h.clickNamed(text.Unlock)
	h.awaitWorktreeWrite("the unlock", w, locked(false))
}

func TestWorktreesCreateANewBranchBesideTheRepository(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	p := h.app.project
	text := &h.app.text.Worktrees

	h.clickNamed(text.New)
	h.await("the references", func() bool { return w.create.refsLoaded })
	if w.create.reference != "refs/heads/main" {
		t.Fatalf("reference = %q, want the current branch", w.create.reference)
	}
	w.create.name.SetText("topic/new thing")
	h.app.invalidator.Invalidate()
	h.settle()
	want := worktreeDestination(p.git.repositoryRoot(p.root), w.create.preview.CleanedName)
	if got := w.create.destination.Text(); got != want {
		t.Fatalf("destination = %q, want the suggestion %q", got, want)
	}
	t.Cleanup(func() { _ = os.RemoveAll(want) })

	h.clickNamed(text.Create)
	h.awaitWorktreeWrite("the creation", w, func() bool { return len(w.list) == 2 })
	created, ok := w.find(w.selected)
	if !ok || created.IsPrimary || created.Branch != "refs/heads/"+w.create.preview.CleanedName {
		t.Fatalf("selected %+v, want the new worktree on its new branch", created)
	}
}

func TestWorktreeDestinationNamesTheLeafBesideTheRepository(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "work", "app")
	for _, tc := range []struct{ source, leaf string }{
		{"feature/login", "login"},
		{"fix bug#12", "fix-bug-12"},
		{"版本", "版本"},
		{"", worktreeLeafFallback},
		{"refs/heads/", worktreeLeafFallback},
	} {
		if got := worktreeLeaf(tc.source); got != tc.leaf {
			t.Errorf("worktreeLeaf(%q) = %q, want %q", tc.source, got, tc.leaf)
		}
	}
	want := filepath.Join(string(filepath.Separator), "work", "app-login")
	if got := worktreeDestination(root, "feature/login"); got != want {
		t.Fatalf("worktreeDestination() = %q, want %q", got, want)
	}
}

func TestWorktreeFailureTextFollowsTheCode(t *testing.T) {
	text := i18n.For(i18n.English).Worktrees
	for _, tc := range []struct {
		code     core.ErrorCode
		removing bool
		want     string
	}{
		{core.CodeGitWorktreePrimary, true, text.RemovePrimary},
		{core.CodeGitWorktreePrimary, false, text.LockPrimary},
		{core.CodeGitWorktreeCurrent, true, text.RemoveCurrent},
		{core.CodeGitWorktreeLocked, true, text.RemoveLocked},
		{core.CodeProcessFailed, true, text.Failed("fatal: refused")},
	} {
		err := &core.Error{Code: tc.code, Message: "fatal: refused"}
		if got := worktreeFailureText(&text, tc.removing, err); got != tc.want {
			t.Errorf("worktreeFailureText(%s, %v) = %q, want %q", tc.code, tc.removing, got, tc.want)
		}
	}
	if got := worktreeFailureText(&text, true, errors.New("plain")); got != text.Failed("plain") {
		t.Errorf("a plain error reads %q", got)
	}
}

func TestWorktreeStatusPutsTheMostPressingFirst(t *testing.T) {
	all := core.GitWorktree{IsPrunable: true, IsLocked: true, IsCurrent: true}
	steps := []worktreeStatus{worktreeMissing, worktreeLocked, worktreeModified, worktreeCurrent, worktreeAvailable}
	var got []worktreeStatus
	changes := 3
	for range steps {
		got = append(got, worktreeStatusOf(all, changes))
		switch {
		case all.IsPrunable:
			all.IsPrunable = false
		case all.IsLocked:
			all.IsLocked = false
		case changes > 0:
			changes = 0
		default:
			all.IsCurrent = false
		}
	}
	if !slices.Equal(got, steps) {
		t.Fatalf("statuses = %v, want %v", got, steps)
	}
}
