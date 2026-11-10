package workbench

import (
	"context"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file keeps the Diff tabs. Each shows how one file changed, as a tab of the editor area
// that is selected, moved, split off and closed like an open file's or a terminal's: its
// member in a tab group is "diff:<id>". A tab shows the change of a file in the working tree
// or the index of a checkout, with Core's blocks to stage, unstage and roll back, or the
// change a commit made, read only. It lays the file out side by side or as unified lines,
// folds the unchanged lines between changes, steps through the differences and through the
// other changed files of the same list. Core decides everything about Git (the lines, the
// rows, the blocks and what a write runs); this file sequences the calls and lays the rows
// out. difftab_view.go declares the tab's body.

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
	// "" for a change of the working tree. A commit's change is read only.
	commit string
	// files are the changed files the tab steps through with its previous and next file
	// buttons: the commit's files, or the checkout's changes when the tab opened.
	files []core.GitChange
	// split shows the two sides next to each other instead of the unified lines, and whole
	// shows every unchanged line instead of folding the long runs of them.
	split, whole bool
	// expanded are the folds the user opened, by the first line or row they hide.
	expanded map[int]bool
	file     *core.GitDiffFile
	plan     *core.DiffBlockPlan
	// items is what the list shows, built from file and plan; builtSplit and builtWhole are
	// the modes it was built for.
	items                  []diffItem
	builtSplit, builtWhole bool
	// changes are the items that start a difference, a run of changed lines, and current the
	// one the user last stepped to, -1 before the first step.
	changes []int
	current int
	// revealed says the first difference was scrolled into view since the file was read.
	revealed bool
	list     ui.ListState
	// busy is set while a block is written.
	busy bool
	// confirm is the block waiting for the user to confirm its rollback, "" for none.
	confirm string
	// note is a refusal to show: the plan went stale, or a rollback is unsafe.
	note string
	// ruler paints the marks of the differences beside the list, made once.
	ruler func(*ui.DrawContext)
}

// diffItem is one row of a Diff tab's list: a line or an aligned row of the file, the header
// of a block that carries its toggle and rollback, or a fold that stands for unchanged lines.
type diffItem struct {
	// block is the block a header row belongs to; nil for any other row.
	block *core.DiffBlock
	// number is the 1-based position of the block among the blocks.
	number int
	// line indexes the unified lines, row the aligned rows; -1 for the one the mode does not
	// show and for a header or a fold.
	line, row int
	// fold is how many lines a fold row hides, 0 for any other row, and at the first of them.
	fold, at int
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
	t := a.showDiff(p, root, "", change, a.changeSiblings(p, root))
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
	t := a.showDiff(p, root, commit, core.GitChange{Path: file.Path, Status: file.Status}, files)
	if t != nil {
		a.performed("git.diff.openCommit", surfaceButton)
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
func (a *App) showDiff(p *project, root, commit string, change core.GitChange, files []core.GitChange) *diffTab {
	if _, ok := a.reviewKernel(); !ok || change.Path == "" || strings.HasSuffix(change.Path, "/") {
		return nil
	}
	s := &p.diffs
	t := s.showing(root, commit, change.Path)
	if t == nil {
		t = &diffTab{id: s.next + 1, root: root, commit: commit, split: s.split, whole: s.whole, current: -1}
		if !a.placeDiff(p, t.id) {
			return nil
		}
		s.next = t.id
		s.list = append(s.list, t)
	}
	t.files = files
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
func (t *diffTab) show(change core.GitChange) {
	t.change = change
	t.staged = t.commit == "" && change.Staged && !change.Worktree
	t.file, t.plan, t.items, t.changes = nil, nil, t.items[:0], t.changes[:0]
	t.expanded, t.current, t.revealed = nil, -1, false
	t.err, t.note, t.confirm = "", "", ""
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
// working tree or the index, and the plain diff for an untracked one, for a commit's change and
// for a file the plan has no section for.
func (a *App) loadDiff(p *project, t *diffTab) {
	kernel, ok := a.reviewKernel()
	if !ok {
		return
	}
	t.loading, t.gen = true, t.gen+1
	gen, change, target, commit, untracked := t.gen, t.change, t.target(), t.commit, t.untracked()
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		var (
			file *core.GitDiffFile
			plan *core.DiffBlockPlan
			err  error
		)
		if commit == "" && !untracked {
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
			request := core.GitDiffRequest{Root: target.Root, Path: change.Path, Commit: commit}
			if commit == "" {
				request.Staged, request.Untracked = target.Staged, untracked
			}
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
			t.err, t.file, t.plan = "", file, plan
			t.rebuild()
			if !t.revealed {
				t.revealed = true
				t.step(1)
			}
		}
	})
}

// reloadDiffs reads again every tab that shows a change of the working tree or the index of the
// checkout at root, after something wrote to it.
func (a *App) reloadDiffs(p *project, root string) {
	for _, t := range p.diffs.list {
		if t.root == root && t.commit == "" {
			a.loadDiff(p, t)
		}
	}
}

// units is how many lines the unified view or rows the side-by-side view lays out.
func (t *diffTab) units() int {
	if t.file == nil {
		return 0
	}
	if t.split {
		return len(t.file.Rows)
	}
	return len(t.file.Lines)
}

// changed says unit i of the mode is a changed line: added or removed, or a row that changes,
// adds or removes.
func (t *diffTab) changed(i int) bool {
	if t.split {
		switch t.file.Rows[i].Kind {
		case "addition", "removal", "changed":
			return true
		}
		return false
	}
	switch t.file.Lines[i].LineType {
	case "added", "removed":
		return true
	}
	return false
}

// plain says unit i is an unchanged line, one a fold may hide. A hunk's header is neither
// plain nor changed and always stays in view.
func (t *diffTab) plain(i int) bool {
	if t.split {
		return t.file.Rows[i].Kind == "context"
	}
	return t.file.Lines[i].LineType == "context"
}

// unit is the item of unit i of the mode.
func (t *diffTab) unit(i int) diffItem {
	if t.split {
		return diffItem{line: -1, row: i}
	}
	return diffItem{line: i, row: -1}
}

// rebuild lays out the list rows for the tab's modes: each block's header stands over its first
// line, and while the tab folds, a run of unchanged lines longer than the context on both sides
// of the changes around it gives way to one fold row, unless the user opened it.
func (t *diffTab) rebuild() {
	t.items, t.changes = t.items[:0], t.changes[:0]
	t.builtSplit, t.builtWhole = t.split, t.whole
	if t.file == nil {
		return
	}
	anchors := t.blockAnchors()
	n, number := t.units(), 0
	for i := 0; i < n; {
		if !t.whole && t.plain(i) && anchors[i] == nil {
			j := i + 1
			for j < n && t.plain(j) && anchors[j] == nil {
				j++
			}
			head, tail := diffContext, diffContext
			if i == 0 {
				head = 0
			}
			if j == n {
				tail = 0
			}
			hidden := j - i - head - tail
			if hidden < diffFoldLeast || t.expanded[i] {
				head, hidden = j-i, 0
			}
			for k := i; k < i+head; k++ {
				t.items = append(t.items, t.unit(k))
			}
			if hidden > 0 {
				t.items = append(t.items, diffItem{line: -1, row: -1, fold: hidden, at: i})
				for k := j - tail; k < j; k++ {
					t.items = append(t.items, t.unit(k))
				}
			}
			i = j
			continue
		}
		if t.changed(i) && (i == 0 || !t.changed(i-1)) {
			t.changes = append(t.changes, len(t.items))
		}
		if block := anchors[i]; block != nil {
			number++
			t.items = append(t.items, diffItem{block: block, number: number, line: -1, row: -1})
		}
		t.items = append(t.items, t.unit(i))
		i++
	}
	t.current = min(t.current, len(t.changes)-1)
}

// blockAnchors maps the unit each block's header stands over to the block.
func (t *diffTab) blockAnchors() map[int]*core.DiffBlock {
	anchors := map[int]*core.DiffBlock{}
	if t.plan == nil {
		return anchors
	}
	for i := range t.plan.Blocks {
		n, ok := blockLine(t.plan.Blocks[i].ID)
		if !ok {
			continue
		}
		if t.split {
			if n, ok = t.rowOfLine(n); !ok {
				continue
			}
		}
		anchors[n] = &t.plan.Blocks[i]
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

// rowOfLine finds the aligned row that shows unified line index, by the line numbers they
// share.
func (t *diffTab) rowOfLine(index int) (int, bool) {
	if t.file == nil || index < 0 || index >= len(t.file.Lines) {
		return 0, false
	}
	line := t.file.Lines[index]
	for i, row := range t.file.Rows {
		switch {
		case line.NewLine != nil && row.NewLine != nil && *line.NewLine == *row.NewLine:
			return i, true
		case line.NewLine == nil && line.OldLine != nil && row.OldLine != nil && *line.OldLine == *row.OldLine:
			return i, true
		}
	}
	return 0, false
}

// step moves by differences, forward for a positive by, and scrolls the one it lands on to the
// middle of the list. It stops at the first and the last.
func (t *diffTab) step(by int) {
	if len(t.changes) == 0 {
		return
	}
	t.current = min(max(t.current+by, 0), len(t.changes)-1)
	t.list.ScrollTo(t.changes[t.current], ui.ListCenter)
}

// setMode lays the tab out side by side or unified, folded or whole, and remembers the choice
// for the next tab. The difference the user stood on stays in view.
func (a *App) setDiffMode(p *project, t *diffTab, split, whole bool) {
	if t.whole != whole {
		t.expanded = nil
	}
	t.split, t.whole = split, whole
	p.diffs.split, p.diffs.whole = split, whole
	t.rebuild()
	if t.current >= 0 {
		t.list.ScrollTo(t.changes[t.current], ui.ListCenter)
	}
}

// expand opens the fold whose first hidden line is at.
func (t *diffTab) expand(at int) {
	if t.expanded == nil {
		t.expanded = map[int]bool{}
	}
	t.expanded[at] = true
	t.rebuild()
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
