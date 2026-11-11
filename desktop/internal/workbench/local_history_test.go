package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

// TestLocalHistoryComparesASnapshotWithThePreviousOneAndTheCurrentText records two snapshots of a
// file and checks the dialog's comparisons. The same text as the current one is reported in the
// dialog without a tab. Comparing with the snapshot before opens a read-only Diff tab named by the
// two snapshots, with Core's lines. Comparing with the current text takes the open editor's
// unsaved text over the file on disk. The snapshots are kept in the client's data directory.
func TestLocalHistoryComparesASnapshotWithThePreviousOneAndTheCurrentText(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "a.txt")
	if err := os.WriteFile(path, []byte("two\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.recordLocalHistory(p, path, "save", historyTexts{before: []byte("one\n"), after: []byte("two\n")})
	h.settle()
	stored, err := os.ReadDir(filepath.Join(h.store.Dir(), "LocalHistory"))
	if err != nil || len(stored) != 1 {
		t.Fatalf("the snapshots are not kept in the client's data directory: %v, %v", stored, err)
	}
	history, words := &p.history, h.app.text.History
	openHistory := func() {
		t.Helper()
		h.app.openLocalHistory(p, path)
		h.await("the snapshots and the preview", func() bool {
			return !history.loading && len(history.entries) == 2 && history.previewReady
		})
	}
	press := func(label string) {
		t.Helper()
		h.click(center(h.popupHit(label)))
	}
	contents := func(tab *diffTab) []string {
		var out []string
		for _, line := range tab.file.Lines {
			out = append(out, strings.TrimSpace(line.Content))
		}
		return out
	}

	openHistory()
	if err := os.WriteFile(path, []byte(history.preview), 0o600); err != nil {
		t.Fatal(err)
	}
	press(words.CompareWithCurrent)
	h.await("the comparison without differences", func() bool { return history.failure == words.NoChanges })
	if !history.open || len(p.diffs.list) != 0 {
		t.Fatalf("the same text opened a tab or closed the dialog: open %v, tabs %d", history.open, len(p.diffs.list))
	}

	newer, older := history.entries[0], history.entries[1]
	press(words.CompareWithPrevious)
	h.await("the Diff with the snapshot before", func() bool { return len(p.diffs.list) == 1 && p.diffs.list[0].file != nil })
	tab := p.diffs.list[0]
	if history.open {
		t.Fatal("the dialog stays open over the Diff tab")
	}
	if left, right := h.app.diffSideLabels(tab); left != localHistorySide(older) || right != localHistorySide(newer) {
		t.Fatalf("sides %q and %q, want the older and the newer snapshot", left, right)
	}
	if !tab.readOnly() || tab.root != root || tab.change.Path != "a.txt" {
		t.Fatalf("tab read only %v, root %q, path %q", tab.readOnly(), tab.root, tab.change.Path)
	}
	if got := contents(tab); tab.file.Additions != 1 || tab.file.Deletions != 1 || !slices.Contains(got, "one") || !slices.Contains(got, "two") {
		t.Fatalf("lines %q, +%d −%d", got, tab.file.Additions, tab.file.Deletions)
	}

	// Without auto-save the edit stays in the editor when the dialog takes the keyboard.
	h.app.settings.DisableAutoSave = true
	h.app.openFile(p, path)
	h.await("the open file", func() bool { return p.docs.byPath(path) != nil })
	d := p.docs.byPath(path)
	data, _ := d.view.Text()
	if err := d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: len(data)}, Text: "three\n"}}); err != nil {
		t.Fatal(err)
	}
	openHistory()
	press(words.CompareWithCurrent)
	h.await("the Diff with the current text", func() bool {
		return (len(p.diffs.list) == 2 && p.diffs.list[1].file != nil) || history.failure != ""
	})
	if history.failure != "" {
		t.Fatalf("comparing with the current text failed: %s", history.failure)
	}
	tab = p.diffs.list[1]
	if _, right := h.app.diffSideLabels(tab); right != words.CurrentVersion {
		t.Fatalf("the current side is named %q", right)
	}
	if got := contents(tab); !slices.Contains(got, "three") {
		t.Fatalf("the current side is not the editor's unsaved text: %q", got)
	}
	if disk, err := os.ReadFile(path); err != nil || strings.Contains(string(disk), "three") {
		t.Fatalf("the edit reached the disk (%q, %v), so the test cannot tell the editor's text from the file's", disk, err)
	}
}
