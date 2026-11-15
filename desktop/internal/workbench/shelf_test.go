package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// The Shelf tab of the Commit tool window shelves the staged, working and untracked changes in
// a file of the client's own, never the repository; lists the shelf; shows what it saved under
// its two layers and a saved file's diff; keeps the shelf when a restore is refused and
// restores it on the retry; and drops another once the user confirms, leaving the checkout as
// it is.
func TestShelfTabShelvesShowsRestoresAndDropsShelves(t *testing.T) {
	dir := newTestRepository(t)
	write := func(name, value string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("staged.txt", "staged\n")
	gitRun(t, dir, "add", "staged.txt")
	write("notes.txt", "note\n")
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	lang := h.app.language()
	s := &p.shelf

	h.clickNamed(i18n.Shared(lang, "git.saved.tab"))
	h.settle()
	if h.app.layout.commitTab != commitTabShelf {
		t.Fatalf("Commit tool window tab %d, want the Shelf tab", h.app.layout.commitTab)
	}
	h.await("the shelves", func() bool { return s.loaded })
	h.settle()
	if !h.shows(i18n.Shared(lang, "native.noShelves")) {
		t.Fatal("the empty Shelf tab does not say there are no shelves")
	}

	h.clickNamed(i18n.Shared(lang, "native.shelveChanges"))
	h.settle()
	if !s.shelveOpen {
		t.Fatal("the toolbar button did not open the shelve dialog")
	}
	s.message.SetText("parked")
	h.app.shelveChanges(p)
	h.settleChain()
	if len(s.list) != 1 || s.list[0].Message != "parked" || s.writeErr != "" {
		t.Fatalf("shelves after shelving = %+v (%q), want the parked one", s.list, s.writeErr)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); got != "" {
		t.Fatalf("status after shelving = %q, want clean", got)
	}
	shelf := s.list[0]
	folder, _ := h.app.shelfDirectory(dir)
	if rel, err := filepath.Rel(h.store.Dir(), folder); err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("shelf folder %q is outside the client's store %q", folder, h.store.Dir())
	}
	if _, err := os.Stat(filepath.Join(folder, shelf.ID+".json")); err != nil {
		t.Fatalf("the shelf was not written: %v", err)
	}
	if !slices.Equal(shelf.Paths, []string{"changed.txt", "notes.txt", "staged.txt"}) {
		t.Fatalf("shelf paths %v", shelf.Paths)
	}
	if !h.shows("parked") || !h.shows(i18n.Shared(lang, "native.selectSavedChanges")) {
		t.Fatal("the Shelf tab does not show the shelf over the prompt to select one")
	}

	h.app.selectShelf(p, shelf.ID)
	h.await("the shelf's files", func() bool { return !s.filesLoading })
	h.settle()
	if s.filesErr != "" || !slices.Equal(s.layers, []string{core.GitShelfStaged, core.GitShelfWorking}) {
		t.Fatalf("shelf layers %v (%q), want the staged and the working layer", s.layers, s.filesErr)
	}
	layerPaths := func(l int) []string {
		var paths []string
		for _, f := range s.tree.layers[l].files {
			paths = append(paths, f.Path)
		}
		slices.Sort(paths)
		return paths
	}
	if got := layerPaths(0); !slices.Equal(got, []string{"staged.txt"}) {
		t.Fatalf("staged layer %v, want staged.txt", got)
	}
	if got := layerPaths(1); !slices.Equal(got, []string{"changed.txt", "notes.txt"}) {
		t.Fatalf("working layer %v, want changed.txt and notes.txt", got)
	}
	if !h.shows(i18n.Shared(lang, "git.saved.staged")) || !h.shows(i18n.Shared(lang, "git.saved.worktree")) || !h.shows("notes.txt") {
		t.Fatal("the Shelf tab does not show the files under their layers")
	}

	h.app.openShelfFile(p, savedPath{layer: 1, path: "changed.txt"})
	h.settle()
	d := p.diffs.showing(dir, "shelf:"+shelf.ID+":"+core.GitShelfWorking, "changed.txt")
	if d == nil || !d.readOnly() || d.file == nil || d.loading || len(d.files) != 2 {
		t.Fatalf("shelf Diff tab = %+v, want a read-only tab of the saved file", d)
	}
	if left, right := h.app.diffSideLabels(d); left != i18n.Shared(lang, "git.diff.indexVersion") || right != i18n.Shared(lang, "git.saved.worktree") {
		t.Fatalf("working shelf Diff tab sides %q and %q", left, right)
	}
	h.app.openShelfFile(p, savedPath{layer: 0, path: "staged.txt"})
	h.settle()
	d = p.diffs.showing(dir, "shelf:"+shelf.ID+":"+core.GitShelfStaged, "staged.txt")
	if d == nil {
		t.Fatal("the staged file's Diff tab did not open")
	}
	if left, right := h.app.diffSideLabels(d); left != i18n.Shared(lang, "native.head") || right != i18n.Shared(lang, "git.diff.indexVersion") {
		t.Fatalf("staged shelf Diff tab sides %q and %q", left, right)
	}

	// An edit that is not saved stops the restore before it reaches Git.
	source := filepath.Join(dir, "changed.txt")
	h.app.openFileAtPosition(p, source, 0, 0)
	h.settle()
	doc := p.docs.byPath(source)
	if doc == nil {
		t.Fatal("missing document")
	}
	input := doc.view.TextInput(app.TextInputContext{ID: doc.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "unsaved\n"}); err != nil {
		t.Fatal(err)
	}
	h.app.restoreShelf(p, shelf)
	h.settle()
	if s.writeErr != i18n.Shared(lang, "git.saved.unsaved") || s.busy || len(s.list) != 1 {
		t.Fatalf("restore with an unsaved file: error %q, busy %v, shelves %d", s.writeErr, s.busy, len(s.list))
	}
	h.app.removeDocument(p, doc)
	h.settle()

	// A working tree that conflicts with the shelf refuses the restore and keeps the shelf.
	write("changed.txt", "other\n")
	h.app.restoreShelf(p, shelf)
	h.settleChain()
	if s.writeErr == "" || len(s.list) != 1 {
		t.Fatalf("conflicting restore: error %q, shelves %+v; want a failure with the shelf kept", s.writeErr, s.list)
	}
	gitRun(t, dir, "checkout", "--", "changed.txt")
	h.app.restoreShelf(p, shelf)
	h.settleChain()
	if s.writeErr != "" || len(s.list) != 0 || s.selected != "" {
		t.Fatalf("after the restore: error %q, shelves %+v, selected %q", s.writeErr, s.list, s.selected)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); !strings.Contains(got, "A  staged.txt") || !strings.Contains(got, "M changed.txt") || !strings.Contains(got, "?? notes.txt") {
		t.Fatalf("status after the restore = %q, want the staged, working and untracked changes back", got)
	}
	if _, err := os.Stat(filepath.Join(folder, shelf.ID+".json")); !os.IsNotExist(err) {
		t.Fatalf("the restored shelf's file is still there: %v", err)
	}

	h.app.openShelve(p)
	s.message.SetText("second")
	h.app.shelveChanges(p)
	h.settleChain()
	if len(s.list) != 1 {
		t.Fatalf("shelves after the second shelve = %+v", s.list)
	}
	s.confirmDropShelf(s.list[0])
	h.app.post(func(*App) {})
	h.settle()
	if !h.shows(i18n.Shared(lang, "git.saved.drop")) || !h.showsWrapped(i18n.Shared(lang, "native.thisRemovesTheSavedPatchFromLitheAndCannotBeUndone")) {
		t.Fatal("dropping a shelf does not ask the user to confirm")
	}
	h.app.dropShelf(p)
	h.settleChain()
	if len(s.list) != 0 || s.dropping != nil || s.writeErr != "" {
		t.Fatalf("after the drop: shelves %+v, error %q", s.list, s.writeErr)
	}
	if got := gitRun(t, dir, "status", "--porcelain"); got != "" {
		t.Fatalf("status after the drop = %q, want the checkout left clean", got)
	}
}

// A shelf folder lists only the files this client writes: another format, a file that does
// not name itself and a file that does not decode are passed over and reported.
func TestReadShelvesSkipsForeignFiles(t *testing.T) {
	dir := t.TempDir()
	older, newer := newShelfID(), newShelfID()
	files := map[string]string{
		older + ".json":        `{"formatVersion":1,"id":"` + older + `","message":"older","createdAt":"2026-01-01T00:00:00Z","stagedPatch":"","workingPatch":"x","paths":["a"]}`,
		newer + ".json":        `{"formatVersion":1,"id":"` + newer + `","message":"newer","createdAt":"2026-02-01T00:00:00Z","stagedPatch":"","workingPatch":"x","paths":["a"]}`,
		newShelfID() + ".json": `{"formatVersion":2,"id":"x"}`,
		newShelfID() + ".json": `{not json`,
		"notes.txt":            `ignored`,
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	list, skipped, err := readShelves(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Message != "newer" || list[1].Message != "older" {
		t.Fatalf("shelves %+v, want newer then older", list)
	}
	if skipped == nil {
		t.Fatal("the foreign shelf files were not reported")
	}
	if list, skipped, err := readShelves(filepath.Join(dir, "missing")); err != nil || skipped != nil || len(list) != 0 {
		t.Fatalf("a missing folder read %v, %v, %v; want no shelves", list, skipped, err)
	}
	if err := removeShelf(dir, "../escape"); err == nil {
		t.Fatal("removeShelf accepted an identity that is not one")
	}
}

// The Git actions menu's Shelves item shows the Commit tool window on its Shelf tab.
func TestGitActionsMenuShowsTheShelfTab(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openLog(t, dir)
	lang := h.app.language()

	h.clickNamed(i18n.Shared(lang, "desktop.gitReview.menuLabel"))
	h.settle()
	h.clickNamed(i18n.Shared(lang, "git.saved.shelves"))
	h.settle()
	if h.app.layout.commitTab != commitTabShelf || !h.app.chrome.isOpen(catalogIndex[itemCommit]) {
		t.Fatalf("Commit tab %d, open %v; want the Shelf tab shown", h.app.layout.commitTab, h.app.chrome.isOpen(catalogIndex[itemCommit]))
	}
}
