package workbench

import (
	"context"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the log tab of the Git tool window as a Page, laid out as the macOS log
// is: the action stripe of the reference pane, the reference pane, the commit list with its
// filter bar, and the details pane. What the list rows show is painted by gitgraph.go into
// the rows declared here; the details are in gitlog_details_view.go and the popovers in
// gitlog_popover_view.go.

// logPageView declares the body of the log tab.
func (a *App) logPageView(c ui.C) {
	v := &a.logView
	if v.bodyDraw == nil {
		v.bodyDraw = func(d *ui.DrawContext) { v.bodyRect = d.Rect }
		v.barDraw = func(d *ui.DrawContext) { measureLogBar(&v.barWidth, d) }
		v.filtersDraw = func(d *ui.DrawContext) { measureLogBar(&v.filtersWidth, d) }
		v.refs.Node, v.refLabel = v.refNode, v.refRowLabel
		v.commits.Label = a.logCommitLabel
	}
	// What the splitter was dragged to in the last paint is the details' width now.
	v.capture()
	v.hasBody, v.details = false, false
	p := a.project
	if p == nil {
		return
	}
	l := &p.log
	if !l.started {
		a.loadLog(p)
	}
	a.syncLogFilters(p)
	v.syncLogRefMarks(p)
	ui.Row(c).Fill().Background(a.colors.Editor).Children(func() {
		if l.branchesHidden {
			a.drawLogHiddenStripe(c, p)
		} else {
			a.drawLogStripe(c, p)
			ui.Divider(c)
			a.drawLogReferences(c, p).Width(v.refSplit.Pos).Shrink(0)
			ui.Splitter(c, &v.refSplit).Mins(logRefsMin, logCommitsMin).Label(a.text.Panel.Resize)
		}
		ui.Row(c).Grow(1).Draw(v.bodyDraw).Children(func() {
			v.details = l.showDetails
			if !l.showDetails {
				a.drawLogCommits(c, p).Grow(1)
				return
			}
			if v.bodyWidth > 0 && !v.detailSplit.Dragging() {
				v.derived = max(v.bodyWidth-shellSplitter-v.detailWidth, logCommitsMin)
				v.detailSplit.Pos = v.derived
			}
			a.drawLogCommits(c, p).Grow(1)
			ui.Splitter(c, &v.detailSplit).Mins(logCommitsMin, logDetailsMin).Label(a.text.Panel.Resize)
			a.drawLogDetails(c, p).Width(v.detailWidth).Shrink(0)
		})
		v.hasBody = true
	})
	if !v.focus.IsZero() {
		c.Canvas().RequestFocus(v.focus)
		v.focus = gfx.ID{}
	}
}

// syncLogFilters applies the text typed into the filter field once the typing stops.
func (a *App) syncLogFilters(p *project) {
	l := &p.log
	if text := strings.TrimSpace(a.logView.search.Text()); text != l.text {
		l.text = text
		if !l.loading {
			a.reproject(p, a.delays.filter)
		}
	}
}

// drawLogStripe declares the action stripe of the reference pane.
func (a *App) drawLogStripe(c ui.C, p *project) {
	l := &p.log
	g := a.text.Git
	selected, hasSelected := l.findReference(l.refSelected)
	// With several rows marked the button deletes the branches among them, else the selected one.
	batch, skipped, several := a.logChosenBranches(p)
	deletable := several && len(batch) > 0 || !several && hasSelected && deletableBranch(selected)
	base, compareTarget, comparable := l.primaryComparison()
	compare := g.CompareWorkingTree
	if compareTarget != nil {
		compare = g.CompareWithCurrent
	}
	// The branch selected, or the checked out one without a selection, is what the
	// buttons act on.
	target := selected
	if !hasSelected || selected.Kind != "local" {
		target = l.currentReference()
	}
	updatable := target.Kind == "local" && (target.IsCurrent || target.UpstreamShortName != "")
	ui.Column(c).Width(logStripeWidth).Shrink(0).FillHeight().Items(ui.Center).PadY(6).Gap(4).Background(a.colors.Panel).Children(func() {
		if a.gitIconButton(c, g.HideBranches, icons.ChevronLeft, false, false) {
			c.After(func() { l.branchesHidden = true })
		}
		ui.Divider(c).Width(20)
		if a.gitIconButton(c, g.NewBranch, icons.Plus, false, l.sync.busy) {
			from := l.currentReference()
			if hasSelected {
				from = selected
			}
			c.After(func() {
				a.branch.refs = l.refs
				a.branch.repo = p.logBranchRepo()
				a.beginCreate(p, from)
			})
		}
		if a.gitIconButton(c, g.UpdateBranch, icons.ArrowDownLeft, false, !updatable || l.sync.busy) {
			c.After(func() { a.updateBranch(p, target, surfaceButton) })
		}
		if a.gitIconButton(c, g.DeleteBranch, icons.Trash2, false, !deletable) {
			c.After(func() {
				a.adoptLogBranches(p)
				if several {
					a.beginDeleteBranches(batch, skipped)
				} else {
					a.beginDelete(selected)
				}
			})
		}
		if a.gitIconButton(c, compare, icons.ArrowLeftRight, false, !comparable || l.comparing) {
			c.After(func() { a.compareReferences(p, base, compareTarget) })
		}
		if a.gitIconButton(c, g.FindBranch, icons.Search, false, false) {
			a.logView.focus = logRefSearchID
		}
		if a.gitIconButton(c, g.Fetch, icons.CloudDownload, false, l.sync.busy) {
			c.After(func() { a.fetchAll(p, surfaceButton) })
		}
		if a.gitIconButton(c, g.LocateBranch, icons.Locate, false, !hasSelected && l.current == "") {
			short := l.current
			if hasSelected {
				short = selected.ShortName
			}
			c.After(func() { a.locateReference(p, short) })
		}
		ui.Divider(c).Width(20)
		settings, clicked := a.gitToolButton(c, g.BranchSettings, icons.Settings, l.popover == logPopoverBranchSettings, false)
		if clicked {
			c.After(func() { a.toggleLogPopover(p, logPopoverBranchSettings) })
		}
		a.drawBranchSettingsMenu(c, p, settings)
		a.drawGitReviewMenu(c, p)
		if a.gitIconButton(c, g.ExpandAll, icons.ChevronsUpDown, false, false) {
			c.After(func() { clear(l.collapsed) })
		}
		if a.gitIconButton(c, g.CollapseAll, icons.ChevronsDownUp, false, false) {
			c.After(func() { a.collapseLogRefs(p) })
		}
	})
}

// collapseLogRefs closes every section of the reference pane, and every repository's node in a
// folder with several.
func (a *App) collapseLogRefs(p *project) {
	l := &p.log
	if p.workspaceMode() {
		for _, repo := range p.workspaceRepositories() {
			l.collapsed[logRepoRefKey(repo.id)] = true
		}
		return
	}
	for _, s := range l.sections {
		l.collapsed["s"+s.kind] = true
	}
}

// drawLogHiddenStripe is the stripe that stands for the reference pane while it is hidden.
func (a *App) drawLogHiddenStripe(c ui.C, p *project) {
	ui.Column(c).Width(logStripeWidth).Shrink(0).FillHeight().Items(ui.Center).PadY(6).Gap(4).Background(a.colors.Panel).Children(func() {
		if a.gitIconButton(c, a.text.Git.ShowBranches, icons.GitBranch, false, false) {
			c.After(func() { p.log.branchesHidden = false })
		}
	})
	ui.Divider(c)
}

// drawLogReferences declares the reference pane: its search field over HEAD and the
// sections of local branches, remote branches and tags.
func (a *App) drawLogReferences(c ui.C, p *project) ui.Box {
	l, v, g := &p.log, &a.logView, a.text.Git
	query := strings.ToLower(strings.TrimSpace(v.refSearch.Text()))
	shown := a.buildLogRefRows(p, query)
	v.refSel = l.refSelected
	return ui.Column(c).FillHeight().Background(a.colors.Panel).Clip().Children(func() {
		ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).PadX(6).Children(func() {
			ui.TextFieldID(c, logRefSearchID, &v.refSearch, g.BranchSearch, g.BranchSearch).Grow(1)
		})
		ui.Divider(c)
		// A level starts an icon and a gap right of its parent, so a row's arrow or icon is under
		// its parent's name, as in IDEA's branch tree.
		v.refs.Indent = logRefRowIcon + c.Theme().Metrics.GapItem
		ui.Tree(c, &v.refs, len(v.refItems), v.refLabel, func(i int) {
			a.drawLogRefContent(c, p, v.refs.RowID(i), v.refItems[i])
		}).Scrollbars().Grow(1).PadY(4)
		if i, ok := v.refs.Toggled(); ok {
			c.After(func() { a.toggleLogRef(p, v.refItems[i], query) })
		}
		// A click with Cmd, Ctrl or Shift held marks references instead; Enter is a choice with no
		// click behind it.
		info, clicked := c.Canvas().ClickInfo()
		if i, ok := v.refs.Chosen(); ok {
			r, mods := v.refItems[i], gfx.Modifiers(0)
			if clicked {
				mods = info.Modifiers
			}
			c.After(func() { a.chooseLogRef(p, r, query, clicked, mods) })
		}
		if query != "" && shown == 0 {
			ui.Text(c, g.NoMatchingReferences).Muted().TextCenter().FillWidth().PadY(16)
		}
	})
}

// buildLogRefRows lists the rows the reference pane shows for query: HEAD, then each section
// with the folders and references of its tree, or only the matching references while the
// filter has text. A folder with several repositories lists a node per repository instead, each
// with its own sections (appendRepositoryLogRows). It returns how many references the pane lists.
func (a *App) buildLogRefRows(p *project, query string) (shown int) {
	l, v := &p.log, &a.logView
	rows := v.refItems[:0]
	if query == "" {
		rows = append(rows, logRefRow{kind: logRefHead, label: a.text.Git.HeadRow, key: "HEAD", short: "HEAD"})
	}
	if p.workspaceMode() {
		rows, shown = a.appendRepositoryLogRows(rows, p, query)
	} else {
		rows, shown = a.appendLogSections(rows, p, "", "", &l.sections, 0, query)
	}
	v.refItems = rows
	return shown
}

// appendLogSections appends the sections of one repository's references at depth, keyed under
// prefix. foreign is the Core ID of a repository other than the one whose references the log reads
// with its history, whose references then walk it on a click; empty for that one. It returns how
// many references the sections list.
func (a *App) appendLogSections(rows []logRefRow, p *project, prefix, foreign string, sections *[3]logSection, depth int, query string) ([]logRefRow, int) {
	labels := [3]string{a.text.Git.LocalGroup, a.text.Git.RemoteGroup, a.text.Git.TagGroup}
	kind := logRefReference
	if foreign != "" {
		kind = logRefForeign
	}
	shown := 0
	for i := range sections {
		s := &sections[i]
		if len(s.refs) == 0 {
			continue
		}
		section := logRefRow{kind: logRefSection, depth: depth, label: labels[i], key: prefix + "s" + s.kind, repo: foreign, open: true}
		if query != "" {
			matches := slices.DeleteFunc(slices.Clone(s.refs), func(r core.GitReference) bool {
				return !strings.Contains(strings.ToLower(r.ShortName), query)
			})
			if len(matches) == 0 {
				continue
			}
			shown += len(matches)
			rows = append(rows, section)
			for j := range matches {
				rows = append(rows, logRefRow{kind: kind, depth: depth + 1, label: matches[j].ShortName, key: matches[j].FullName, short: matches[j].ShortName, ref: &matches[j], repo: foreign})
			}
			continue
		}
		shown += len(s.refs)
		section.open = !p.log.collapsed[section.key]
		rows = append(rows, section)
		if section.open {
			rows = a.appendLogNodes(rows, p, prefix, foreign, s, s.nodes, depth+1)
		}
	}
	return rows, shown
}

// appendLogNodes appends the folders and references of a section's tree, the folders that are
// open with what is in them.
func (a *App) appendLogNodes(rows []logRefRow, p *project, prefix, foreign string, s *logSection, nodes []core.ReferenceTreeNode, depth int) []logRefRow {
	kind := logRefReference
	if foreign != "" {
		kind = logRefForeign
	}
	for i := range nodes {
		node := &nodes[i]
		if node.Reference != nil {
			if r := *node.Reference; r >= 0 && r < len(s.refs) {
				ref := &s.refs[r]
				rows = append(rows, logRefRow{kind: kind, depth: depth, label: node.Name, key: ref.FullName, short: ref.ShortName, ref: ref, repo: foreign})
			}
			continue
		}
		key := prefix + "f" + s.kind + "/" + node.Path
		open := !p.log.collapsed[key]
		rows = append(rows, logRefRow{kind: logRefFolder, depth: depth, label: node.Name, key: key, open: open})
		if open {
			rows = a.appendLogNodes(rows, p, prefix, foreign, s, node.Children, depth+1)
		}
	}
	return rows
}

// refNode describes row i of the reference pane to its tree. HEAD and the references of the
// walked repository show as selected when the log walks them or they are marked; the other rows
// only fold or switch repository.
func (v *logView) refNode(i int) ui.TreeNode {
	r := v.refItems[i]
	selected := (r.kind == logRefHead || r.kind == logRefReference) && (v.refSel == r.key || v.refMarks[r.key])
	return ui.TreeNode{Depth: r.depth, Branch: r.kind == logRefSection || r.kind == logRefFolder || r.kind == logRefRepository, Expanded: r.open, Selected: selected}
}

// logRefScope is what the marks of the reference pane belong to: the project, the repository the
// log walks and the reference it selects.
type logRefScope struct {
	p              *project
	repo, selected string
}

// syncLogRefMarks drops the marks of the reference pane when they no longer belong to what the
// log walks: when it walks another repository, or selects another reference than a click in the
// pane left selected (a menu, the popover, a deletion). It also drops the marks of references
// the log no longer lists, so that a branch created again under a deleted name is not marked.
// Marks of rows the pane does not show, folded or filtered out, stay, as Core keeps them.
func (v *logView) syncLogRefMarks(p *project) {
	scope := logRefScope{p: p, repo: p.logRepoID(), selected: p.log.refSelected}
	if scope != v.refScope {
		v.refScope = scope
		v.forgetLogRefMarks()
		return
	}
	for key := range v.refMarks {
		if _, ok := p.log.findReference(key); !ok && key != "HEAD" {
			delete(v.refMarks, key)
		}
	}
}

// forgetLogRefMarks drops the marks of the reference pane and its anchor.
func (v *logView) forgetLogRefMarks() { v.refMarks, v.refAnchor = nil, "" }

// markedLogRefs are the references of the walked repository marked in the reference pane, in the
// order the log lists them, and whether HEAD is marked. Marks the pane has not synced to p yet
// count for nothing.
func (v *logView) markedLogRefs(p *project) (refs []core.GitReference, head bool) {
	l := &p.log
	if len(v.refMarks) == 0 || v.refScope != (logRefScope{p: p, repo: p.logRepoID(), selected: l.refSelected}) {
		return nil, false
	}
	for _, s := range l.sections {
		for _, r := range s.refs {
			if v.refMarks[r.FullName] {
				refs = append(refs, r)
			}
		}
	}
	return refs, v.refMarks["HEAD"]
}

// reduceLogRefMarks applies a click on HEAD or a reference of the pane to its marks, with Core's
// workspace.rowSelection over HEAD and the references the pane shows, top to bottom. It reports
// whether the click applied; Core rejects a row that went away since the paint that showed it.
func (a *App) reduceLogRefMarks(p *project, action core.RowAction) bool {
	v, l := &a.logView, &p.log
	rows := make([]string, 0, len(v.refItems))
	for i := range v.refItems {
		if r := &v.refItems[i]; r.kind == logRefHead || r.kind == logRefReference {
			rows = append(rows, r.key)
		}
	}
	selection := core.RowSelection{Anchor: v.refAnchor}
	if l.refSelected != "" {
		selection.Selected = new(l.refSelected)
	}
	for key := range v.refMarks {
		selection.Marked = append(selection.Marked, key)
	}
	ctx, cancel := context.WithTimeout(a.operationContext(context.Background()), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.ReduceRowSelection(ctx, rows, selection, action)
	if err != nil {
		a.operationFailed("git_log_ref_selection", err)
		a.notifyError(a.text.Errors.Core(err.Error()))
		return false
	}
	if result.Rejection != "" {
		return false
	}
	v.refMarks = nil
	if len(result.Selection.Marked) > 0 {
		v.refMarks = make(map[string]bool, len(result.Selection.Marked))
		for _, key := range result.Selection.Marked {
			v.refMarks[key] = true
		}
	}
	v.refAnchor = result.Selection.Anchor
	return true
}

// refRowLabel is the accessible name of row i of the reference pane.
func (v *logView) refRowLabel(i int) string { return v.refItems[i].label }

// logRefRowIcon is the size of the icon of a row of the reference pane.
const logRefRowIcon = 14

// drawLogRefContent declares what row of the reference pane shows after its arrow. Viva's Tree
// starts a row without an arrow (HEAD, a reference) where the arrow of a row with one is, so such
// a row keeps the arrow's room empty, and its icon lines up with the name of a section or the
// icon of a folder beside it.
func (a *App) drawLogRefContent(c ui.C, p *project, row gfx.ID, r logRefRow) {
	switch r.kind {
	case logRefHead, logRefReference, logRefForeign:
		ui.Row(c).Grow(1).Shrink(1).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(treeChevron).Children(func() {
			a.drawLogRefLeaf(c, p, row, r)
		})
		return
	}
	switch r.kind {
	case logRefSection:
		ui.Text(c, r.label).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
	case logRefRepository:
		ui.Icon(c, icons.Folder).Size(logRefRowIcon, logRefRowIcon).Color(r.tint)
		ui.Text(c, r.label).Weight(gfx.WeightMedium).Color(r.tint).Ellipsis().Grow(1)
		if p.logChosen(r.repo) {
			// The repositories the log walks are checked, as the roots list checks them.
			ui.Icon(c, icons.Check).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
		}
	case logRefFolder:
		ui.Icon(c, icons.Folder).Size(logRefRowIcon, logRefRowIcon).Color(a.colors.Subtle)
		ui.Text(c, r.label).Ellipsis().Grow(1)
	}
}

// drawLogRefLeaf declares the icon, name and distance from its upstream of HEAD or a reference
// in the reference pane. The name of a reference of the repository the log walks labels the row
// and carries the reference's menu.
func (a *App) drawLogRefLeaf(c ui.C, p *project, row gfx.ID, r logRefRow) {
	switch r.kind {
	case logRefHead:
		ui.Icon(c, icons.Tag).Size(logRefRowIcon, logRefRowIcon).Color(referenceColor("head", a.colors.Dark))
		ui.Text(c, r.label).Ellipsis().Grow(1)
	case logRefReference, logRefForeign:
		ref := r.ref
		kind := map[string]string{"local": "branch", "remote": "remote", "tag": "tag"}[ref.Kind]
		icon := icons.GitBranch
		switch {
		case ref.Kind == "tag":
			icon = icons.Tag
		case ref.IsCurrent:
			kind, icon = "head", icons.Tag
		}
		trailing := ""
		if ref.Ahead > 0 {
			trailing = "↑" + strconv.Itoa(ref.Ahead)
		}
		if ref.Behind > 0 {
			trailing = strings.TrimSpace(trailing + " ↓" + strconv.Itoa(ref.Behind))
		}
		ui.Icon(c, icon).Size(logRefRowIcon, logRefRowIcon).Color(referenceColor(kind, a.colors.Dark))
		name := ui.Text(c, r.label).Ellipsis().Grow(1)
		if r.kind == logRefReference {
			a.drawLogRefMenu(c, name.LabelFor(row), p, *ref)
		}
		if trailing != "" {
			ui.Text(c, trailing).Muted().FontSize(a.theme.Metrics.FontSizeS).Shrink(0)
		}
	}
}

// toggleLogRef opens or closes the section or folder of a row; while the filter has text the
// sections show every match and do not fold.
func (a *App) toggleLogRef(p *project, r logRefRow, query string) {
	if (r.kind == logRefSection || r.kind == logRefFolder || r.kind == logRefRepository) && query == "" {
		p.log.collapsed[r.key] = r.open
	}
}

// chooseLogRef acts on a choice of row r of the reference pane: a repository's node, a section or
// a folder folds, a reference of another repository walks that reference in its repository, and
// HEAD or a reference of the walked repository becomes the one the log walks. A click on HEAD or
// a reference also goes to the pane's marks, as reduceLogRefMarks says: a plain click drops them,
// a Cmd or Ctrl click marks or unmarks the row and a Shift click marks the rows from the anchor.
// Enter, a choice with no click behind it, leaves the marks.
func (a *App) chooseLogRef(p *project, r logRefRow, query string, clicked bool, mods gfx.Modifiers) {
	l, v := &p.log, &a.logView
	switch r.kind {
	case logRefSection, logRefFolder, logRefRepository:
		a.toggleLogRef(p, r, query)
	case logRefForeign:
		a.setLogRepo(p, r.repo, r.ref.FullName, r.ref.ShortName)
	default:
		if clicked {
			action := core.ChooseRow(r.key)
			switch {
			case mods&ui.Primary != 0:
				action = core.ToggleRow(r.key)
			case mods&gfx.ModifierShift != 0:
				action = core.ExtendRow(r.key)
			}
			if !a.reduceLogRefMarks(p, action) {
				return
			}
		}
		l.refSelected = r.key
		a.setLogReference(p, r.key, r.short)
		// The marks belong to what the click left the log walking.
		v.refScope = logRefScope{p: p, repo: p.logRepoID(), selected: l.refSelected}
	}
}

// drawLogCommits declares the commit pane: the filter bar over the list.
func (a *App) drawLogCommits(c ui.C, p *project) ui.Box {
	return ui.Column(c).FillHeight().MinWidth(logCommitsMin).Clip().Children(func() {
		a.drawLogToolbar(c, p)
		ui.Divider(c)
		a.drawSyncStatus(c, p)
		a.drawLogList(c, p)
	})
}

// drawGitActions declares the button of the Git actions menu in the Git tool window's header,
// beside the hide button, with the menu under it. It shows on every tab: fetching, updating
// the branch and refreshing the log act on the repository, not on the tab. The button keeps
// its width while the tabs give theirs up, so a narrow pane cuts the tab labels, not it.
func (a *App) drawGitActions(c ui.C, p *project) {
	l := &p.log
	menu, clicked := a.gitToolButton(c, a.text.Git.Actions, icons.EllipsisVertical, l.popover == logPopoverMenu, false)
	menu.Shrink(0)
	if clicked {
		c.After(func() { a.toggleLogPopover(p, logPopoverMenu) })
	}
	a.drawLogMenu(c, p, menu)
}

// drawLogToolbar declares the filter bar: the text filter, the filters (the filter chips, the
// repository the log walks and the button that shows every reference again), and the view
// buttons, as IDEA's log toolbar lays them out. The filters keep their width; a bar short of room
// moves the view buttons, the last first, into its overflow menu, then narrows the text filter to
// logSearchFloor, and only a bar too narrow for that cuts the filters' end. The menu of the Git
// actions is in the tool window's header (drawGitActions).
func (a *App) drawLogToolbar(c ui.C, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	shown := logViewFit(v.barWidth, v.filtersWidth, logViewCount)
	if shown == logViewCount && l.popover == logPopoverViewMore {
		l.popover = logPopoverNone // the bar has room for every button again
	}
	searchMin := float32(logSearchMin)
	if shown == 0 {
		searchMin = logSearchWidth(v.barWidth, v.filtersWidth)
	}
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(logBarGap).PadX(logBarPad).Draw(v.barDraw).Children(func() {
		ui.TextFieldID(c, logSearchID, &v.search, g.TextOrHash, g.TextOrHash).MinWidth(searchMin).Grow(1).MaxWidth(320)
		ui.Row(c).Shrink(1).MinWidth(0).Clip().Items(ui.Center).Children(func() {
			ui.Row(c).Shrink(0).Items(ui.Center).Gap(logBarGap).Draw(v.filtersDraw).Children(func() {
				a.drawLogFilters(c, p)
			})
		})
		ui.Spacer(c)
		ui.Row(c).Shrink(0).Items(ui.Center).Gap(logBarGap).Children(func() {
			for i := range shown {
				b := a.logViewButton(p, i)
				if a.gitIconButton(c, b.label, b.icon, b.lit, b.disabled) {
					c.After(func() { a.runLogView(p, i) })
				}
			}
			if shown < logViewCount {
				a.drawLogViewMore(c, p, shown)
			}
		})
	})
}

// drawLogFilters declares the filters of the filter bar: the filter chips with their popovers, the
// repository the log walks, and, while the log walks one reference, the button that shows every
// reference again.
func (a *App) drawLogFilters(c ui.C, p *project) {
	l, g := &p.log, a.text.Git
	dates := [logDateCount]string{g.AnyTime, g.Today, g.Yesterday, g.Last7Days, g.Last30Days}
	chips := [logChipCount]struct {
		label, value string
		popover      logPopover
	}{
		{g.FilterBranch, l.referenceLabel, logPopoverBranch},
		{g.FilterUser, l.user, logPopoverUser},
		{g.FilterDate, "", logPopoverDate},
		{g.FilterPaths, l.path, logPopoverPath},
	}
	if l.date != logAnyTime {
		chips[logChipDate].value = dates[l.date]
	}
	for i, chip := range chips {
		box := a.drawLogChip(c, i, chip.label, chip.value, l.popover == chip.popover)
		if box.Clicked() {
			c.After(func() { a.toggleLogPopover(p, chip.popover) })
		}
		a.drawLogPopover(c, p, chip.popover, box)
	}
	a.drawLogRepoLabel(c, p)
	if l.reference != "" {
		if a.gitIconButton(c, g.ShowAll, icons.Plus, false, false) {
			c.After(func() {
				l.refSelected = ""
				a.setLogReference(p, "", "")
			})
		}
	}
}

// The view buttons at the end of the filter bar, in the order the bar shows them. A bar short of
// room moves the last ones into its overflow menu first.
const (
	logViewCompare = iota
	logViewDetails
	logViewRefresh
	logViewDecorations
	logViewFind
	logViewEdges
	logViewCount
)

// logViewButtonSpec is what a view button of the filter bar shows: its label and icon, whether it
// is drawn pressed (lit) and whether it is disabled. toggle says it switches a setting, on or off
// as state says, which the overflow menu shows as a check mark.
type logViewButtonSpec struct {
	label         string
	icon          gfx.Icon
	lit, disabled bool
	toggle, state bool
}

// logViewButton is what view button i of the filter bar shows.
func (a *App) logViewButton(p *project, i int) logViewButtonSpec {
	l, g := &p.log, a.text.Git
	switch i {
	case logViewCompare:
		return logViewButtonSpec{label: g.CompareBranch, icon: icons.ArrowLeftRight, disabled: l.comparing}
	case logViewDetails:
		return logViewButtonSpec{label: g.ShowDetails, icon: icons.PanelRight, lit: l.showDetails, toggle: true, state: l.showDetails}
	case logViewRefresh:
		return logViewButtonSpec{label: g.RefreshLog, icon: icons.RefreshCw}
	case logViewDecorations:
		icon := icons.EyeOff
		if l.decorations {
			icon = icons.Eye
		}
		return logViewButtonSpec{label: g.Decorations, icon: icon, toggle: true, state: l.decorations}
	case logViewFind:
		return logViewButtonSpec{label: g.FindInLog, icon: icons.Search}
	default:
		icon := icons.ArrowDownToLine
		if l.expanded {
			icon = icons.ArrowUpDown
		}
		return logViewButtonSpec{label: g.LongEdges, icon: icon, lit: l.expanded, toggle: true, state: l.expanded}
	}
}

// runLogView does what view button i of the filter bar does, pressed in the bar or chosen in its
// overflow menu.
func (a *App) runLogView(p *project, i int) {
	l := &p.log
	switch i {
	case logViewCompare:
		a.compareReferences(p, l.currentReference(), nil)
	case logViewDetails:
		l.showDetails = !l.showDetails
	case logViewRefresh:
		a.loadLog(p)
	case logViewDecorations:
		l.decorations = !l.decorations
	case logViewFind:
		a.logView.focus = logSearchID
	case logViewEdges:
		l.expanded = !l.expanded
		if !l.loading {
			a.reproject(p, 0)
		}
	}
}

// logViewFit is how many of count view buttons the filter bar shows: all of them when they fit in
// a bar barWidth wide beside the text filter at its least width and filters filtersWidth wide,
// otherwise as many as fit with the button of the overflow menu after them. A bar not laid out
// yet shows them all.
func logViewFit(barWidth, filtersWidth float32, count int) int {
	if barWidth <= 0 {
		return count
	}
	// The text filter, the filters, the spacer and the buttons stand logBarGap apart.
	room := barWidth - 2*logBarPad - logSearchMin - filtersWidth - 3*logBarGap
	fits := int((room + logBarGap) / (shellHideSize + logBarGap))
	if fits >= count {
		return count
	}
	return max(fits-1, 0)
}

// logSearchWidth is the least width of the text filter of a bar barWidth wide that has moved every
// view button into its overflow menu: the room the filters filtersWidth wide and the menu's button
// leave it, no more than logSearchMin and no less than logSearchFloor.
func logSearchWidth(barWidth, filtersWidth float32) float32 {
	room := barWidth - 2*logBarPad - filtersWidth - shellHideSize - 3*logBarGap
	return min(max(room, logSearchFloor), logSearchMin)
}

// measureLogBar records in width the width d laid its box out at and, when it changed, asks for
// one more paint: which view buttons the filter bar shows is worked out from it.
func measureLogBar(width *float32, d *ui.DrawContext) {
	if d.Rect.Width != *width {
		*width = d.Rect.Width
		d.Canvas.RequestFrame()
	}
}

// drawLogViewMore declares the button of the filter bar's overflow menu and, while it is open, the
// menu: the view buttons from first on, which the bar has no room for, each with its icon, and a
// setting one switches checked when it is on.
func (a *App) drawLogViewMore(c ui.C, p *project, first int) {
	l := &p.log
	label := i18n.Shared(a.language(), "git.log.toolbar.moreActions")
	button, clicked := a.gitToolButton(c, label, icons.Ellipsis, l.popover == logPopoverViewMore, false)
	if clicked {
		c.After(func() { a.toggleLogPopover(p, logPopoverViewMore) })
	}
	if l.popover != logPopoverViewMore {
		return
	}
	open := true
	ui.Menu(c, button, &open, func(menu *ui.MenuItems) {
		for i := first; i < logViewCount; i++ {
			b := a.logViewButton(p, i)
			item := menu.Item(b.label).Icon(b.icon).Disabled(b.disabled)
			if b.toggle {
				item = item.Checked(b.state)
			}
			if item.Clicked() {
				c.After(func() { a.runLogView(p, i) })
			}
		}
	})
	if !open {
		l.popover = logPopoverNone
	}
}

// drawLogRepoLabel declares, after the filter chips, the name of the repository the log walks in
// its color, or the colors and the count of the repositories it walks together. A click lists the
// repositories of the folder to walk (drawLogRoots). While the log walks a nested repository alone
// a button leads back to the project's own.
func (a *App) drawLogRepoLabel(c ui.C, p *project) {
	l := &p.log
	if !p.workspaceMode() && p.nested.logRepo == "" {
		return
	}
	g := a.text.Git.Repositories
	id := p.logRepoID()
	name, tint := p.repositoryName(id), a.repositoryTint(p, id)
	several := p.walksSeveral()
	if several {
		name, tint = g.Several(len(p.nested.chosen)), a.colors.Text
	}
	tip := g.Current(name)
	if p.workspaceMode() {
		tip = g.Choose
	}
	rc := c.Part("repo")
	open := l.popover == logPopoverRoots
	label := ui.Row(rc).Height(logButtonSize).Shrink(0).Items(ui.Center).Gap(4).PadX(6).
		Radius(a.theme.Metrics.RadiusItem())
	if p.workspaceMode() {
		label = label.HitWith(ui.ID(rc), tip, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
		if open {
			label = label.Background(a.colors.Active)
		} else {
			label = label.Hover(ui.Look{}.Background(a.colors.Hover))
		}
	} else {
		label = label.HitWith(ui.ID(rc), tip, gfx.HitOptions{Role: gfx.RoleStatus})
	}
	label = label.Tooltip(tip)
	label.Children(func() {
		if several {
			for _, chosen := range p.nested.chosen {
				a.drawRepositorySwatch(rc, p, chosen)
			}
		} else {
			ui.Icon(rc, icons.Folder).Size(14, 14).Shrink(0).Color(tint)
		}
		ui.Text(rc, name).Weight(gfx.WeightMedium).Color(tint).Ellipsis().MaxWidth(160)
		if p.workspaceMode() {
			ui.Icon(rc, icons.ChevronDown).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
		}
	})
	if p.workspaceMode() {
		if label.Clicked() {
			c.After(func() { a.toggleLogPopover(p, logPopoverRoots) })
		}
		a.drawLogPopover(c, p, logPopoverRoots, label)
	}
	if !several && p.nested.logRepo != "" && p.git.isRepository() {
		own := p.ownID()
		if ui.Button(c.Part("repo-back"), g.Back(p.repositoryName(own))).Ghost().Shrink(0).Clicked() {
			c.After(func() { a.setLogRepo(p, own, "", "") })
		}
	}
}

// drawLogChip declares a filter chip: its name, or the filter it applies, and a chevron.
func (a *App) drawLogChip(c ui.C, i int, label, value string, open bool) ui.Box {
	text := label
	if value != "" {
		text = a.text.Git.FilterValue(label, value)
	}
	chip := ui.Row(c.KeyInt(i)).Height(logButtonSize).Shrink(0).Items(ui.Center).Gap(4).PadX(8).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), text, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
	switch {
	case open:
		chip = chip.Background(a.colors.Active)
	case value != "":
		chip = chip.Background(a.colors.Hover)
	default:
		chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	chip.Children(func() {
		color := a.colors.Subtle
		if value != "" {
			color = a.colors.Text
		}
		ui.Text(c, text).Color(color).MaxWidth(180).Ellipsis()
		ui.Icon(c, icons.ChevronDown).Size(12, 12).Color(a.colors.Subtle)
	})
	return chip
}

// drawLogList declares the commit list, or what stands in for it. Only the rows in view are
// declared, so a long history costs what fits; the row after the last stands for the next
// page while there is one.
func (a *App) drawLogList(c ui.C, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	switch {
	case !p.git.loaded || l.loading && len(l.commits) == 0:
		a.gitEmpty(c, g.Loading)
		return
	case !p.hasRepository():
		a.gitEmpty(c, g.NotRepository)
		return
	case !p.git.isRepository() && p.logRepo() == nil:
		// The folder is no repository; the log walks a nested one once Core picked it.
		a.gitEmpty(c, g.Loading)
		return
	case l.err != nil:
		a.gitEmpty(c, g.Failed(l.err.Error()))
		return
	case len(l.commits) == 0:
		a.gitEmpty(c, g.NoCommits)
		return
	case len(l.graph.Rows) == 0 && l.filtered():
		a.gitEmpty(c, g.NoMatches)
		return
	}
	rows := l.graph.Rows
	n := len(rows)
	v.keyRows = rows
	if v.commits.Selection == nil {
		v.commits.Selection, v.commits.Key = &v.chosen, v.logCommitKey
	}
	if l.reveal {
		l.reveal = false
		if at := slices.IndexFunc(rows, func(r core.GraphRow) bool { return r.CommitHash == l.selected }); at >= 0 {
			v.commits.ScrollIntoView(at)
		}
	}
	// The list's choice follows the commit selected anywhere else: a reference located in
	// the graph, a selection that a filter dropped. With no row selected before or after, the
	// commits chosen are left as they are.
	if cur := v.commits.Selected(); !v.commits.Changed() && (cur < 0 || cur >= n || rows[cur].CommitHash != l.selected) {
		if at := slices.IndexFunc(rows, func(r core.GraphRow) bool { return r.CommitHash == l.selected }); at >= 0 || cur >= 0 {
			v.commits.Select(at)
			v.chosen.Clear()
			if at >= 0 {
				v.chosen.Add(v.hashKey(l.selected))
			}
		}
	}
	total := n
	if l.hasMore || l.loadingMore || l.limitReached {
		total++
	}
	area := ui.List(c, &v.commits, total, func(row ui.ListRow) { a.drawLogRow(c, p, rows, row) }).Scrollbars().Grow(1).FillWidth()
	if v.commits.Changed() {
		if i := v.commits.Selected(); i >= 0 && i < n {
			a.selectCommit(p, rows[i].CommitHash)
		}
	}
	if s := area.ScrollState(); l.hasMore && s.Content > 0 && s.Offset+s.Viewport >= s.Content-logLoadMoreMargin {
		a.loadMoreLog(p)
	}
}

// drawLogRow declares one row of the commit list: a commit, whose graph and texts the draw
// callback paints, or the row under the commits that loads the next page.
func (a *App) drawLogRow(c ui.C, p *project, rows []core.GraphRow, row ui.ListRow) {
	l, v := &p.log, &a.logView
	i := row.Index
	if i >= len(rows) {
		a.drawLogFooter(c, p, row)
		return
	}
	box := row.Element.Height(logRowHeight).FillWidth()
	switch {
	case rows[i].CommitHash == l.selected || v.chosen.Len() > 1 && v.commits.Chosen(i):
		box = box.Background(a.colors.Selection)
	case l.currentRows[rows[i].CommitHash]:
		box = box.Background(currentBranchBackground(a.colors.Dark)).Hover(ui.Look{}.Background(a.colors.Hover))
	default:
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	// The menu hangs on the row the list already identifies: an identity of its own would
	// take the row's presses from the list, which then never chooses the commit.
	ui.ContextMenu(row.C, box, a.logCommitMenu(p, i))
	box.Draw(v.rowPainter(a, i))
}

// drawLogFooter declares the row under the list that loads the next page, or that says the log
// read as many commits as its settings let it and offers them.
func (a *App) drawLogFooter(c ui.C, p *project, row ui.ListRow) {
	l, g := &p.log, a.text.Git
	row.Element.Height(logRowHeight * 1.5).FillWidth().Items(ui.Center).Gap(8).PadX(12).Children(func() {
		ui.Spacer(c)
		switch {
		case l.loadingMore:
			ui.Text(c, g.LoadingCommits).Muted()
		case l.moreFailed:
			ui.Text(c, g.LoadMoreFailed).Color(a.colors.Warning)
			if ui.Button(c.Part("retry-more"), g.Retry).Ghost().Clicked() {
				c.After(func() {
					l.moreFailed = false
					a.loadMoreLog(p)
				})
			}
		case l.limitReached && !l.hasMore:
			ui.Text(c, g.LimitReached(len(l.commits))).Muted()
			if ui.Button(c.Part("adjust-limit"), g.AdjustLimit).Ghost().Clicked() {
				c.After(a.openGitLogLimitSettings)
			}
		default:
			if ui.Button(c.Part("load-more"), g.LoadMore).Ghost().Clicked() {
				c.After(func() { a.loadMoreLog(p) })
			}
		}
		ui.Spacer(c)
	})
}

// logCommitKey is the key of row i of the commit list in its selection: the key of the commit's
// hash, so a choice survives a reload that moves the rows. Zero identifies the
// loading footer, which still needs a valid identity even though it is not selectable.
func (v *logView) logCommitKey(i int) int {
	if i < 0 || i >= len(v.keyRows) {
		return 0
	}
	return v.hashKey(v.keyRows[i].CommitHash)
}

// hashKey is the selection key of the commit hash: the order the list first showed it in. A
// row's key is its identity too, which has to be unique and below 2^31, as no digest of the
// hash is.
func (v *logView) hashKey(hash string) int {
	if k, ok := v.keys[hash]; ok {
		return k
	}
	if v.keys == nil {
		v.keys = map[string]int{}
	}
	k := len(v.keys) + 1 // Zero belongs to the loading footer.
	v.keys[hash] = k
	return k
}
