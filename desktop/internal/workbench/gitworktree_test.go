package workbench

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
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
	h.app.layout.gitTab = gitTabWorktrees
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

// The Worktrees item of the Git tools menu shows the Worktrees tab instead of a dialog.
func TestGitToolsMenuShowsTheWorktreesTab(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	lang := h.app.language()

	h.clickNamed(i18n.Shared(lang, "desktop.gitReview.menuLabel"))
	h.settle()
	h.clickNamed(i18n.Shared(lang, "git.worktrees"))
	h.settle()
	if h.app.layout.gitTab != gitTabWorktrees || !h.app.chrome.isOpen(catalogIndex[itemGit]) {
		t.Fatalf("tab %d, Git tool window open %v; want the Worktrees tab shown", h.app.layout.gitTab, h.app.chrome.isOpen(catalogIndex[itemGit]))
	}
	if p.review.tools.open {
		t.Fatal("the menu opened the tools dialog")
	}
	h.await("the worktrees", func() bool { return p.worktrees.started && p.worktrees.loaded })
	// The Git actions menu is in the tool window's header, so it stays on every tab.
	if _, ok := h.findPageHit(h.app.text.Git.Actions); !ok {
		t.Fatal("the Worktrees tab hides the Git actions menu of the header")
	}
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

// awaitWorktreeChanges waits until the changes of the worktree at path were read with no write
// in flight and done accepts them, and returns them.
func (h *harness) awaitWorktreeChanges(what, path string, done func([]core.GitChange) bool) []core.GitChange {
	h.t.Helper()
	var changes []core.GitChange
	h.await(what, func() bool {
		entry := h.app.project.worktrees.changes[path]
		if entry == nil || entry.loading || entry.busy || entry.err != nil {
			return false
		}
		changes = entry.changes
		return done(changes)
	})
	return changes
}

// stagedAs reports that the changes are the one at name, staged or not as staged says.
func stagedAs(name string, staged bool) func([]core.GitChange) bool {
	return func(changes []core.GitChange) bool {
		return len(changes) == 1 && changes[0].Path == name && changes[0].Staged == staged
	}
}

// changeAt is the change at name among changes.
func changeAt(t *testing.T, changes []core.GitChange, name string) core.GitChange {
	t.Helper()
	for _, change := range changes {
		if change.Path == name {
			return change
		}
	}
	t.Fatalf("no change at %s in %+v", name, changes)
	return core.GitChange{}
}

// The Changes tab stages and unstages in the checkout it shows, not in the open project's.
func TestWorktreeChangesStageAndUnstageInTheirCheckout(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	if err := os.WriteFile(filepath.Join(linked, "draft.txt"), []byte("draft\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openWorktrees(t, dir)
	commit := h.app.text.Commit
	h.selectWorktreeAt(t, linked)
	h.clickNamed(h.app.text.Worktrees.Changes)
	h.awaitWorktreeChanges("the linked checkout's change", linked, stagedAs("draft.txt", false))

	h.clickNamed(commit.StageFile("draft.txt"))
	h.awaitWorktreeChanges("the staged file", linked, stagedAs("draft.txt", true))
	if got := gitRun(t, linked, "diff", "--cached", "--name-only"); got != "draft.txt" {
		t.Fatalf("the linked checkout's index has %q, want draft.txt", got)
	}
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); got != "" {
		t.Fatalf("the primary checkout's index has %q, want nothing", got)
	}
	h.clickNamed(commit.UnstageFile("draft.txt"))
	h.awaitWorktreeChanges("the unstaged file", linked, stagedAs("draft.txt", false))

	// The list's checkbox stages everything; the toolbar unstages it again.
	h.clickNamed(h.app.text.Worktrees.LocalChanges)
	h.awaitWorktreeChanges("everything staged", linked, stagedAs("draft.txt", true))
	h.clickNamed(commit.UnstageAll)
	h.awaitWorktreeChanges("everything unstaged", linked, stagedAs("draft.txt", false))
	if got := gitRun(t, linked, "diff", "--cached", "--name-only"); got != "" {
		t.Fatalf("the linked checkout's index has %q after unstaging all, want nothing", got)
	}
}

// The diff and the rollback of a change of another worktree read and write that checkout.
func TestWorktreeChangesShowTheDiffAndRollBackInTheirCheckout(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	for name, value := range map[string]string{"changed.txt": "linked\n", "draft.txt": "draft\n"} {
		if err := os.WriteFile(filepath.Join(linked, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openWorktrees(t, dir)
	p, lang := h.app.project, h.app.language()
	h.selectWorktreeAt(t, linked)
	h.clickNamed(h.app.text.Worktrees.Changes)
	changes := h.awaitWorktreeChanges("the linked checkout's changes", linked, func(c []core.GitChange) bool { return len(c) == 2 })

	// draft.txt exists only in the linked checkout, so its diff can only be read there.
	d := h.app.openDiffIn(p, linked, changeAt(t, changes, "draft.txt"))
	if d == nil {
		t.Fatal("no Diff tab opened for the linked checkout's change")
	}
	h.await("the diff", func() bool { return !d.loading })
	if d.err != "" || d.root != linked || d.file == nil {
		t.Fatalf("diff in %q: err %q, file %v; want draft.txt read from %q", d.root, d.err, d.file != nil, linked)
	}
	h.app.closeDiffTab(p, d.id)

	h.rightClickNamed("changed.txt")
	h.clickNamed(i18n.Shared(lang, "git.rollback"))
	h.settle()
	if !p.review.rollback.open || p.review.rollback.root != linked {
		t.Fatalf("rollback %+v, want the confirmation for %q", p.review.rollback, linked)
	}
	h.clickNamed(i18n.Shared(lang, "git.rollback.confirm"))
	h.awaitWorktreeChanges("the rollback", linked, func(c []core.GitChange) bool {
		return len(c) == 1 && c[0].Path == "draft.txt"
	})
	for root, want := range map[string]string{linked: "first\n", dir: "second\n"} {
		if got, err := os.ReadFile(filepath.Join(root, "changed.txt")); err != nil || string(got) != want {
			t.Fatalf("changed.txt in %s = %q, %v; want %q", root, got, err, want)
		}
	}
}

// rightClickNamed opens the context menu of the element named name.
func (h *harness) rightClickNamed(name string) {
	h.t.Helper()
	point := center(h.pageHit(name).Bounds)
	if err := h.driver.ClickButton(point.X, point.Y, gfx.PointerButtonSecondary); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
}

// The History tab of a linked checkout lays its commits out on the lanes of the Git graph,
// with the merge on its own row and the merged branch on a lane beside the first parent's.
func TestWorktreeHistoryDrawsTheGraphOfItsCheckout(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	gitRun(t, linked, "switch", "-c", "side")
	if err := os.WriteFile(filepath.Join(linked, "side.txt"), []byte("side\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, linked, "add", "side.txt")
	gitRun(t, linked, "commit", "-m", "side work")
	gitRun(t, linked, "switch", "feature")
	gitRun(t, linked, "commit", "--allow-empty", "-m", "feature work")
	gitRun(t, linked, "merge", "--no-ff", "-m", "merge side", "side")
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openWorktrees(t, dir)
	h.selectWorktreeAt(t, linked)
	h.clickNamed(h.app.text.Worktrees.History)
	history := &h.app.project.worktrees.history
	h.await("the linked checkout's history and graph", func() bool {
		return history.loaded && !history.loading && len(history.graph.Rows) == len(history.commits)
	})
	rows := history.graph.Rows
	if len(rows) != 4 || history.commits[0].Subject != "merge side" {
		t.Fatalf("the history has %d graph rows for %d commits starting with %q, want 4 starting with the merge",
			len(rows), len(history.commits), history.commits[0].Subject)
	}
	lanes := map[int]bool{}
	for i, row := range rows {
		if row.CommitHash != history.commits[i].Hash {
			t.Fatalf("graph row %d is commit %s, want %s", i, row.CommitHash, history.commits[i].Hash)
		}
		lanes[row.Lane] = true
	}
	if len(lanes) < 2 {
		t.Fatalf("the graph keeps every commit on lanes %v, want the merged branch on its own lane", lanes)
	}
	if !h.app.worktreeView.graphed || !h.shows("merge side") {
		t.Fatalf("the History tab does not draw the graph rows (graphed %v)", h.app.worktreeView.graphed)
	}
}

// A linked checkout commits what is staged in it from its Changes tab, with a message of its
// own; the project's checkout and its Commit draft are left as they were.
func TestWorktreeChangesCommitInTheirCheckout(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	if err := os.WriteFile(filepath.Join(linked, "draft.txt"), []byte("draft\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	p, commit := h.app.project, h.app.text.Commit
	p.commit.editor.Insert("The project's draft")
	h.selectWorktreeAt(t, linked)
	h.clickNamed(h.app.text.Worktrees.Changes)
	h.awaitWorktreeChanges("the linked checkout's change", linked, stagedAs("draft.txt", false))
	h.clickNamed(commit.StageFile("draft.txt"))
	h.awaitWorktreeChanges("the staged file", linked, stagedAs("draft.txt", true))

	target := p.worktreeCommit(linked)
	if target.state == &p.commit || p.canCommitWorktree(linked, target.state) {
		t.Fatal("the linked checkout shares the project's draft or commits without a message")
	}
	target.state.editor.Insert("Linked work")
	h.settle()
	if !p.canCommitWorktree(linked, target.state) {
		t.Fatalf("the commit is off with draft.txt staged and the message %q", target.state.message())
	}
	h.clickNamed(commit.Commit)
	h.awaitWorktreeWrite("the commit", w, func() bool {
		return !target.state.busy && gitRun(t, linked, "log", "-1", "--format=%s") == "Linked work"
	})
	h.awaitWorktreeChanges("the clean checkout", linked, func(c []core.GitChange) bool { return len(c) == 0 })
	if got := gitRun(t, dir, "log", "-1", "--format=%s"); got != "initial" {
		t.Fatalf("the project's checkout moved to %q", got)
	}
	if got := gitRun(t, linked, "show", "--name-only", "--format=", "HEAD"); got != "draft.txt" {
		t.Fatalf("the commit took %q, want draft.txt", got)
	}
	if target.state.message() != "" || p.commit.message() != "The project's draft" {
		t.Fatalf("messages after the commit: linked %q, project %q", target.state.message(), p.commit.message())
	}
}

// The project's own checkout commits from the Worktrees tab as the Commit tool window does,
// with its draft; a push from a linked checkout shows its review over the workbench.
func TestWorktreeChangesShareTheProjectsCommit(t *testing.T) {
	dir, linked := newWorktreeRepository(t)
	if err := os.WriteFile(filepath.Join(linked, "draft.txt"), []byte("draft\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, gitKernel{core.NewClient()})
	w := h.openWorktrees(t, dir)
	p, commit := h.app.project, h.app.text.Commit
	var primary string
	for _, worktree := range w.list {
		if worktree.IsCurrent {
			primary = worktree.Path
		}
	}
	if primary == "" || p.worktreeCommit(primary).state != &p.commit {
		t.Fatalf("the project's checkout %q does not commit with the project's draft", primary)
	}
	if p.worktreeCommit(linked).state == &p.commit {
		t.Fatal("the linked checkout commits with the project's draft")
	}

	h.selectWorktreeAt(t, linked)
	h.clickNamed(h.app.text.Worktrees.Changes)
	h.awaitWorktreeChanges("the linked checkout's change", linked, stagedAs("draft.txt", false))
	h.clickNamed(commit.StageFile("draft.txt"))
	h.awaitWorktreeChanges("the staged file", linked, stagedAs("draft.txt", true))
	target := p.worktreeCommit(linked)
	target.state.editor.Insert("Publish linked work")
	h.settle()
	h.clickNamed(commit.CommitAndPush)
	h.await("the review", func() bool { return !target.state.busy && target.state.review != nil })
	if got := gitRun(t, linked, "log", "-1", "--format=%s"); got != "initial" {
		t.Fatalf("the commit ran before its review was confirmed: %q", got)
	}
	h.clickNamed(commit.Cancel)
	if target.state.review != nil {
		t.Fatal("cancel left the linked checkout's review open")
	}
}
