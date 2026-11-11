package workbench

import (
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
	deletable := hasSelected && selected.Kind == "local" && !selected.IsCurrent
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
			c.After(func() { a.updateBranch(p, target) })
		}
		if a.gitIconButton(c, g.DeleteBranch, icons.Trash2, false, !deletable) {
			c.After(func() {
				a.branch.repo = p.logBranchRepo()
				a.beginDelete(selected)
			})
		}
		if a.gitIconButton(c, compare, icons.ArrowLeftRight, false, !comparable || l.comparing) {
			c.After(func() { a.compareReferences(p, base, compareTarget) })
		}
		if a.gitIconButton(c, g.FindBranch, icons.Search, false, false) {
			a.logView.focus = logRefSearchID
		}
		if a.gitIconButton(c, g.Fetch, icons.CloudDownload, false, l.sync.busy) {
			c.After(func() { a.fetchAll(p) })
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
			c.After(func() {
				for _, s := range l.sections {
					l.collapsed["s"+s.kind] = true
				}
			})
		}
	})
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
		ui.Tree(c, &v.refs, len(v.refItems), v.refLabel, func(i int) {
			a.logRefPointer(c, p, i)
			a.drawLogRefContent(c, v.refItems[i])
		}).Grow(1).PadY(4)
		a.drawLogRefMenu(c, p)
		if i, ok := v.refs.Toggled(); ok {
			c.After(func() { a.toggleLogRef(p, v.refItems[i], query) })
		}
		if i, ok := v.refs.Chosen(); ok {
			c.After(func() { a.chooseLogRef(p, v.refItems[i], query) })
		}
		if query != "" && shown == 0 {
			ui.Text(c, g.NoMatchingReferences).Muted().TextCenter().FillWidth().PadY(16)
		}
	})
}

// buildLogRefRows lists the rows the reference pane shows for query: HEAD, then each section
// with the folders and references of its tree, or only the matching references while the
// filter has text. It returns how many references the sections list.
func (a *App) buildLogRefRows(p *project, query string) (shown int) {
	l, v := &p.log, &a.logView
	rows := v.refItems[:0]
	labels := [3]string{a.text.Git.LocalGroup, a.text.Git.RemoteGroup, a.text.Git.TagGroup}
	if query == "" {
		rows = append(rows, logRefRow{kind: logRefHead, label: a.text.Git.HeadRow, key: "HEAD", short: "HEAD"})
	}
	for i := range l.sections {
		s := &l.sections[i]
		if len(s.refs) == 0 {
			continue
		}
		section := logRefRow{kind: logRefSection, label: labels[i], key: "s" + s.kind, open: true}
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
				rows = append(rows, logRefRow{kind: logRefReference, depth: 1, label: matches[j].ShortName, key: matches[j].FullName, short: matches[j].ShortName, ref: &matches[j]})
			}
			continue
		}
		shown += len(s.refs)
		section.open = !l.collapsed[section.key]
		rows = append(rows, section)
		if section.open {
			rows = a.appendLogNodes(rows, p, s, s.nodes, 1)
		}
	}
	var nested int
	rows, nested = a.appendNestedLogRows(rows, p, query)
	shown += nested
	v.refItems = rows
	return shown
}

// appendLogNodes appends the folders and references of a section's tree, the folders that are
// open with what is in them.
func (a *App) appendLogNodes(rows []logRefRow, p *project, s *logSection, nodes []core.ReferenceTreeNode, depth int) []logRefRow {
	for i := range nodes {
		node := &nodes[i]
		if node.Reference != nil {
			if r := *node.Reference; r >= 0 && r < len(s.refs) {
				ref := &s.refs[r]
				rows = append(rows, logRefRow{kind: logRefReference, depth: depth, label: node.Name, key: ref.FullName, short: ref.ShortName, ref: ref})
			}
			continue
		}
		key := "f" + s.kind + "/" + node.Path
		open := !p.log.collapsed[key]
		rows = append(rows, logRefRow{kind: logRefFolder, depth: depth, label: node.Name, key: key, open: open})
		if open {
			rows = a.appendLogNodes(rows, p, s, node.Children, depth+1)
		}
	}
	return rows
}

// refNode describes row i of the reference pane to its tree.
func (v *logView) refNode(i int) ui.TreeNode {
	r := v.refItems[i]
	selected := false
	switch r.kind {
	case logRefHead:
		selected = v.refSel == "HEAD"
	case logRefReference:
		selected = v.refSel == r.key
	}
	return ui.TreeNode{Depth: r.depth, Branch: r.kind == logRefSection || r.kind == logRefFolder || r.kind == logRefRepository, Expanded: r.open, Selected: selected}
}

// refRowLabel is the accessible name of row i of the reference pane.
func (v *logView) refRowLabel(i int) string { return v.refItems[i].label }

// drawLogRefContent declares what a row of the reference pane shows after its arrow.
func (a *App) drawLogRefContent(c ui.C, r logRefRow) {
	switch r.kind {
	case logRefSection:
		ui.Text(c, r.label).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
	case logRefRepository:
		ui.Icon(c, icons.Folder).Size(14, 14).Color(r.tint)
		ui.Text(c, r.label).Weight(gfx.WeightMedium).Color(r.tint).Ellipsis().Grow(1)
	case logRefFolder:
		ui.Icon(c, icons.Folder).Size(14, 14).Color(a.colors.Subtle)
		ui.Text(c, r.label).Ellipsis().Grow(1)
	case logRefHead:
		ui.Icon(c, icons.Tag).Size(14, 14).Color(referenceColor("head", a.colors.Dark))
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
		ui.Icon(c, icon).Size(14, 14).Color(referenceColor(kind, a.colors.Dark))
		ui.Text(c, r.label).Ellipsis().Grow(1)
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

// chooseLogRef acts on a click on a row of the reference pane: a section or folder folds, a
// repository's group or one of its references makes that repository the one the log walks, and a
// reference of the walked repository becomes the one the log walks.
func (a *App) chooseLogRef(p *project, r logRefRow, query string) {
	l := &p.log
	switch r.kind {
	case logRefSection, logRefFolder:
		a.toggleLogRef(p, r, query)
	case logRefRepository:
		a.setLogRepo(p, r.repo, "", "")
	case logRefForeign:
		a.setLogRepo(p, r.repo, r.ref.FullName, r.ref.ShortName)
	default:
		l.refSelected = r.key
		a.setLogReference(p, r.key, r.short)
	}
}

// drawLogCommits declares the commit pane: the filter bar over the list.
func (a *App) drawLogCommits(c ui.C, p *project) ui.Box {
	return ui.Column(c).FillHeight().MinWidth(logCommitsMin).Clip().Children(func() {
		a.drawLogRepoBar(c, p)
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

// drawLogToolbar declares the filter bar: the text filter, the filter chips and the
// view buttons. The menu of the Git actions is in the tool window's header (drawGitActions).
func (a *App) drawLogToolbar(c ui.C, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		ui.TextFieldID(c, logSearchID, &v.search, g.TextOrHash, g.TextOrHash).MinWidth(150).Grow(1).MaxWidth(320)
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
		if l.reference != "" {
			// The log walks one reference: this shows every reference again.
			if a.gitIconButton(c, g.ShowAll, icons.Plus, false, false) {
				c.After(func() {
					l.refSelected = ""
					a.setLogReference(p, "", "")
				})
			}
		}
		ui.Spacer(c)
		if a.gitIconButton(c, g.CompareBranch, icons.ArrowLeftRight, false, l.comparing) {
			c.After(func() { a.compareReferences(p, l.currentReference(), nil) })
		}
		if a.gitIconButton(c, g.ShowDetails, icons.PanelRight, l.showDetails, false) {
			c.After(func() { l.showDetails = !l.showDetails })
		}
		if a.gitIconButton(c, g.RefreshLog, icons.RefreshCw, false, false) {
			c.After(func() { a.loadLog(p) })
		}
		decorations := icons.EyeOff
		if l.decorations {
			decorations = icons.Eye
		}
		if a.gitIconButton(c, g.Decorations, decorations, false, false) {
			c.After(func() { l.decorations = !l.decorations })
		}
		if a.gitIconButton(c, g.FindInLog, icons.Search, false, false) {
			v.focus = logSearchID
		}
		edges := icons.ArrowDownToLine
		if l.expanded {
			edges = icons.ArrowUpDown
		}
		if a.gitIconButton(c, g.LongEdges, edges, l.expanded, false) {
			c.After(func() {
				l.expanded = !l.expanded
				if !l.loading {
					a.reproject(p, 0)
				}
			})
		}
	})
}

// drawLogRepoBar declares the header of the commit list that names the repository the log walks,
// and, while a nested repository is walked, the way back to the project's own. It shows only in a
// workspace with nested repositories.
func (a *App) drawLogRepoBar(c ui.C, p *project) {
	if len(p.nested.repos) == 0 && p.nested.logRepo == "" {
		return
	}
	g := a.text.Git.Repositories
	id := commitRepositoryID
	if repo := p.logRepo(); repo != nil {
		id = repo.id
	}
	tint := a.repositoryTint(p, id)
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(6).Children(func() {
		ui.Icon(c, icons.Folder).Size(14, 14).Shrink(0).Color(tint)
		ui.Text(c, g.Current(p.repositoryName(id))).Weight(gfx.WeightMedium).Color(tint).Ellipsis().Grow(1)
		if p.nested.logRepo != "" {
			if ui.Button(c.Part("repo-back"), g.Back(p.repositoryName(commitRepositoryID))).Ghost().Clicked() {
				c.After(func() { a.setLogRepo(p, commitRepositoryID, "", "") })
			}
		}
	})
	ui.Divider(c)
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
	case !p.git.isRepository():
		a.gitEmpty(c, g.NotRepository)
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
	if l.hasMore || l.loadingMore {
		total++
	}
	area := ui.List(c, &v.commits, total, func(row ui.ListRow) { a.drawLogRow(c, p, rows, row) }).Grow(1).FillWidth()
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

// drawLogFooter declares the row under the list that loads the next page.
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
		default:
			if ui.Button(c.Part("load-more"), g.LoadMore).Ghost().Clicked() {
				c.After(func() { a.loadMoreLog(p) })
			}
		}
		ui.Spacer(c)
	})
}

// logCommitKey is the key of row i of the commit list in its selection: the key of the commit's
// hash, so a choice survives a reload that moves the rows. The row past the commits has none.
func (v *logView) logCommitKey(i int) int {
	if i < 0 || i >= len(v.keyRows) {
		return -1
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
	k := len(v.keys)
	v.keys[hash] = k
	return k
}
