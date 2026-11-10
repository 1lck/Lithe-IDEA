package workbench

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// openDiffTab opens the Diff tab of path, a change of the project's repository, and waits for
// what it reads.
func openDiffTab(t *testing.T, h *harness, p *project, path string) *diffTab {
	t.Helper()
	d := h.app.openDiff(p, changeOf(t, p, path))
	if d == nil {
		t.Fatalf("no Diff tab opened for %s", path)
	}
	h.await("the diff of "+path, func() bool { return !d.loading })
	h.settle()
	return d
}

// editorGroups counts the tab groups of the editor area, leaving out the tool window's.
func editorGroups(p *project) int {
	n := 0
	for _, g := range p.terms.bench.Groups {
		if g.ID != toolGroup {
			n++
		}
	}
	return n
}

// diffBlocks counts the block headers among the tab's rows.
func diffBlocks(d *diffTab) int {
	blocks := 0
	for _, item := range d.items {
		if item.block != nil {
			blocks++
		}
	}
	return blocks
}

// diffFolds are the fold rows among the tab's rows.
func diffFolds(d *diffTab) []diffItem {
	var folds []diffItem
	for _, item := range d.items {
		if item.fold > 0 {
			folds = append(folds, item)
		}
	}
	return folds
}

func TestDiffTabStagesAndRollsBackABlock(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	d := openDiffTab(t, h, p, "changed.txt")
	if d.plan == nil || len(d.plan.Blocks) != 1 || d.file == nil {
		t.Fatalf("diff = %+v, want a tab with one block", d)
	}
	if blocks := diffBlocks(d); blocks != 1 || len(d.items) != len(d.file.Lines)+1 {
		t.Fatalf("diff has %d block headers over %d rows for %d lines", blocks, len(d.items), len(d.file.Lines))
	}
	for _, label := range []string{"changed.txt", i18n.Shared(h.app.language(), "git.diff.unified")} {
		if !h.shows(label) {
			t.Errorf("the Diff tab does not show %q", label)
		}
	}

	h.app.toggleDiffBlock(p, d, d.plan.Blocks[0])
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); got != "changed.txt" {
		t.Fatalf("staged files after the toggle = %q, want changed.txt", got)
	}
	if !d.plan.Blocks[0].Checked {
		t.Fatalf("the reloaded plan does not show the block as staged: %+v", d.plan.Blocks)
	}

	h.app.toggleDiffBlock(p, d, d.plan.Blocks[0])
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); got != "" {
		t.Fatalf("staged files after the second toggle = %q, want none", got)
	}
	h.app.writeDiffBlock(p, d, d.plan.Blocks[0].ID, core.DiffBlockRollback)
	h.settle()
	h.settle()
	if got := gitRun(t, dir, "status", "--porcelain"); got != "" {
		t.Fatalf("status after the rollback = %q, want clean", got)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "changed.txt"))
	if string(data) != "first\n" {
		t.Fatalf("file after the block rollback = %q, want the committed text", data)
	}
}

func TestDiffTabSplitViewAnchorsBlocksOnRows(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	d := openDiffTab(t, h, p, "changed.txt")
	h.app.setDiffMode(p, d, true, d.whole)
	if diffBlocks(d) != 1 {
		t.Fatalf("split view has %d block headers, want 1", diffBlocks(d))
	}
	for i, item := range d.items {
		if item.block != nil && (i+1 >= len(d.items) || d.items[i+1].row < 0) {
			t.Fatalf("split block header %+v does not stand over a row: %+v", item, d.items)
		}
	}
	if !p.diffs.split {
		t.Fatal("the next Diff tab does not open side by side after the switch")
	}
}

// The Diff tab is a tab of the editor area like a file's: it is selected in its group, is not
// opened twice for one change, splits off into a group of its own and closes with its group.
func TestDiffTabIsAnEditorTab(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.app.openFile(p, filepath.Join(dir, "changed.txt"))
	h.settle()

	d := openDiffTab(t, h, p, "changed.txt")
	member := diffMember(d.id)
	g := p.terms.bench.GroupOf(member)
	if g == nil || g.Selected != member || len(g.Members) != 2 {
		t.Fatalf("the Diff tab is not the selected tab beside the file: %+v", g)
	}
	if h.app.focus != (focusTarget{diff: d.id}) {
		t.Fatalf("focus %+v, want the Diff tab", h.app.focus)
	}
	if again := h.app.openDiff(p, changeOf(t, p, "changed.txt")); again != d || len(p.diffs.list) != 1 {
		t.Fatalf("opening the change again made another tab: %d tabs", len(p.diffs.list))
	}
	h.await("the diff read again", func() bool { return !d.loading })

	first := g.ID
	if !h.app.splitTab(p, member, first, edgeRight) {
		t.Fatal("the Diff tab did not split off")
	}
	h.settle()
	g = p.terms.bench.GroupOf(member)
	if g == nil || g.ID == first || editorGroups(p) != 2 {
		t.Fatalf("after the split the Diff tab is in %+v of %d groups", g, editorGroups(p))
	}
	if !h.shows(i18n.Shared(h.app.language(), "git.diff.unified")) {
		t.Fatal("the split-off group does not show the Diff tab")
	}

	h.app.closeDiffTab(p, d.id)
	h.settle()
	if p.terms.bench.GroupOf(member) != nil || len(p.diffs.list) != 0 || editorGroups(p) != 1 {
		t.Fatalf("after closing, %d tabs in %d groups", len(p.diffs.list), editorGroups(p))
	}
}

// A long file folds the unchanged lines between its differences; the user steps through the
// differences, opens a fold, shows the whole file and steps to the next changed file.
func TestDiffTabFoldsAndStepsThroughDifferences(t *testing.T) {
	dir := newTestRepository(t)
	lines := make([]string, 40)
	for i := range lines {
		lines[i] = fmt.Sprintf("line %d", i+1)
	}
	write := func() {
		if err := os.WriteFile(filepath.Join(dir, "long.txt"), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write()
	gitRun(t, dir, "add", "long.txt")
	gitRun(t, dir, "commit", "-m", "long")
	lines[4], lines[34] = "line five", "line thirty-five"
	write()
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	d := openDiffTab(t, h, p, "long.txt")
	if d.file == nil || len(d.changes) != 2 || d.current != 0 {
		t.Fatalf("diff has %d differences, at %d; want 2, at the first", len(d.changes), d.current)
	}
	folds := diffFolds(d)
	if len(folds) == 0 {
		t.Fatalf("no fold over the unchanged lines: %+v", d.items)
	}
	label := i18n.SharedFormat(h.app.language(), "native.lldUnchangedLines", map[string]string{"arg1": fmt.Sprint(folds[0].fold)})
	if !h.shows(label) && !h.shows(i18n.SharedFormat(h.app.language(), "git.diff.differences", map[string]string{"count": "2"})) {
		t.Errorf("the Diff tab shows neither the fold %q nor the count of differences", label)
	}

	d.step(1)
	if d.current != 1 {
		t.Fatalf("after the next difference the tab stands at %d", d.current)
	}
	d.step(1)
	if d.current != 1 {
		t.Fatalf("the next difference went past the last to %d", d.current)
	}

	d.expand(folds[0].at)
	if len(diffFolds(d)) != len(folds)-1 {
		t.Fatalf("opening a fold left %d of %d folds", len(diffFolds(d)), len(folds))
	}
	h.app.setDiffMode(p, d, d.split, true)
	if len(diffFolds(d)) != 0 || !p.diffs.whole {
		t.Fatalf("the whole file still folds %d runs", len(diffFolds(d)))
	}
	h.app.setDiffMode(p, d, true, false)
	if len(diffFolds(d)) == 0 || len(d.changes) != 2 {
		t.Fatalf("side by side, folded: %d folds, %d differences", len(diffFolds(d)), len(d.changes))
	}

	if len(d.files) != 2 {
		t.Fatalf("the tab steps through %d files, want long.txt and changed.txt", len(d.files))
	}
	by := 1
	if d.fileIndex() == 1 {
		by = -1
	}
	h.app.stepFile(p, d, by)
	h.await("the next file's diff", func() bool { return !d.loading })
	if d.change.Path != "changed.txt" || d.file == nil || len(p.diffs.list) != 1 {
		t.Fatalf("the next file is %q in %d tabs", d.change.Path, len(p.diffs.list))
	}
}
