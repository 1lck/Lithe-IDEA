package workbench

import (
	"context"
	"math"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file keeps the Diff tabs. Each shows how one file changed, as a tab of the editor area
// that is selected, moved, split off and closed like an open file's or a terminal's: its
// member in a tab group is "diff:<id>". A tab shows the change of a file in the working tree
// or the index of a checkout, with Core's blocks to stage, unstage and roll back, or the
// change a commit made, read only. It lays the file out side by side or as unified lines,
// folds the unchanged lines between changes, steps through the differences and through the
// other changed files of the same list. As in IDEA, the two versions of the file are two
// read-only editors side by side, colored for the file's language, numbered as in their version,
// with the changed lines tinted, joined across the gap between them and scrolled in step; the
// unified view is one editor of the unified lines. Core decides everything about Git (the
// lines, the blocks and what a write runs); this file sequences the calls and keeps the
// editors' text (built by layoutDiff, diffpanes.go). difftab_view.go declares the tab's body.

const (
	// diffMemberPrefix starts the member name of a Diff tab in a tab group: "diff:3".
	diffMemberPrefix = "diff:"
	// diffContext is how many unchanged lines stay in view on each side of a change while the
	// unchanged lines are folded.
	diffContext = 3
	// diffFoldLeast is the fewest unchanged lines a fold hides; a shorter run stays in view.
	diffFoldLeast = 4
)

// diffSet is the project's Diff tabs and the way the next one opens: in the mode the user last
// chose, side by side or unified, with the unchanged lines folded or the whole file.
type diffSet struct {
	list []*diffTab
	// next is the id the last tab was given; ids are never reused while the project is open.
	next  int
	split bool
	whole bool
	// ignoreSpace reads the diffs ignoring whitespace, for the tabs opened after it is set.
	ignoreSpace bool
}

// find is the tab with id, nil when there is none.
func (s *diffSet) find(id int) *diffTab {
	for _, t := range s.list {
		if t.id == id {
			return t
		}
	}
	return nil
}

// showing is the tab that shows path of the checkout at root, as commit changed it when
// commit is set; nil when no tab does.
func (s *diffSet) showing(root, commit, path string) *diffTab {
	for _, t := range s.list {
		if t.root == root && t.commit == commit && t.change.Path == path {
			return t
		}
	}
	return nil
}

// diffMember is the name of Diff tab id as a member of a tab group.
func diffMember(id int) string { return diffMemberPrefix + strconv.Itoa(id) }

// memberDiff is the Diff tab id a group member names, and false for a member that does not
// name one.
func memberDiff(member string) (int, bool) {
	rest, ok := strings.CutPrefix(member, diffMemberPrefix)
	if !ok {
		return 0, false
	}
	id, err := strconv.Atoi(rest)
	return id, err == nil && id > 0
}

// selectedDiff is the Diff tab group shows, nil when it shows a file, a terminal or nothing.
func (p *project) selectedDiff(group string) *diffTab {
	g := p.terms.bench.Group(group)
	if g == nil {
		return nil
	}
	if id, ok := memberDiff(g.Selected); ok {
		return p.diffs.find(id)
	}
	return nil
}

// diffTab is one Diff tab: which change of which file it shows, what Core read for it and the
// rows laid out from that.
type diffTab struct {
	id      int
	loading bool
	// gen counts the loads; the answer of an older one is dropped.
	gen int
	err string
	// root is the checkout the change is in: the project's repository or another of its
	// worktrees.
	root   string
	change core.GitChange
	// staged says the tab shows the index against HEAD, for a change that is only staged.
	staged bool
	// commit is the commit whose change of the file the tab shows against its first parent,
	// "" for a change of the working tree. A commit's change is read only. For a stash it is
	// the stash's commit, and stash holds what the tab shows; for a comparison it is the
	// comparison's key, and compare holds its two sides.
	commit string
	// stash is the stash whose saved file the tab shows, nil for any other change.
	stash *stashSource
	// compare is the comparison of two references whose file the tab shows, nil for any other
	// change.
	compare *diffComparison
	// files are the changed files the tab steps through with its previous and next file
	// buttons: the commit's files, or the checkout's changes when the tab opened.
	files []core.GitChange
	// split shows the two sides next to each other instead of the unified lines, and whole
	// shows every unchanged line instead of folding the long runs of them.
	split, whole bool
	// ignoreSpace reads the diff ignoring all whitespace (see setDiffWhitespace).
	ignoreSpace bool
	// expanded are the folds the user opened, by the unified index of the first unchanged line
	// of the run they hide, which is the same in both modes.
	expanded map[int]bool
	file     *core.GitDiffFile
	plan     *core.DiffBlockPlan
	// grammar colors the text of the file at grammarPath; it is found away from the window
	// thread, and nil shows the text in one color.
	grammar     *syntax.Syntax
	grammarPath string
	// layout is what the editors show, built from file and plan for the modes; nil while the
	// tab has no file.
	layout *diffLayout
	// before and after are the editors of the two versions; the unified view shows only after.
	// They are made with the first layout of a file and closed with the tab.
	before, after *diffEditor
	// find is the find bar of the tab (diff_find.go).
	find diffFind
	// revealLine is the 1-based line of the after side the tab goes to once its layout is ready;
	// zero when nothing is pending (gitlinehistory.go).
	revealLine int
	// gap is the strip between the two editors, or before the unified one, that joins each
	// difference across and carries its block's checkbox and rollback; gapDraw paints it.
	gap     ui.Handlers
	gapDraw func(*ui.DrawContext)
	// numberCells is how many cells the widest line number of the before side takes: the gap
	// shows those numbers beside the before editor, as IDEA does, and is as wide as they are.
	// cellW is the width of a cell at the last paint of the gap.
	numberCells int
	cellW       float32
	// current is the difference, the fragment of the layout, the user last stepped to; -1
	// before the first step.
	current int
	// revealed says the first difference was scrolled into view since the file was read.
	revealed bool
	// busy is set while a block is written.
	busy bool
	// confirm is the block waiting for the user to confirm its rollback, "" for none.
	confirm string
	// note is a refusal to show: the plan went stale, or a rollback is unsafe.
	note string
	// ruler paints the marks of the differences beside the editors, made once.
	ruler func(*ui.DrawContext)
}

// diffEditor is the editor of one side of a Diff tab: a read-only view of the side's lines,
// colored for the file's language, with the gutter numbering them as in that version and the
// changed lines tinted.
type diffEditor struct {
	view *editorview.View
	// label names the view's control: the side and the path.
	label string
	// grammar is the grammar the view was made with.
	grammar *syntax.Syntax
	hit     gfx.ID
	input   ui.Handlers
	draw    func(*ui.DrawContext)
	// decorated and palette are the layout and the colors the view's labels, notes and tints
	// were last set from.
	decorated *diffLayout
	palette   diffPalette
	// x and y are the scroll the tab last saw the view at: a scroll that differs is the
	// user's, and the other side follows it.
	x, y float32
}

// stashSource is the stash a Diff tab shows a saved file of: the name its sides are labelled
// with, and the files Core read for it, which the tab shows and steps through without asking
// Git again.
type stashSource struct {
	label string
	files []core.GitDiffFile
}

// diffComparison is the comparison a Diff tab shows a file of: base against target, or against
// the working tree when target is nil.
type diffComparison struct {
	base   core.GitReference
	target *core.GitReference
}

// key is the comparison's identity among the tabs, kept in their commit: a comparison's file
// opens in the tab that already shows it.
func (c *diffComparison) key() string {
	target := "worktree"
	if c.target != nil {
		target = c.target.FullName
	}
	return "compare:" + c.base.FullName + ".." + target
}

// diffOrigin is where a Diff tab of a commit reads its file instead of the commit: the files
// a stash saved, or the comparison of two references. The zero value reads the commit, or the
// working tree.
type diffOrigin struct {
	stash   *stashSource
	compare *diffComparison
}

// name is the title of the tab: the name of the file.
func (t *diffTab) name() string { return path.Base(t.change.Path) }

// readOnly says the tab's right side cannot be written: a commit's change, or the index.
func (t *diffTab) readOnly() bool { return t.commit != "" || t.staged }

// untracked says the tab shows a file Git does not track yet.
func (t *diffTab) untracked() bool {
	return t.change.Untracked || t.change.Status == "??"
}

// openDiff opens the Diff tab of a change of the project's repository and reads it in the
// background.
func (a *App) openDiff(p *project, change core.GitChange) *diffTab {
	return a.openDiffIn(p, p.git.repositoryRoot(p.root), change)
}

// openDiffIn opens the Diff tab of a change of the checkout at root. The tab steps through the
// checkout's other changes.
func (a *App) openDiffIn(p *project, root string, change core.GitChange) *diffTab {
	t := a.showDiff(p, root, "", change, a.changeSiblings(p, root), diffOrigin{})
	if t != nil {
		a.performed("git.diff.open", surfaceMenu)
	}
	return t
}

// openCommitDiff opens the Diff tab of what commit changed in file, against the commit's first
// parent, in the repository at root. The tab steps through the commit's other files.
func (a *App) openCommitDiff(p *project, root, commit string, file core.GitCommitFile) *diffTab {
	if commit == "" || file.Path == "" {
		return nil
	}
	var files []core.GitChange
	if p.log.selected == commit {
		for _, f := range p.log.files {
			files = append(files, core.GitChange{Path: f.Path, Status: f.Status})
		}
	}
	t := a.showDiff(p, root, commit, core.GitChange{Path: file.Path, Status: file.Status}, files, diffOrigin{})
	if t != nil {
		a.performed("git.diff.openCommit", surfaceButton)
	}
	return t
}

// openStashDiff opens the Diff tab of the file at path that stash saved, from the files read for
// it, in the repository at root. The tab steps through the stash's other files.
func (a *App) openStashDiff(p *project, root string, stash core.GitStash, path string, files []core.GitDiffFile) *diffTab {
	i := slices.IndexFunc(files, func(f core.GitDiffFile) bool { return f.Path == path })
	if stash.OID == "" || i < 0 {
		return nil
	}
	changes := make([]core.GitChange, len(files))
	for j, f := range files {
		changes[j] = core.GitChange{Path: f.Path, OriginalPath: f.OriginalPath, Status: f.Status}
	}
	source := &stashSource{label: stash.Reference, files: files}
	t := a.showDiff(p, root, stash.OID, changes[i], changes, diffOrigin{stash: source})
	if t != nil {
		a.performed("git.diff.openStash", surfaceButton)
	}
	return t
}

// changeSiblings are the changed files of the checkout at root a Diff tab steps through: the
// project's status for its own repository, the listed changes for another worktree, without
// the summarized untracked directories.
func (a *App) changeSiblings(p *project, root string) []core.GitChange {
	var changes []core.GitChange
	if root == p.git.repositoryRoot(p.root) {
		changes = p.git.status.Changes
	} else if w := p.worktrees.changes[root]; w != nil {
		changes = w.changes
	}
	files := make([]core.GitChange, 0, len(changes))
	for _, change := range changes {
		if !strings.HasSuffix(change.Path, "/") {
			files = append(files, change)
		}
	}
	return files
}

// showDiff shows change in a Diff tab and reads it: the tab that already shows the file, or a
// new one in the group a file opens in. It is nil when the window's kernel has no review
// commands, for a summarized directory, and when the kernel refuses the new tab.
func (a *App) showDiff(p *project, root, commit string, change core.GitChange, files []core.GitChange, origin diffOrigin) *diffTab {
	if _, ok := a.reviewKernel(); !ok || change.Path == "" || strings.HasSuffix(change.Path, "/") {
		return nil
	}
	s := &p.diffs
	t := s.showing(root, commit, change.Path)
	if t == nil {
		t = &diffTab{id: s.next + 1, root: root, commit: commit, split: s.split, whole: s.whole, ignoreSpace: s.ignoreSpace, current: -1}
		if !a.placeDiff(p, t.id) {
			return nil
		}
		s.next = t.id
		s.list = append(s.list, t)
	}
	t.files, t.stash, t.compare = files, origin.stash, origin.compare
	t.show(change)
	a.selectDiff(p, t.id)
	a.loadDiff(p, t)
	return t
}

// placeDiff opens the member of Diff tab id in the group a file opens in, made first when the
// editor has no group, and reports whether the kernel accepted it.
func (a *App) placeDiff(p *project, id int) bool {
	set := &p.terms
	state := set.bench
	group, added := a.documentGroup(p), ""
	if group == "" {
		added = editorGroupID(set.nextGroup + 1)
		state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: added})
		group = added
	}
	if !a.reduceTerminals(p, state, core.OpenEditor(group, diffMember(id), true)) {
		return false
	}
	if added != "" {
		set.nextGroup++
		set.layout = newLeaf(added)
	}
	return true
}

// show makes the tab show change of its checkout or commit, forgetting what it read before.
// Another file gets editors of its own, made for its language and scrolled to its top.
func (t *diffTab) show(change core.GitChange) {
	if change.Path != t.change.Path {
		t.closeEditors()
	}
	t.change = change
	t.staged = t.commit == "" && change.Staged && !change.Worktree
	t.file, t.plan, t.layout = nil, nil, nil
	t.expanded, t.current, t.revealed = nil, -1, false
	t.err, t.note, t.confirm = "", "", ""
}

// closeEditors closes the editors of the two sides.
func (t *diffTab) closeEditors() {
	for _, e := range []*diffEditor{t.before, t.after} {
		if e != nil {
			e.view.Close()
		}
	}
	t.before, t.after = nil, nil
}

// closeDiffs closes the editors of every Diff tab of the project, which is closing.
func (p *project) closeDiffs() {
	for _, t := range p.diffs.list {
		t.gen++
		t.closeEditors()
	}
	p.diffs.list = nil
}

// selectDiff shows Diff tab id in its group and gives its list the keyboard. Files open in
// its group after it.
func (a *App) selectDiff(p *project, id int) {
	member := diffMember(id)
	g := p.terms.bench.GroupOf(member)
	if g == nil {
		return
	}
	if g.Selected != member && !a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(g.ID, member)) {
		return
	}
	p.docs.group = g.ID
	a.focus = focusTarget{diff: id}
}

// closeDiffTab closes Diff tab id. Its group shows the neighbouring tab instead and gives it
// the keyboard; a group of the editor that this leaves empty goes, with its place in the
// layout.
func (a *App) closeDiffTab(p *project, id int) {
	t := p.diffs.find(id)
	if t == nil {
		return
	}
	member := diffMember(id)
	if g := p.terms.bench.GroupOf(member); g != nil {
		group := g.ID
		if !a.reduceTerminals(p, p.terms.bench, core.CloseEditor(group, member, emptyPolicy(group), core.SelectAdjacent)) {
			return
		}
		a.focusSelected(p, group)
	}
	t.gen++
	t.closeEditors()
	p.diffs.list = slices.DeleteFunc(p.diffs.list, func(x *diffTab) bool { return x == t })
}

// focusSelected gives the keyboard to what group shows: a file, a Diff tab or a terminal.
func (a *App) focusSelected(p *project, group string) {
	switch {
	case p.selectedDocument(group) != nil:
		a.focusDocument(p.selectedDocument(group).id)
	case p.selectedDiff(group) != nil:
		a.focus = focusTarget{diff: p.selectedDiff(group).id}
	case p.terms.selected(group) != nil:
		a.focusTerminal(p.terms.selected(group).id)
	}
}

// target is the file of the tab as Core's block commands take it.
func (t *diffTab) target() core.DiffBlockTarget {
	return core.DiffBlockTarget{Root: t.root, Path: t.change.Path, OriginalPath: t.change.OriginalPath, Staged: t.staged}
}

// live says t is still a tab of the project and gen is still its latest load.
func (p *project) live(t *diffTab, gen int) bool {
	return p.diffs.find(t.id) == t && t.gen == gen
}

// loadDiff reads the diff of the tab's change again: the block plan for a tracked file of the
// working tree or the index, and the diff of the whole file for an untracked one, for a commit's
// change, for a comparison's file and for a file the plan has no section for. A stash's file was
// read with the stash, so it shows at once.
func (a *App) loadDiff(p *project, t *diffTab) {
	kernel, ok := a.reviewKernel()
	if !ok {
		return
	}
	a.loadDiffGrammar(p, t)
	if t.stash != nil {
		t.loading, t.gen = false, t.gen+1
		i := slices.IndexFunc(t.stash.files, func(f core.GitDiffFile) bool { return f.Path == t.change.Path })
		if i < 0 {
			t.err = i18n.Shared(a.language(), "git.diff.noChangesInStash")
			return
		}
		file := t.stash.files[i]
		a.readDiff(t, &file, nil)
		return
	}
	t.loading, t.gen = true, t.gen+1
	gen, change, target, commit, untracked, compare := t.gen, t.change, t.target(), t.commit, t.untracked(), t.compare
	// The block plan of a working-tree change is read without whitespace rules, so a diff that
	// ignores whitespace reads its file instead; its blocks cannot be staged meanwhile.
	ignore := t.ignoreSpace
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		var (
			file *core.GitDiffFile
			plan *core.DiffBlockPlan
			err  error
		)
		if commit == "" && !untracked && !ignore {
			var got core.DiffBlockPlan
			if got, err = kernel.PlanDiffBlocks(ctx, target); err == nil {
				plan = &got
				if got.Worktree != nil && len(got.Worktree.Files) > 0 {
					file = &got.Worktree.Files[0]
				}
			}
		}
		if err == nil && file == nil {
			plan = nil
			var files []core.GitDiffFile
			// The editors show both versions in full, so the diff is read with the whole file
			// as its context, as the block plan is.
			request := core.GitDiffRequest{Root: target.Root, Path: change.Path, Commit: commit, WholeFile: true}
			switch {
			case compare != nil:
				base := compare.base
				request = core.GitDiffRequest{Root: target.Root, Path: change.Path, Base: &base, Target: compare.target, Untracked: untracked, WholeFile: true}
			case commit == "":
				request.Staged, request.Untracked = target.Staged, untracked
			}
			request.IgnoreAllWhitespace = ignore
			files, err = kernel.GitDiff(ctx, request)
			if err == nil && len(files) > 0 {
				file = &files[0]
			}
		}
		return func(a *App) {
			if !p.live(t, gen) {
				return
			}
			t.loading = false
			if err != nil {
				t.err = i18n.SharedFormat(a.language(), "git.diff.getFileDiffFailed", map[string]string{"file": change.Path, "error": reviewReason(err)})
				a.gitOperationFailed("git_diff", err)
				return
			}
			a.readDiff(t, file, plan)
		}
	})
}

// loadDiffGrammar finds the grammar of the tab's file away from the window thread, once for a
// file. The editors were made without it in the meantime, so they are made again with it, at
// the scroll they had.
func (a *App) loadDiffGrammar(p *project, t *diffTab) {
	path := t.change.Path
	if t.grammarPath == path {
		return
	}
	t.grammarPath, t.grammar = path, nil
	registry := a.syntaxRegistry()
	a.background(p, 0, func(context.Context) func(*App) {
		var grammar *syntax.Syntax
		if language, ok := registry.ForPath(path); ok {
			grammar = registry.Syntax(language.ID)
		}
		return func(a *App) {
			if p.diffs.find(t.id) != t || t.grammarPath != path || grammar == nil {
				return
			}
			t.grammar = grammar
			a.presentDiff(t)
		}
	})
}

// readDiff shows what was read for the tab's file and, the first time after the file changed,
// scrolls to its first difference.
func (a *App) readDiff(t *diffTab, file *core.GitDiffFile, plan *core.DiffBlockPlan) {
	t.err, t.file, t.plan = "", file, plan
	a.rebuildDiff(t)
	if !t.revealed {
		t.revealed = true
		t.step(1)
	}
}

// reloadDiffs reads again every tab that shows a change of the working tree or the index of the
// checkout at root, a comparison with the working tree among them, after something wrote to it.
func (a *App) reloadDiffs(p *project, root string) {
	for _, t := range p.diffs.list {
		if t.root == root && (t.commit == "" || (t.compare != nil && t.compare.target == nil)) {
			a.loadDiff(p, t)
		}
	}
}

// rebuildDiff lays the tab's file out again for its modes and hands the text to the editors:
// each side's lines in split mode, the unified lines otherwise, with the long runs of unchanged
// lines folded unless the tab shows the whole file or the user opened them.
func (a *App) rebuildDiff(t *diffTab) {
	if t.file == nil {
		t.layout = nil
		return
	}
	lang := a.language()
	t.layout = layoutDiff(t.file.Lines, t.blockAnchors(), t.split, t.whole, t.expanded, func(n int) string {
		return i18n.SharedFormat(lang, "native.lldUnchangedLines", map[string]string{"arg1": strconv.Itoa(n)})
	})
	t.numberCells = 0
	for _, label := range t.layout.before.labels {
		t.numberCells = max(t.numberCells, len(label))
	}
	t.current = min(t.current, len(t.layout.fragments)-1)
	a.presentDiff(t)
	a.applyDiffReveal(t)
}

// presentDiff hands the tab's layout to its editors: the before side's only side by side, the
// after side's always. An editor is made when the side has none yet or its grammar changed.
func (a *App) presentDiff(t *diffTab) {
	l := t.layout
	if l == nil {
		return
	}
	if l.split {
		t.before = a.diffSideEditor(t, t.before, &l.before, true)
	} else if t.before != nil {
		t.before.view.Close()
		t.before = nil
	}
	t.after = a.diffSideEditor(t, t.after, &l.after, false)
}

// diffSideEditor shows pane in e, or in a new editor when e is nil or was made with another
// grammar; a new editor takes the scroll of the one it replaces.
func (a *App) diffSideEditor(t *diffTab, e *diffEditor, pane *diffPane, before bool) *diffEditor {
	content := editorview.Prepare(pane.text)
	if e != nil && e.grammar == t.grammar {
		e.view.ShowContent(content)
		e.decorated = nil
		return e
	}
	var x, y float32
	if e != nil {
		x, y = e.view.ScrollOffset()
		e.view.Close()
	}
	left, right := a.diffSideLabels(t)
	label := right + " " + t.change.Path
	if before {
		label = left + " " + t.change.Path
	}
	e = &diffEditor{label: label, grammar: t.grammar, x: x, y: y}
	e.view = editorview.New(editorview.Config{Label: label, Content: content, Syntax: t.grammar, Notify: a.invalidator.Invalidate})
	e.view.SetReadOnly(true)
	e.view.SetWrap(false)
	e.view.SetMinimap(false)
	e.view.SetScrollOffset(x, y)
	a.diffEditorInput(t, e, before)
	return e
}

// diffEditorInput makes the handlers and the painter of editor e of tab t, once, when it is
// made. A press on a fold's line opens the fold; anything else is the editor's.
func (a *App) diffEditorInput(t *diffTab, e *diffEditor, before bool) {
	e.input = ui.Handlers{
		Role: gfx.RoleTerminal,
		Key: func(event gfx.KeyEvent) gfx.EventResult {
			if a.diffFindChord(t, event) {
				return gfx.EventResult{Handled: true, Repaint: true}
			}
			result, _ := e.view.Key(event)
			return result
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			if a.diffFoldPressed(t, e, before, event) {
				return gfx.EventResult{Handled: true, Repaint: true}
			}
			result, _ := e.view.Pointer(event)
			return result
		},
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			result, _ := e.view.Scroll(event)
			return result
		},
		Text: e.view.TextInput,
	}
	e.draw = func(dc *ui.DrawContext) { a.drawDiffEditor(dc, t, e, before) }
}

// diffFoldPressed opens the fold whose line the primary button pressed on in editor e, and
// reports whether there was one.
func (a *App) diffFoldPressed(t *diffTab, e *diffEditor, before bool, event gfx.PointerEvent) bool {
	if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary || event.Target != e.hit || t.layout == nil {
		return false
	}
	line, ok := e.view.LineAt(event.Y)
	if !ok {
		return false
	}
	fold, ok := t.layout.foldAt(line, before)
	if !ok {
		return false
	}
	a.expandDiff(t, fold.at)
	return true
}

// followDiffScroll keeps the two sides in step: when the user scrolled one of them, the other
// is scrolled to the place that matches the middle of its view, and sideways as far, on a whole
// pixel so its text stays sharp. height is the height of the editors. A side moved after it was
// painted is painted again.
func (a *App) followDiffScroll(t *diffTab, height float32) {
	l, b, f := t.layout, t.before, t.after
	if l == nil || !l.split || b == nil || f == nil {
		return
	}
	bx, by := b.view.ScrollOffset()
	ax, ay := f.view.ScrollOffset()
	lineH := max(b.view.LineHeight(), f.view.LineHeight())
	switch {
	case lineH <= 0:
	case bx != b.x || by != b.y:
		y := l.mapLine(float64((by+height/2)/lineH), true)
		f.view.SetScrollOffset(bx, float32(math.Round(y*float64(lineH)-float64(height/2))))
		a.invalidator.Invalidate()
	case ax != f.x || ay != f.y:
		y := l.mapLine(float64((ay+height/2)/lineH), false)
		b.view.SetScrollOffset(ax, float32(math.Round(y*float64(lineH)-float64(height/2))))
		a.invalidator.Invalidate()
	}
	b.x, b.y = b.view.ScrollOffset()
	f.x, f.y = f.view.ScrollOffset()
}

// blockAnchors maps the unified line each block starts at to the block.
func (t *diffTab) blockAnchors() map[int]*core.DiffBlock {
	anchors := map[int]*core.DiffBlock{}
	if t.plan == nil {
		return anchors
	}
	for i := range t.plan.Blocks {
		if n, ok := blockLine(t.plan.Blocks[i].ID); ok {
			anchors[n] = &t.plan.Blocks[i]
		}
	}
	return anchors
}

// blockLine is the unified-line index a block ID names ("line-<index>").
func blockLine(id string) (int, bool) {
	rest, ok := strings.CutPrefix(id, "line-")
	if !ok || rest == "" {
		return 0, false
	}
	n := 0
	for _, r := range rest {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n*10 + int(r-'0')
	}
	return n, true
}

// differences is how many differences the tab shows.
func (t *diffTab) differences() int {
	if t.layout == nil {
		return 0
	}
	return len(t.layout.fragments)
}

// step moves by differences, forward for a positive by, and scrolls the one it lands on to the
// middle of the editors. It stops at the first and the last.
func (t *diffTab) step(by int) {
	n := t.differences()
	if n == 0 {
		return
	}
	t.current = min(max(t.current+by, 0), n-1)
	t.scrollToCurrent()
}

// scrollToCurrent scrolls the difference the user stands on to the middle of the editors and
// puts their carets on it. When the sides disagree, at an end of the file, the before side wins
// and the after side follows it (see followDiffScroll).
func (t *diffTab) scrollToCurrent() {
	l := t.layout
	if l == nil || t.current < 0 || t.current >= len(l.fragments) || t.after == nil {
		return
	}
	f := l.fragments[t.current]
	// Each side puts its caret on the difference and centers it, so the caret never stays on a
	// fold's row and the two sides agree when they follow each other.
	center := func(e *diffEditor, span diffSpan) {
		e.view.GoToLine(span.start + 1)
		e.view.CenterLine(span.start + max(span.end-span.start-1, 0)/2)
	}
	center(t.after, f.after)
	if l.split && t.before != nil {
		center(t.before, f.before)
	}
}

// setMode lays the tab out side by side or unified, folded or whole, and remembers the choice
// for the next tab. The difference the user stood on stays in view.
func (a *App) setDiffMode(p *project, t *diffTab, split, whole bool) {
	if t.whole != whole {
		t.expanded = nil
	}
	t.split, t.whole = split, whole
	p.diffs.split, p.diffs.whole = split, whole
	a.rebuildDiff(t)
	if t.current >= 0 {
		t.scrollToCurrent()
	}
}

// expandDiff opens the fold of tab t that starts at unified line at.
func (a *App) expandDiff(t *diffTab, at int) {
	if t.expanded == nil {
		t.expanded = map[int]bool{}
	}
	t.expanded[at] = true
	a.rebuildDiff(t)
}

// fileIndex is the position of the tab's file among the files it steps through, -1 when it is
// not one of them.
func (t *diffTab) fileIndex() int {
	return slices.IndexFunc(t.files, func(c core.GitChange) bool { return c.Path == t.change.Path })
}

// stepFile shows the previous or the next of the files the tab steps through, for a negative or
// a positive by. A change of the working tree is looked up again in the checkout's changes, so
// the tab reads it as it is now.
func (a *App) stepFile(p *project, t *diffTab, by int) {
	i := t.fileIndex()
	if i < 0 || t.busy {
		return
	}
	next := i + by
	if next < 0 || next >= len(t.files) {
		return
	}
	change := t.files[next]
	if t.commit == "" {
		if fresh := a.changeSiblings(p, t.root); slices.ContainsFunc(fresh, func(c core.GitChange) bool { return c.Path == change.Path }) {
			t.files = fresh
			change = fresh[slices.IndexFunc(fresh, func(c core.GitChange) bool { return c.Path == change.Path })]
		}
	}
	t.show(change)
	a.performed("git.diff.stepFile", surfaceButton)
	a.loadDiff(p, t)
}

// openDiffFile opens the tab's file of the working tree in the editor.
func (a *App) openDiffFile(p *project, t *diffTab) {
	a.openFile(p, filepath.Join(t.root, filepath.FromSlash(t.change.Path)))
}

// toggleDiffBlock stages the block, or unstages it when it is staged.
func (a *App) toggleDiffBlock(p *project, t *diffTab, block core.DiffBlock) {
	action := core.DiffBlockInclude
	if block.Checked {
		action = core.DiffBlockExclude
	}
	a.writeDiffBlock(p, t, block.ID, action)
}

// writeDiffBlock applies one action to a block of the plan the tab shows, then reads again the
// tabs of the checkout. A plan that went stale is read again too, so the user reviews the file
// as it is now.
func (a *App) writeDiffBlock(p *project, t *diffTab, id string, action core.DiffBlockAction) {
	kernel, ok := a.reviewKernel()
	if !ok || t.busy || t.plan == nil {
		return
	}
	t.busy, t.confirm, t.note = true, "", ""
	plan, target, root := *t.plan, t.target(), t.root
	a.performed("git.diff.block."+string(action), surfaceButton)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		err := kernel.ApplyDiffBlock(ctx, plan, target, id, action)
		return func(a *App) {
			a.checkoutWritten(p, root)
			if p.diffs.find(t.id) != t {
				return
			}
			t.busy = false
			if err != nil {
				a.diffBlockRefused(t, err)
			}
			a.reloadDiffs(p, root)
		}
	})
}

// diffBlockRefused tells the user in the tab why Core refused a block write and logs it.
func (a *App) diffBlockRefused(t *diffTab, err error) {
	switch text := err.Error() + " " + reviewReason(err); {
	case strings.Contains(text, "GIT_DIFF_BLOCK_STALE"), strings.Contains(text, "GIT_DIFF_BLOCK_UNAVAILABLE"):
		t.note = i18n.Shared(a.language(), "git.diff.hunkStale")
	case strings.Contains(text, "GIT_HUNK_ROLLBACK_UNSAFE"):
		t.note = i18n.Shared(a.language(), "git.diff.rollbackUnsafe")
	default:
		t.note = i18n.Shared(a.language(), "git.diff.stageFailed")
	}
	a.gitOperationFailed("git_diff_block", err)
}
