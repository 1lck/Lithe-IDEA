package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// settleChain waits for the background steps an action chained: a status load, then the
// placement of its changes in the lists.
func (h *harness) settleChain() {
	h.t.Helper()
	for range gitChainSteps {
		h.settle()
	}
}

// showsWrapped is shows for a paragraph, whose lines are labels of their own: the labels
// read in order, the line breaks and spaces left out.
func (h *harness) showsWrapped(value string) bool {
	h.t.Helper()
	var all strings.Builder
	for _, label := range h.driver.Snapshot().Labels {
		all.WriteString(label.Value)
	}
	squeeze := func(s string) string { return strings.Join(strings.Fields(s), "") }
	return strings.Contains(squeeze(all.String()), squeeze(value))
}

// changeNamed is the change of the status at path.
func changeNamed(t *testing.T, p *project, path string) core.GitChange {
	t.Helper()
	for _, change := range p.git.status.Changes {
		if change.Path == path {
			return change
		}
	}
	t.Fatalf("%s is not a change of %+v", path, p.git.status.Changes)
	return core.GitChange{}
}

// newTwoChangeRepository is newTestRepository with a second modified file, other.txt.
func newTwoChangeRepository(t *testing.T) string {
	t.Helper()
	dir := newTestRepository(t)
	path := filepath.Join(dir, "other.txt")
	if err := os.WriteFile(path, []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", "other.txt")
	gitRun(t, dir, "commit", "-m", "other")
	if err := os.WriteFile(path, []byte("two\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// createChangeList creates a list named name through the dialog, taking move.
func (h *harness) createChangeList(p *project, name string, move ...core.GitChange) {
	h.t.Helper()
	h.app.openChangeListDialog(p, changeListCreate, move)
	p.lists.name.SetText(name)
	h.app.submitChangeListName(p)
	h.settleChain()
}

func TestChangeListsCommitOnlyTheActiveList(t *testing.T) {
	dir := newTwoChangeRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.settleChain()
	if !p.listsReady() || p.lists.inUse() {
		t.Fatalf("a repository without stored lists is not ready with the default list alone: %+v", p.lists)
	}

	h.createChangeList(p, "Later", changeNamed(t, p, "other.txt"))
	if p.lists.dialog != changeListNoDialog || p.lists.nameError != "" {
		t.Fatalf("the dialog stayed open: %d %q", p.lists.dialog, p.lists.nameError)
	}
	if !p.lists.inUse() || p.changeListOf(changeNamed(t, p, "other.txt")) == changeListDefaultID {
		t.Fatalf("other.txt did not move to the new list: %+v", p.lists.members)
	}
	if p.lists.activeID() != changeListDefaultID {
		t.Fatalf("creating a list activated it: %q", p.lists.activeID())
	}
	if !h.shows("Later") {
		t.Fatal("the new list's section is not shown")
	}

	// A second window reads what this one stored.
	stored, err := loadChangeLists(h.store, p.git.repositoryRoot(p.root))
	if err != nil || !sameChangeLists(stored, p.lists.state) {
		t.Fatalf("stored lists = %+v, %v; want %+v", stored, err, p.lists.state)
	}

	h.app.stageAll(p, surfaceButton)
	h.settleChain()
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); got != "changed.txt" {
		t.Fatalf("stage all staged %q, want only the active list's changed.txt", got)
	}

	p.commit.editor.Insert("Only the default list")
	h.settle()
	if !p.canCommit() {
		t.Fatalf("the commit is off with the active list staged: ready %v, other staged %v", p.listsReady(), p.otherStaged())
	}
	h.app.startCommit(p, false, surfaceButton)
	h.settleChain()
	if got := gitRun(t, dir, "show", "--name-only", "--format=", "HEAD"); got != "changed.txt" {
		t.Fatalf("the commit took %q, want changed.txt", got)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); got != "M other.txt" {
		t.Fatalf("status after the commit = %q, want other.txt left", got)
	}
}

func TestChangeListsOtherStagedFilesBlockTheCommit(t *testing.T) {
	dir := newTwoChangeRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.settleChain()
	h.createChangeList(p, "Later", changeNamed(t, p, "other.txt"))

	gitRun(t, dir, "add", "changed.txt", "other.txt")
	h.app.refreshChanges(p)
	h.settleChain()
	p.commit.editor.Insert("Mixed")
	h.settle()
	if !p.otherStaged() || p.canCommit() {
		t.Fatalf("a staged file of another list leaves the commit on: other staged %v", p.otherStaged())
	}
	warning := i18n.Shared(h.app.language(), "native.otherChangeListsHaveStagedFilesUnstageThemBeforeCommittingTheCurrentChangeList")
	if !h.showsWrapped(warning) {
		t.Fatal("the commit area does not say why it is off")
	}
}

func TestChangeListsRejectedNameKeepsTheDialogOpen(t *testing.T) {
	dir := newTwoChangeRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.settleChain()
	h.createChangeList(p, "Later")

	h.app.openChangeListDialog(p, changeListCreate, nil)
	p.lists.name.SetText("Later")
	h.app.submitChangeListName(p)
	h.settleChain()
	if p.lists.dialog != changeListCreate || p.lists.nameError != i18n.Shared(h.app.language(), "git.changelists.invalidName") {
		t.Fatalf("a duplicate name closed the dialog or showed %q", p.lists.nameError)
	}
	if len(p.lists.state.Lists) != 2 {
		t.Fatalf("a duplicate name created a list: %+v", p.lists.state.Lists)
	}
}

func TestChangeListsRemoveReturnsFilesToTheDefault(t *testing.T) {
	dir := newTwoChangeRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.settleChain()
	h.createChangeList(p, "Later", changeNamed(t, p, "other.txt"))
	later := p.changeListOf(changeNamed(t, p, "other.txt"))

	h.app.activateChangeList(p, later)
	h.settleChain()
	if p.lists.activeID() != later {
		t.Fatalf("active list = %q, want %q", p.lists.activeID(), later)
	}
	h.app.openChangeListDialog(p, changeListDelete, nil)
	h.app.removeChangeList(p)
	h.settleChain()
	if p.lists.inUse() || p.lists.dialog != changeListNoDialog {
		t.Fatalf("the list was not removed: %+v", p.lists.state)
	}
	if p.changeListOf(changeNamed(t, p, "other.txt")) != changeListDefaultID || p.lists.activeID() != changeListDefaultID {
		t.Fatal("the removed list's file did not return to the default list")
	}
}

func TestChangeListsUnreadableStoreTurnsTheCommitOff(t *testing.T) {
	dir := newTwoChangeRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.settleChain()
	file := filepath.Join(h.store.Dir(), changeListsFile(p.git.repositoryRoot(p.root)))
	if err := os.WriteFile(file, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", "changed.txt")
	h.app.refreshChanges(p)
	h.settleChain()
	p.commit.editor.Insert("Blocked")
	h.settle()
	if p.lists.failed == nil || p.listsReady() || p.canCommit() {
		t.Fatalf("an unreadable list file left the commit on: failed %v", p.lists.failed)
	}
	if !h.showsWrapped(i18n.Shared(h.app.language(), "git.changelists.unavailable")) {
		t.Fatal("the bar does not say the lists are unavailable")
	}
	if got, err := os.ReadFile(file); err != nil || string(got) != "{not json" {
		t.Fatalf("the unreadable file was replaced: %q, %v", got, err)
	}
}
