package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// newTopicRepository is newTestRepository with a branch topic one commit ahead of main, which
// adds topic.txt, and an untracked notes.txt beside the change of changed.txt.
func newTopicRepository(t *testing.T) string {
	t.Helper()
	dir := newTestRepository(t)
	write := func(name, value string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, dir, "checkout", "-b", "topic")
	write("topic.txt", "topic\n")
	gitRun(t, dir, "add", "topic.txt")
	gitRun(t, dir, "commit", "-m", "topic")
	gitRun(t, dir, "checkout", "main")
	write("notes.txt", "note\n")
	return dir
}

// comparisonTab is the Diff tab of path that the comparison of base with target shows, nil
// when none does; target "" stands for the working tree.
func comparisonTab(p *project, base, target, path string) *diffTab {
	c := &diffComparison{base: core.GitReference{FullName: base}}
	if target != "" {
		c.target = &core.GitReference{FullName: target}
	}
	return p.diffs.showing(p.git.repositoryRoot(p.root), c.key(), path)
}

// The reference pane's compare button compares the current branch with the selected one and
// opens a read-only Diff tab of the file that differs, its sides named after the branches.
func TestBranchStripeComparesTheSelectedBranchWithTheCurrentOne(t *testing.T) {
	dir := newTopicRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	g := h.app.text.Git

	p.log.refSelected = "refs/heads/topic"
	h.app.post(func(*App) {})
	h.settle()
	h.clickNamed(g.CompareWithCurrent)
	h.await("the comparison", func() bool { return !p.log.comparing })
	h.settleChain()
	d := comparisonTab(p, "refs/heads/main", "refs/heads/topic", "topic.txt")
	if d == nil || !d.readOnly() || d.err != "" || len(d.files) != 1 {
		t.Fatalf("comparison Diff tab = %+v, want a read-only tab of topic.txt alone", d)
	}
	h.await("the file's diff", func() bool { return !d.loading })
	if d.file == nil || d.err != "" {
		t.Fatalf("comparison Diff tab read %+v (%q), want topic.txt's diff", d.file, d.err)
	}
	if left, right := h.app.diffSideLabels(d); left != "main" || right != "topic" {
		t.Fatalf("comparison Diff tab sides %q and %q, want main and topic", left, right)
	}
}

// The filter bar's compare button compares the current branch with the working tree, the
// untracked files among the files, and the tab steps to an untracked one and reads it.
func TestLogToolbarComparesTheCurrentBranchWithTheWorkingTree(t *testing.T) {
	dir := newTopicRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	g := h.app.text.Git

	h.clickNamed(g.CompareBranch)
	h.await("the comparison", func() bool { return !p.log.comparing })
	h.settleChain()
	i := slices.IndexFunc(p.diffs.list, func(d *diffTab) bool { return d.compare != nil })
	if i < 0 {
		t.Fatal("comparing with the working tree opened no Diff tab")
	}
	d := p.diffs.list[i]
	paths := make([]string, len(d.files))
	for j, f := range d.files {
		paths[j] = f.Path
	}
	slices.Sort(paths)
	if !slices.Equal(paths, []string{"changed.txt", "notes.txt"}) {
		t.Fatalf("comparison files %v, want changed.txt and the untracked notes.txt", paths)
	}
	if left, right := h.app.diffSideLabels(d); left != "main" || right != i18n.Shared(h.app.language(), "git.saved.worktree") {
		t.Fatalf("comparison Diff tab sides %q and %q, want main and the working tree", left, right)
	}
	for d.change.Path != "notes.txt" {
		h.app.stepFile(p, d, 1)
	}
	h.await("the untracked file's diff", func() bool { return !d.loading })
	if !d.untracked() || d.file == nil || d.err != "" {
		t.Fatalf("untracked comparison file read %+v (%q), want notes.txt's diff", d.file, d.err)
	}
	if comparisonTab(p, "refs/heads/main", "", "notes.txt") != d {
		t.Fatal("the comparison's tab is not found by its key")
	}
}

// A comparison with nothing to show opens no tab and says so.
func TestComparisonWithoutDifferencesSaysSo(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)

	h.app.compareReferences(p, p.log.currentReference(), nil)
	h.await("the comparison", func() bool { return !p.log.comparing })
	h.settle()
	if len(p.diffs.list) != 0 || h.app.notice != i18n.Shared(h.app.language(), "git.diff.noDifferences") {
		t.Fatalf("tabs %d, notice %q; want no tab and the notice that nothing differs", len(p.diffs.list), h.app.notice)
	}
}

// With HEAD detached the compare button compares HEAD with the working tree, and with another
// reference selected it is unavailable: Core compares a revision only with the working tree.
func TestPrimaryComparisonOfADetachedHead(t *testing.T) {
	topic := core.GitReference{FullName: "refs/heads/topic", ShortName: "topic", Kind: "local"}
	l := &gitLogState{}
	l.sections[0].refs = []core.GitReference{topic}
	if base, target, ok := l.primaryComparison(); !ok || target != nil || base.FullName != "HEAD" {
		t.Fatalf("detached without a selection: %+v %+v %v, want HEAD with the working tree", base, target, ok)
	}
	l.refSelected = topic.FullName
	if _, _, ok := l.primaryComparison(); ok {
		t.Fatal("detached with a branch selected: the comparison is offered")
	}
}

// The reference pane's settings menu opens the fetch options dialog.
func TestBranchSettingsMenuOpensTheFetchOptions(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	p := h.openLog(t, dir)
	g := h.app.text.Git

	h.clickNamed(g.BranchSettings)
	if p.log.popover != logPopoverBranchSettings {
		t.Fatalf("popover %v after clicking the settings button, want its menu", p.log.popover)
	}
	h.clickNamed(g.FetchOptions)
	h.settle()
	if p.log.sync.dialog != syncDialogFetch || p.log.popover != logPopoverNone {
		t.Fatalf("sync dialog %v popover %v, want the fetch options and the menu closed", p.log.sync.dialog, p.log.popover)
	}
}
