package workbench

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
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

// diffBlocks counts the differences of the tab that carry a block.
func diffBlocks(d *diffTab) int {
	blocks := 0
	if d.layout != nil {
		for _, f := range d.layout.fragments {
			if f.block != nil {
				blocks++
			}
		}
	}
	return blocks
}

// diffFolds are the folded runs of unchanged lines of the tab.
func diffFolds(d *diffTab) []diffFold {
	if d.layout == nil {
		return nil
	}
	return d.layout.folds
}

// commitLongFile commits long.txt with lines, then writes it again as change makes them.
func commitLongFile(t *testing.T, dir string, lines []string, change func([]string) []string) {
	t.Helper()
	write := func(lines []string) {
		if err := os.WriteFile(filepath.Join(dir, "long.txt"), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(lines)
	gitRun(t, dir, "add", "long.txt")
	gitRun(t, dir, "commit", "-m", "long")
	write(change(slices.Clone(lines)))
}

// numberedLines are n lines "line 1" to "line n".
func numberedLines(n int) []string {
	lines := make([]string, n)
	for i := range lines {
		lines[i] = fmt.Sprintf("line %d", i+1)
	}
	return lines
}

func TestDiffTabStagesAndRollsBackABlock(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	d := openDiffTab(t, h, p, "changed.txt")
	if d.plan == nil || len(d.plan.Blocks) != 1 || d.file == nil {
		t.Fatalf("diff = %+v, want a tab with one block", d)
	}
	if blocks := diffBlocks(d); blocks != 1 || d.after == nil || d.before != nil {
		t.Fatalf("unified diff has %d blocks, editors %v and %v; want one block in one editor", blocks, d.before, d.after)
	}
	lang := h.app.language()
	if !h.shows("changed.txt") {
		t.Error("the Diff tab does not show the file's name")
	}
	if _, ok := h.findPageHit(i18n.Shared(lang, "git.diff.unified")); !ok {
		t.Error("the Diff tab has no button of the unified view")
	}

	// The checkbox of the block, in the gap before the editor, stages it.
	block := i18n.SharedFormat(lang, "desktop.gitReview.blockN", map[string]string{"n": "1"})
	h.clickNamed(block + " " + i18n.Shared(lang, "git.diff.includeBlock"))
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
	// Its rollback asks first, in the toolbar, and rolls the block back on the user's word.
	h.clickNamed(block + " " + i18n.Shared(lang, "git.diff.rollbackHunk"))
	if d.confirm != d.plan.Blocks[0].ID {
		t.Fatalf("the rollback did not ask to confirm: %q", d.confirm)
	}
	h.clickNamed(i18n.Shared(lang, "git.rollback.confirm"))
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
	h.settle()
	if diffBlocks(d) != 1 || d.before == nil || d.after == nil {
		t.Fatalf("split view has %d blocks, editors %v and %v; want one block in two editors", diffBlocks(d), d.before, d.after)
	}
	for _, f := range d.layout.fragments {
		if f.block != nil && f.before.empty() && f.after.empty() {
			t.Fatalf("split block %+v has no lines on either side", f)
		}
	}
	// The before editor shows the version of HEAD, the after editor the working tree's.
	if before, after := d.layout.before.text, d.layout.after.text; !strings.Contains(string(before), "first") || strings.Contains(string(after), "first") {
		t.Fatalf("before side %q, after side %q", before, after)
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
	if _, ok := h.findPageHit(i18n.Shared(h.app.language(), "git.diff.unified")); !ok {
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
	commitLongFile(t, dir, numberedLines(40), func(lines []string) []string {
		lines[4], lines[34] = "line five", "line thirty-five"
		return lines
	})
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	d := openDiffTab(t, h, p, "long.txt")
	if d.file == nil || d.differences() != 2 || d.current != 0 {
		t.Fatalf("diff has %d differences, at %d; want 2, at the first", d.differences(), d.current)
	}
	folds := diffFolds(d)
	if len(folds) == 0 {
		t.Fatalf("no fold over the unchanged lines: %+v", d.layout)
	}
	label := i18n.SharedFormat(h.app.language(), "native.lldUnchangedLines", map[string]string{"arg1": fmt.Sprint(folds[0].hidden)})
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

	h.app.revealDiff(d, folds[0].at, diffReveal{all: true})
	if len(diffFolds(d)) != len(folds)-1 {
		t.Fatalf("opening a fold left %d of %d folds", len(diffFolds(d)), len(folds))
	}
	h.app.setDiffMode(p, d, d.split, true)
	if len(diffFolds(d)) != 0 || !p.diffs.whole {
		t.Fatalf("the whole file still folds %d runs", len(diffFolds(d)))
	}
	h.app.setDiffMode(p, d, true, false)
	if len(diffFolds(d)) == 0 || d.differences() != 2 {
		t.Fatalf("side by side, folded: %d folds, %d differences", len(diffFolds(d)), d.differences())
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

// TestDiffTabShowsTheDifferenceRightAfterTheFoldToggle switches a long file between folded and
// whole and back with the toolbar button, and wants the difference shown after the click alone:
// the jump from the top to the middle of the file used to leave the rows blank until the
// pointer moved.
func TestDiffTabShowsTheDifferenceRightAfterTheFoldToggle(t *testing.T) {
	dir := newTestRepository(t)
	lines := numberedLines(300)
	lines[200] = "line two hundred and one"
	commitLongFile(t, dir, numberedLines(300), func(changed []string) []string {
		changed[200] = lines[200]
		return changed
	})
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	d := openDiffTab(t, h, p, "long.txt")
	if d.whole || !h.shows(lines[200]) {
		t.Fatalf("the folded diff does not show the difference %q", lines[200])
	}
	toggle := i18n.Shared(h.app.language(), "native.collapseUnchangedFragments")
	for _, whole := range []bool{true, false, true} {
		h.clickNamed(toggle)
		if d.whole != whole {
			t.Fatalf("after the click the diff is whole %v, want %v", d.whole, whole)
		}
		if !h.shows(lines[200]) || !h.shows(lines[199]) {
			t.Fatalf("whole %v: the difference %q and the line above it are not shown after the click", whole, lines[200])
		}
	}
}

// Side by side the two editors scroll in step: scrolled past lines the working tree inserted,
// the before side stands that many lines higher than the after side.
func TestDiffTabSidesScrollInStep(t *testing.T) {
	dir := newTestRepository(t)
	commitLongFile(t, dir, numberedLines(300), func(lines []string) []string {
		inserted := make([]string, 50)
		for i := range inserted {
			inserted[i] = fmt.Sprintf("inserted %d", i+1)
		}
		return slices.Insert(lines, 100, inserted...)
	})
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	d := openDiffTab(t, h, p, "long.txt")
	h.app.setDiffMode(p, d, true, true)
	h.app.invalidator.Invalidate()
	h.settle()
	if d.before == nil || d.after == nil || d.differences() != 1 {
		t.Fatalf("split diff has editors %v and %v and %d differences", d.before, d.after, d.differences())
	}
	lineH := d.after.view.LineHeight()
	if lineH <= 0 {
		t.Fatal("the after editor was not painted")
	}
	d.after.view.SetScrollOffset(0, 250*lineH)
	h.app.invalidator.Invalidate()
	h.settle()
	h.settle()
	_, before := d.before.view.ScrollOffset()
	_, after := d.after.view.ScrollOffset()
	if after != 250*lineH || before != after-50*lineH {
		t.Fatalf("after side at %v, before side at %v; want the before side 50 lines higher", after/lineH, before/lineH)
	}
	// The user scrolls the before side back: the after side follows it.
	d.before.view.SetScrollOffset(0, 120*lineH)
	h.app.invalidator.Invalidate()
	h.settle()
	h.settle()
	if _, after := d.after.view.ScrollOffset(); after != 170*lineH {
		t.Fatalf("after side at %v following the before side at 120, want 170", after/lineH)
	}
}
