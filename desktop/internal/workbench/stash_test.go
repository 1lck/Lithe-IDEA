package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The Stash tab of the Commit tool window stashes the local changes with the untracked files,
// lists the stash, shows what it saved and a saved file's diff, pops it, and drops another once
// the user confirms.
func TestStashTabMakesShowsPopsAndDropsStashes(t *testing.T) {
	dir := newTestRepository(t)
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("note\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	lang := h.app.language()
	s := &p.stash

	h.clickNamed(i18n.Shared(lang, "native.stash"))
	h.settle()
	if h.app.layout.commitTab != commitTabStash {
		t.Fatalf("Commit tool window tab %d, want the Stash tab", h.app.layout.commitTab)
	}
	h.await("the stashes", func() bool { return s.loaded })
	h.settle()
	if !h.shows(i18n.Shared(lang, "native.noSavedChanges")) {
		t.Fatal("the empty Stash tab does not say there are no saved changes")
	}

	h.clickNamed(i18n.Shared(lang, "desktop.gitReview.stashPush"))
	h.settle()
	if !s.pushOpen {
		t.Fatal("the toolbar button did not open the stash dialog")
	}
	s.message.SetText("parked")
	s.untracked = true
	h.app.pushStash(p)
	h.settleChain()
	if len(s.list) != 1 || !strings.Contains(s.list[0].Message, "parked") || s.writeErr != "" {
		t.Fatalf("stashes after the stash = %+v (%q), want the parked one", s.list, s.writeErr)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); got != "" {
		t.Fatalf("status after the stash = %q, want clean", got)
	}
	if !h.shows("parked") || !h.shows(i18n.Shared(lang, "native.selectSavedChanges")) {
		t.Fatal("the Stash tab does not show the stash over the prompt to select one")
	}

	stash := s.list[0]
	h.app.selectStash(p, stash.OID)
	h.await("the stash's files", func() bool { return !s.filesLoading })
	h.settle()
	paths := make([]string, len(s.files))
	for i, f := range s.files {
		paths[i] = f.Path
	}
	slices.Sort(paths)
	if s.filesErr != "" || !slices.Equal(paths, []string{"changed.txt", "notes.txt"}) {
		t.Fatalf("stash files %v (%q), want changed.txt and notes.txt", paths, s.filesErr)
	}
	if !h.shows("notes.txt") {
		t.Fatal("the Stash tab does not show the saved untracked file")
	}

	h.app.openStashFile(p, "changed.txt")
	h.settle()
	d := p.diffs.showing(p.git.repositoryRoot(p.root), stash.OID, "changed.txt")
	if d == nil || !d.readOnly() || d.file == nil || d.loading || len(d.files) != 2 {
		t.Fatalf("stash Diff tab = %+v, want a read-only tab of the saved file", d)
	}
	if left, right := h.app.diffSideLabels(d); left != stash.Reference+"^" || right != stash.Reference {
		t.Fatalf("stash Diff tab sides %q and %q", left, right)
	}

	h.app.applyStash(p, stash, true)
	h.settleChain()
	if len(s.list) != 0 || s.selected != "" {
		t.Fatalf("after the pop: stashes %+v, selected %q", s.list, s.selected)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); !strings.Contains(got, "M changed.txt") || !strings.Contains(got, "?? notes.txt") {
		t.Fatalf("status after the pop = %q, want the change and the untracked file back", got)
	}

	h.app.openStashPush(p)
	h.app.pushStash(p)
	h.settleChain()
	if len(s.list) != 1 {
		t.Fatalf("stashes after the second stash = %+v", s.list)
	}
	s.confirmDropStash(s.list[0])
	h.app.post(func(*App) {})
	h.settle()
	if !h.shows(i18n.Shared(lang, "native.dropStash")) || !h.showsWrapped(i18n.Shared(lang, "native.thisRemovesTheStashFromGitAndCannotBeUndone")) {
		t.Fatal("dropping a stash does not ask the user to confirm")
	}
	h.app.dropStash(p)
	h.settleChain()
	if len(s.list) != 0 || s.dropping != nil || gitRun(t, dir, "stash", "list") != "" {
		t.Fatalf("after the drop: stashes %+v, git stash list %q", s.list, gitRun(t, dir, "stash", "list"))
	}
}

// The Git actions menu's Stashes item shows the Commit tool window on its Stash tab.
func TestGitActionsMenuShowsTheStashTab(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openLog(t, dir)
	lang := h.app.language()

	h.clickNamed(i18n.Shared(lang, "desktop.gitReview.menuLabel"))
	h.settle()
	h.clickNamed(i18n.Shared(lang, "git.saved.stashes"))
	h.settle()
	if h.app.layout.commitTab != commitTabStash || !h.app.chrome.isOpen(catalogIndex[itemCommit]) {
		t.Fatalf("Commit tab %d, open %v; want the Stash tab shown", h.app.layout.commitTab, h.app.chrome.isOpen(catalogIndex[itemCommit]))
	}
}
