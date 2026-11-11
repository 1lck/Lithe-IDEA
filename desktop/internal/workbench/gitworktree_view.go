package workbench

import (
	"math"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Worktrees tab is one Page: the list of the repository's worktrees beside the details of
// the selected one, with the dialogs that create and remove worktrees drawn by the Git
// overlay.

const (
	// worktreeHistoryInset is where a History row's subject starts when no graph is drawn
	// before it, and worktreeHistoryGap the room between its date and its short hash.
	worktreeHistoryInset = 10
	worktreeHistoryGap   = 12
	// worktreeHashSample is as wide as the short hashes Git prints in large repositories.
	worktreeHashSample = "0000000000"
	// worktreeLabelWidth is the width of the labels of an overview card's fields.
	worktreeLabelWidth = 110
	// worktreeCardRadius is the corner radius of an overview card.
	worktreeCardRadius = 6
)

// worktreePageView declares the body of the Worktrees tab.
func (a *App) worktreePageView(c ui.C) {
	p := a.project
	if p == nil {
		return
	}
	v := &a.worktreeView
	if v.split.Pos == 0 {
		v.split.Pos = worktreeListWidth
	}
	v.commit.begin()
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		if !a.drawCommitStatus(c, p) {
			return
		}
		if !p.worktrees.started {
			a.loadWorktrees(p)
		}
		ui.Row(c).Fill().Children(func() {
			a.drawWorktreeList(c, p).Width(v.split.Pos).Shrink(0)
			ui.Splitter(c, &v.split).Mins(worktreeListMin, worktreeDetailsMin).Label(a.text.Panel.Resize)
			a.drawWorktreeDetails(c, p).Grow(1)
		})
	})
}

// shownWorktrees are the worktrees whose path or branch holds the search's text.
func (a *App) shownWorktrees(p *project) []core.GitWorktree {
	query := strings.ToLower(strings.TrimSpace(a.worktreeView.search.Text()))
	if query == "" {
		return p.worktrees.list
	}
	var shown []core.GitWorktree
	for _, w := range p.worktrees.list {
		if strings.Contains(strings.ToLower(w.Path), query) || strings.Contains(strings.ToLower(w.Branch), query) {
			shown = append(shown, w)
		}
	}
	return shown
}

// drawWorktreeList declares the list pane: the search and the buttons, the count, the notice
// of stale registrations and the worktrees.
func (a *App) drawWorktreeList(c ui.C, p *project) ui.Box {
	w, v, t := &p.worktrees, &a.worktreeView, &a.text.Worktrees
	shown := a.shownWorktrees(p)
	return ui.Column(c).FillHeight().Background(a.colors.Panel).Clip().Children(func() {
		ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
			ui.TextField(c, &v.search, t.Search, t.Search).Grow(1).MinWidth(0)
			if a.gitIconButton(c, t.New, icons.Plus, false, w.busy || !w.loaded) {
				c.After(func() { a.beginCreateWorktree(p) })
			}
			if a.gitIconButton(c, t.Refresh, icons.RefreshCw, false, w.loading) {
				c.After(func() {
					a.performed("git.worktree.refresh", surfaceButton)
					a.loadWorktrees(p)
				})
			}
		})
		ui.Divider(c)
		switch {
		case !w.loaded:
			a.drawWorktreeEmpty(c, t.Loading, t.LoadingHint)
			return
		case w.err != nil:
			a.drawWorktreeEmpty(c, t.Unavailable, a.text.Git.Failed(w.err.Error()))
			return
		case len(w.list) == 0:
			a.drawWorktreeEmpty(c, t.Empty, t.EmptyHint)
			return
		}
		ui.Text(c, t.Count(len(w.list))).FontSize(a.theme.Metrics.FontSizeS).Muted().PadX(10).PadY(4).Shrink(0)
		if stale := w.stale(); stale > 0 {
			a.drawWorktreeStale(c, p, stale)
		}
		if len(shown) == 0 {
			a.drawWorktreeEmpty(c, t.NoMatches, t.NoMatchesHint)
			return
		}
		at := -1
		for i := range shown {
			if shown[i].Path == w.selected {
				at = i
			}
		}
		if cur := v.list.Selected(); !v.list.Changed() && cur != at {
			v.list.Select(at)
		}
		ui.List(c, &v.list, len(shown), func(row ui.ListRow) { a.drawWorktreeRow(p, shown, row) }).Label(a.text.Git.Worktrees).Grow(1).FillWidth()
		if v.list.Changed() {
			if i := v.list.Selected(); i >= 0 && i < len(shown) {
				selected := shown[i].Path
				c.After(func() { a.selectWorktree(p, selected) })
			}
		}
	})
}

// drawWorktreeStale declares the notice of registrations whose checkout is gone, with the
// buttons that prune and repair them.
func (a *App) drawWorktreeStale(c ui.C, p *project, stale int) {
	w, t := &p.worktrees, &a.text.Worktrees
	ui.Column(c).FillWidth().Shrink(0).Gap(6).Pad(8).Background(a.colors.Editor).Children(func() {
		ui.Text(c, t.Stale(stale)).Color(a.colors.Warning).Weight(gfx.WeightMedium)
		ui.Paragraph(c, t.StaleHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		ui.Row(c).Gap(6).Children(func() {
			if ui.Button(c, t.Prune).Outline().Disabled(w.busy).Clicked() {
				c.After(func() {
					a.performed("git.worktree.prune", surfaceButton)
					p.worktrees.dialog = worktreeDialogPrune
				})
			}
			if ui.Button(c, t.Repair).Ghost().Disabled(w.busy).Clicked() {
				c.After(func() { a.repairWorktrees(p) })
			}
		})
	})
}

// drawWorktreeEmpty declares a message with its hint that stands for an empty pane.
func (a *App) drawWorktreeEmpty(c ui.C, title, hint string) {
	ui.Column(c).Fill().Center().Gap(6).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, title, 2).TextCenter().Weight(gfx.WeightMedium)
		ui.Paragraph(c, hint, 4).TextCenter().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
}

// drawWorktreeRow declares one worktree of the list: its folder, its branch and its state.
func (a *App) drawWorktreeRow(p *project, shown []core.GitWorktree, row ui.ListRow) {
	if row.Index < 0 || row.Index >= len(shown) {
		return
	}
	w, c := shown[row.Index], row.C
	item := row.Element.FillWidth().PadX(10).PadY(5).Gap(8).Items(ui.Center).Tooltip(w.Path)
	if w.Path == p.worktrees.selected {
		item = item.Background(a.colors.Selection)
	} else {
		item = item.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	status := worktreeStatusOf(w, p.worktrees.counts[w.Path])
	item.Children(func() {
		icon := icons.GitBranch
		if w.IsLocked {
			icon = icons.Lock
		}
		ui.Icon(c, icon).Size(14, 14).Color(a.colors.Subtle)
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
			ui.Text(c, filepath.Base(w.Path)).Weight(gfx.WeightMedium).Ellipsis()
			ui.Text(c, a.worktreeBranchText(w)).FontSize(a.theme.Metrics.FontSizeS).Muted().Ellipsis()
		})
		ui.Text(c, a.worktreeStatusText(status)).FontSize(a.theme.Metrics.FontSizeS).Color(a.worktreeStatusColor(status)).Shrink(0)
	})
}

// worktreeBranchText names what a worktree has checked out.
func (a *App) worktreeBranchText(w core.GitWorktree) string {
	t := &a.text.Worktrees
	switch {
	case w.IsBare:
		return t.Bare
	case w.Branch != "":
		return t.BranchOf(strings.TrimPrefix(w.Branch, "refs/heads/"))
	}
	return t.Detached
}

// worktreeStatusText is the label of a worktree's state.
func (a *App) worktreeStatusText(s worktreeStatus) string {
	t := &a.text.Worktrees
	switch s {
	case worktreeMissing:
		return t.PathMissing
	case worktreeLocked:
		return t.Locked
	case worktreeModified:
		return t.Modified
	case worktreeCurrent:
		return t.Current
	}
	return t.Available
}

// worktreeStatusColor is the color of a worktree's state.
func (a *App) worktreeStatusColor(s worktreeStatus) gfx.Color {
	switch s {
	case worktreeMissing:
		return a.theme.Danger
	case worktreeLocked:
		return a.colors.Warning
	case worktreeModified:
		return a.colors.Accent
	case worktreeCurrent:
		return a.colors.Success
	}
	return a.colors.Subtle
}

// drawWorktreeDetails declares the details pane of the selected worktree: its tabs and what
// the chosen one shows.
func (a *App) drawWorktreeDetails(c ui.C, p *project) ui.Box {
	w, v, t := &p.worktrees, &a.worktreeView, &a.text.Worktrees
	selected, ok := w.find(w.selected)
	return ui.Column(c).FillHeight().Clip().Children(func() {
		if !ok {
			if w.loaded && w.err == nil && len(w.list) > 0 {
				a.drawWorktreeEmpty(c, t.Select, t.SelectHint)
			}
			return
		}
		ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).PadX(6).Children(func() {
			ui.Tabs(c, &v.tab, worktreeTabs, func(tab worktreeTab) string {
				switch tab {
				case worktreeTabChanges:
					return t.Changes
				case worktreeTabHistory:
					return t.History
				}
				return t.Overview
			})
			ui.Spacer(c)
			a.drawWorktreeActions(c, p, selected)
		})
		ui.Divider(c)
		switch v.tab {
		case worktreeTabChanges:
			a.drawWorktreeChanges(c, p, selected)
		case worktreeTabHistory:
			a.drawWorktreeHistory(c, p, selected)
		default:
			a.drawWorktreeOverview(c, p, selected)
		}
	})
}

// drawWorktreeOverview declares the cards of the Overview tab: what the worktree is, its
// state and what can be done with it.
func (a *App) drawWorktreeOverview(c ui.C, p *project, w core.GitWorktree) {
	ws, t := &p.worktrees, &a.text.Worktrees
	status := worktreeStatusOf(w, ws.counts[w.Path])
	ui.Scroll(c).Grow(1).FillWidth().Pad(shellContentPad).Gap(12).Children(func() {
		a.worktreeCard(c, t.BasicInformation, func() {
			a.worktreeField(c, t.Path, w.Path)
			a.worktreeField(c, t.Branch, a.worktreeBranchText(w))
			head := w.Head
			if len(head) > 12 {
				head = head[:12]
			}
			a.worktreeField(c, t.Head, head)
			role := t.Linked
			if w.IsPrimary {
				role = t.Primary
			}
			a.worktreeField(c, t.Role, role)
		})
		if w.IsPrunable {
			a.worktreeCard(c, t.MissingTitle, func() {
				ui.Paragraph(c, t.MissingHint, 4).Color(a.colors.Subtle)
				if w.PruneReason != "" {
					ui.Paragraph(c, w.PruneReason, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				}
				ui.Row(c).Gap(6).Children(func() {
					if ui.Button(c, t.Prune).Outline().Disabled(ws.busy).Clicked() {
						c.After(func() {
							a.performed("git.worktree.prune", surfaceButton)
							p.worktrees.dialog = worktreeDialogPrune
						})
					}
					if ui.Button(c, t.Repair).Ghost().Disabled(ws.busy).Clicked() {
						c.After(func() { a.repairWorktrees(p) })
					}
				})
			})
		} else {
			a.worktreeCard(c, t.Status, func() {
				ui.Row(c).FillWidth().Gap(12).Children(func() {
					ui.Text(c, t.Worktree).Muted().Width(worktreeLabelWidth).Shrink(0)
					ui.Text(c, a.worktreeStatusText(status)).Color(a.worktreeStatusColor(status))
				})
				a.worktreeField(c, t.Registration, t.Valid)
				protection := t.Unlocked
				if w.IsLocked {
					protection = t.Locked
					if w.LockReason != "" {
						protection = t.LockedBecause(w.LockReason)
					}
				}
				a.worktreeField(c, t.Protection, protection)
				changes := t.ChangesLoading
				if n, known := ws.counts[w.Path]; known {
					changes = t.NoChanges
					if n > 0 {
						changes = t.ChangedFiles(n)
					}
				} else if ws.countsKnown {
					changes = t.ChangesFailed
				}
				a.worktreeField(c, t.LocalChanges, changes)
			})
		}
	})
}

// drawWorktreeActions declares the buttons of the selected worktree's actions in the details
// header, where they stay in sight however short the tool window is. A button that cannot be
// used is named by the reason, which its hover hint shows.
func (a *App) drawWorktreeActions(c ui.C, p *project, w core.GitWorktree) {
	ws, t := &p.worktrees, &a.text.Worktrees
	action := func(label, blocked string, icon gfx.Icon, disabled bool, run func()) {
		if blocked != "" {
			label = blocked
		}
		if a.gitIconButton(c, label, icon, false, disabled || blocked != "") {
			c.After(run)
		}
	}
	action(t.OpenCurrent, "", icons.FolderOpen, w.IsCurrent || w.IsPrunable || w.IsBare, func() { a.openWorktree(w.Path) })
	action(i18n.Shared(a.language(), "desktop.worktree.openNewWindow"), "", icons.FolderOpen, w.IsPrunable || w.IsBare, func() { a.openWorktreeInNewWindow(w.Path) })
	action(t.Reveal, "", icons.Folder, w.IsPrunable, func() { a.revealWorktree(w.Path) })
	action(t.CopyPath, "", icons.Copy, false, func() { a.copyWorktreePath(w.Path) })
	lockLabel, lockIcon := t.Lock, icons.Lock
	if w.IsLocked {
		lockLabel, lockIcon = t.Unlock, icons.LockOpen
	}
	action(lockLabel, worktreeLockBlocked(t, w), lockIcon, ws.busy, func() { a.toggleWorktreeLock(p, w) })
	action(t.Remove, worktreeRemoveBlocked(t, w), icons.Trash2, ws.busy, func() { a.beginRemoveWorktree(p, w) })
}

// worktreeCard declares a card of the Overview tab with its title.
func (a *App) worktreeCard(c ui.C, title string, body func()) {
	ui.Column(c).FillWidth().Shrink(0).Background(a.colors.Panel).Radius(worktreeCardRadius).
		Border(1, a.colors.Line).Pad(12).Gap(8).Children(func() {
		ui.Text(c, title).Weight(gfx.WeightMedium)
		body()
	})
}

// worktreeField declares a labelled value of a card.
func (a *App) worktreeField(c ui.C, label, value string) {
	ui.Row(c).FillWidth().Gap(12).Children(func() {
		ui.Text(c, label).Muted().Width(worktreeLabelWidth).Shrink(0)
		ui.Paragraph(c, value, 3).Grow(1).Shrink(1).MinWidth(0)
	})
}

// drawWorktreeChanges declares the Changes tab: the local changes of the worktree, read when
// the tab is first shown, over the commit area that commits what is staged in it.
func (a *App) drawWorktreeChanges(c ui.C, p *project, w core.GitWorktree) {
	t := &a.text.Worktrees
	entry := p.worktrees.changes[w.Path]
	if entry == nil && !w.IsPrunable && !w.IsBare {
		a.loadWorktreeChanges(p, w.Path)
		entry = p.worktrees.changes[w.Path]
	}
	// busy holds the checkboxes while a write runs or the changes are read again, so a click
	// never acts on a row that went stale.
	busy := entry == nil || entry.busy || entry.loading
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		ui.Spacer(c)
		if entry != nil && len(entry.changes) > 0 {
			commit := a.text.Commit
			label, icon := commit.StageAll, icons.Plus
			if allStaged(entry.changes) {
				label, icon = commit.UnstageAll, icons.Minus
			}
			if a.gitIconButton(c, label, icon, false, busy || !hasToggleable(entry.changes)) {
				c.After(func() { a.stageAllWorktree(p, w.Path) })
			}
		}
		if a.gitIconButton(c, t.RefreshChanges, icons.RefreshCw, false, busy) {
			c.After(func() {
				a.performed("git.worktree.refreshChanges", surfaceButton)
				a.loadWorktreeChanges(p, w.Path)
			})
		}
	})
	ui.Divider(c)
	switch {
	case entry == nil:
		a.drawWorktreeEmpty(c, t.MissingTitle, t.MissingHint)
		return
	case entry.err != nil:
		a.drawWorktreeEmpty(c, t.ChangesFailed, entry.err.Error())
		return
	}
	list := func() ui.Box {
		return ui.Column(c).FillWidth().Clip().Children(func() {
			switch {
			case entry.loading && len(entry.changes) == 0:
				a.gitEmpty(c, t.ChangesLoading)
			case len(entry.changes) == 0:
				ui.Column(c).Fill().Center().Gap(8).Children(func() {
					ui.Icon(c, icons.Check).Size(20, 20).Color(a.colors.Success)
					ui.Text(c, t.Clean).Color(a.colors.Subtle)
				})
			default:
				a.drawChangeRows(c, t.LocalChanges, t.ChangedFiles(fileCount(entry.changes)), entry.changes, busy,
					func() { a.stageAllWorktree(p, w.Path) },
					func(change core.GitChange) { a.drawWorktreeChange(c, p, w.Path, busy, change) })
			}
		})
	}
	a.drawCommitBody(c, &a.worktreeView.commit, list, func() ui.Box {
		if p.projectCheckout(w.Path) {
			return a.drawCommitArea(c, p)
		}
		target := p.worktreeCommit(w.Path)
		return a.drawCommitAreaOf(c, p, commitArea{
			target: target,
			staged: countStaged(entry.changes),
			ready:  func() bool { return p.canCommitWorktree(w.Path, target.state) },
		})
	})
}

// drawWorktreeChange declares the row of one local change of the worktree at root, with the
// commit panel's checkbox; a double click shows its diff.
func (a *App) drawWorktreeChange(c ui.C, p *project, root string, busy bool, change core.GitChange) {
	toggled, opened, _, _ := a.drawChangeRow(c, change, busy, false, func(rowC ui.C) func(*ui.MenuItems) {
		return a.worktreeChangeMenuItems(rowC, p, root, change)
	})
	if toggled {
		c.After(func() { a.stageWorktreeChange(p, root, change) })
	}
	if opened && !strings.HasSuffix(change.Path, "/") {
		c.After(func() { a.openDiffIn(p, root, change) })
	}
}

// worktreeChangeMenuItems is the context menu of a change of the worktree at root: its diff,
// copying its path, and its rollback.
func (a *App) worktreeChangeMenuItems(c ui.C, p *project, root string, change core.GitChange) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		menu.WidthRange(220, 320)
		_, review := a.reviewKernel()
		folder := strings.HasSuffix(change.Path, "/")
		if review && !folder && menu.Item(i18n.Shared(a.language(), "git.showDiff")).Clicked() {
			c.After(func() { a.openDiffIn(p, root, change) })
		}
		if menu.Item(a.text.Worktrees.CopyPath).Clicked() {
			c.After(func() {
				a.copyWorktreePath(filepath.Join(root, filepath.FromSlash(strings.TrimSuffix(change.Path, "/"))))
			})
		}
		if !review {
			return
		}
		menu.Separator()
		if menu.Item(i18n.Shared(a.language(), "git.rollback")).Destructive().Clicked() {
			c.After(func() { a.openRollbackIn(p, root, []core.GitChange{change}) })
		}
	}
}

// drawWorktreeHistory declares the History tab: the commits reachable from the worktree's
// HEAD, read a page at a time, filtered by the search.
func (a *App) drawWorktreeHistory(c ui.C, p *project, w core.GitWorktree) {
	v, t := &a.worktreeView, &a.text.Worktrees
	h := &p.worktrees.history
	if !w.IsPrunable && (h.path != w.Path || (!h.loading && !h.loaded && h.err == nil)) {
		a.loadWorktreeHistory(p, w.Path)
	}
	ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		ui.TextField(c, &v.commitSearch, t.SearchCommits, t.SearchCommits).Grow(1).MinWidth(0).MaxWidth(360)
		ui.Spacer(c)
		if a.gitIconButton(c, t.RefreshHistory, icons.RefreshCw, false, h.loading) {
			c.After(func() {
				a.performed("git.worktree.refreshHistory", surfaceButton)
				a.loadWorktreeHistory(p, w.Path)
			})
		}
	})
	ui.Divider(c)
	switch {
	case w.IsPrunable:
		a.drawWorktreeEmpty(c, t.MissingTitle, t.MissingHint)
		return
	case h.err != nil:
		a.gitEmpty(c, t.HistoryFailed(h.err.Error()))
		return
	case !h.loaded:
		a.gitEmpty(c, t.CommitsLoading)
		return
	case len(h.commits) == 0:
		a.gitEmpty(c, t.NoCommits)
		return
	}
	query := strings.ToLower(strings.TrimSpace(v.commitSearch.Text()))
	commits := h.commits
	if query != "" {
		commits = nil
		for _, commit := range h.commits {
			if strings.Contains(strings.ToLower(commit.Subject), query) || strings.HasPrefix(commit.Hash, query) ||
				strings.Contains(strings.ToLower(commit.AuthorName), query) {
				commits = append(commits, commit)
			}
		}
		if len(commits) == 0 {
			a.gitEmpty(c, t.NoMatchingCommits)
			return
		}
	}
	v.shown, v.graphed = commits, query == "" && len(h.graph.Rows) == len(commits)
	total := len(commits)
	more := h.cursor != "" || h.loadingMore
	if more {
		total++
	}
	area := ui.List(c, &v.commits, total, func(row ui.ListRow) { a.drawWorktreeCommit(p, commits, row) }).Label(t.History).Grow(1).FillWidth()
	if s := area.ScrollState(); h.cursor != "" && s.Content > 0 && s.Offset+s.Viewport >= s.Content-worktreeLoadMoreMargin {
		a.loadMoreWorktreeHistory(p)
	}
}

// drawWorktreeCommit declares one commit of the History tab, whose graph and texts the draw
// callback paints as the Log tab paints its rows, or the row under the commits that reads the
// next page.
func (a *App) drawWorktreeCommit(p *project, commits []core.GitCommit, row ui.ListRow) {
	c := row.C
	if row.Index < len(commits) {
		row.Element.Height(logRowHeight).FillWidth().Label(commits[row.Index].Subject).
			Hover(ui.Look{}.Background(a.colors.Hover)).Draw(a.worktreeView.commitPainter(a, row.Index))
		return
	}
	{
		h, t := &p.worktrees.history, &a.text.Worktrees
		row.Element.Height(logRowHeight).FillWidth().PadX(10).Gap(8).Items(ui.Center).Children(func() {
			ui.Spacer(c)
			switch {
			case h.failed:
				ui.Text(c, t.MoreFailed).Color(a.colors.Warning)
				if ui.Button(c.Part("retry-more"), a.text.Git.Retry).Ghost().Clicked() {
					c.After(func() {
						h.failed = false
						a.loadMoreWorktreeHistory(p)
					})
				}
			default:
				ui.Text(c, t.CommitsLoading).Muted()
			}
			ui.Spacer(c)
		})
	}
}

// commitPainter is the draw callback of the History tab's row index, from a slot reused by
// every row that falls on it.
func (v *worktreeView) commitPainter(a *App, index int) func(*ui.DrawContext) {
	slot := index % logRowSlots
	v.slotRow[slot] = index
	if v.painters[slot] == nil {
		v.painters[slot] = func(d *ui.DrawContext) { a.paintWorktreeCommit(d.Canvas, d.Rect, v.slotRow[slot]) }
	}
	return v.painters[slot]
}

// paintWorktreeCommit paints row index of the History tab into rect: the lanes of the graph
// and the references when the list is the whole history, then the subject, the author, the
// date and the short hash.
func (a *App) paintWorktreeCommit(canvas *gfx.Canvas, rect gfx.Rect, index int) {
	v := &a.worktreeView
	if a.project == nil || index >= len(v.shown) || rect.Width <= 0 || rect.Height <= 0 {
		return
	}
	h := &a.project.worktrees.history
	commit := v.shown[index]
	canvas.Clip(rect)
	defer canvas.Unclip()
	start := float32(worktreeHistoryInset)
	var labels []core.GraphLabel
	if v.graphed && index < len(h.graph.Rows) && h.graph.Rows[index].CommitHash == commit.Hash {
		row := h.graph.Rows[index]
		a.paintGraphRow(canvas, newGraphMetrics(canvas.PixelScale()), rect, row, a.graphColors())
		start, labels = titleOffset(row), row.Labels
	}
	foreground := a.colors.Text
	if len(commit.ParentHashes) > 1 {
		foreground = mergeForeground(a.colors.Dark)
	}
	// The columns from the right: the short hash, the date and the author, as wide as the
	// Log tab's.
	if fonts := canvas.FontGeneration(); v.hashWidth == 0 || v.hashFonts != fonts {
		v.hashWidth, v.hashFonts = canvas.TextWidth(worktreeHashSample, logMetaSize), fonts
	}
	dateWidth := a.logView.dateColumn(canvas)
	hashX := rect.Width - logDatePad - v.hashWidth
	dateX := hashX - worktreeHistoryGap - dateWidth
	authorX := max(start, dateX-logAuthorWidth-logDatePad)
	end := max(start, authorX-logDatePad)
	if len(labels) > 0 {
		group := groupReferences(labels, h.current, nil)
		column := end - start
		subject := canvas.TextWidth(commit.Subject, logFontSize)
		available := max(0, min(column-subject, column/3))
		icon := group.iconWidth(logRefSize + 3)
		text := shortenTitle(canvas, group.title, available-icon-9, logRefSize)
		textWidth := float32(0)
		if text != "" {
			textWidth = float32(math.Ceil(float64(canvas.TextWidth(text, logRefSize)))) + 1
		}
		width := min(column, icon+textWidth+8)
		end -= width
		a.paintLabels(canvas, gfx.Rect{X: rect.X + end, Y: rect.Y, Width: width, Height: rect.Height}, group, text, a.colors.Editor)
	}
	a.paintText(canvas, commit.Subject, gfx.Rect{X: rect.X + start, Y: rect.Y, Width: max(0, end-start), Height: rect.Height}, logFontSize, foreground, gfx.AlignStart)
	a.paintText(canvas, commit.AuthorName, gfx.Rect{X: rect.X + authorX, Y: rect.Y, Width: max(0, dateX-authorX-logDatePad), Height: rect.Height}, logMetaSize, a.colors.Subtle, gfx.AlignStart)
	a.paintText(canvas, a.logView.date(commit), gfx.Rect{X: rect.X + dateX, Y: rect.Y, Width: dateWidth, Height: rect.Height}, logMetaSize, a.colors.Subtle, gfx.AlignEnd)
	a.paintText(canvas, commit.ShortHash, gfx.Rect{X: rect.X + hashX, Y: rect.Y, Width: v.hashWidth, Height: rect.Height}, logMetaSize, a.colors.Subtle, gfx.AlignEnd)
}

// drawWorktreeDialog declares the open dialog of p's Worktrees tab.
func (a *App) drawWorktreeDialog(c ui.C, p *project) {
	if p == nil {
		return
	}
	w, t := &p.worktrees, &a.text.Worktrees
	switch w.dialog {
	case worktreeDialogCreate:
		a.drawWorktreeCreateDialog(c, p)
	case worktreeDialogRemove:
		name := worktreeName(w.target)
		a.worktreeConfirm(c, t.RemoveTitle, t.RemovePrompt(name), "", t.RemoveButton, func() { a.removeWorktree(p, false) })
	case worktreeDialogReview:
		name := worktreeName(w.target)
		a.worktreeConfirm(c, t.RemoveTitle, t.RemovePrompt(name), w.refusal, t.ReviewForce, func() {
			p.worktrees.dialog = worktreeDialogForce
		})
	case worktreeDialogForce:
		a.worktreeConfirm(c, t.ForceTitle, t.ForcePrompt(worktreeName(w.target)), "", t.ForceButton, func() {
			a.performed("git.worktree.forceRemove", surfaceButton)
			a.removeWorktree(p, true)
		})
	case worktreeDialogPrune:
		a.worktreeConfirm(c, t.PruneTitle, t.PrunePrompt, "", t.Prune, func() { a.pruneWorktrees(p) })
	}
}

// worktreeConfirm declares a dialog that asks before a destructive write; note, when not
// empty, is what Git said, shown under the question.
func (a *App) worktreeConfirm(c ui.C, title, prompt, note, confirm string, run func()) {
	t := &a.text.Worktrees
	busy := a.project != nil && a.project.worktrees.busy
	open := true
	body := func() {
		if note != "" {
			ui.Paragraph(c, note, 6).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
	}
	footer := func() {
		if ui.Button(c, t.Cancel).Outline().Disabled(busy).Clicked() {
			c.After(a.cancelWorktreeDialog)
		}
		if ui.Button(c, confirm).Destructive().Disabled(busy).Clicked() {
			c.After(run)
		}
	}
	if ui.ModalWith(c, &open, title, ui.ModalSpec{Description: prompt, Width: branchDialogWidth}, body, footer) {
		c.After(a.cancelWorktreeDialog)
	}
}

// drawWorktreeCreateDialog declares the dialog that creates a worktree.
func (a *App) drawWorktreeCreateDialog(c ui.C, p *project) {
	a.syncWorktreeCreation(p)
	w, t := &p.worktrees, &a.text.Worktrees
	cr := &w.create
	ready := !w.busy && cr.ready()
	problem := a.branchNameErrorText(cr.preview.Error)
	choices := cr.referenceChoices(w.list)
	names := make([]string, len(choices))
	for i, r := range choices {
		names[i] = r.FullName
	}
	shortName := func(full string) string {
		for _, r := range choices {
			if r.FullName == full {
				return r.ShortName
			}
		}
		return full
	}
	submitted := false
	open := true
	body := func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Select(c, &cr.mode, worktreeModes, func(mode string) string {
				switch mode {
				case core.GitWorktreeExistingBranch:
					return t.ExistingBranch
				case core.GitWorktreeDetached:
					return t.DetachedMode
				}
				return t.NewBranch
			}).Label(t.Mode).FillWidth()
			switch {
			case !cr.refsLoaded:
				ui.Text(c, t.ReferencesLoading).Muted()
			case cr.refsErr != nil:
				ui.Paragraph(c, a.text.Git.Failed(cr.refsErr.Error()), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			default:
				if cr.mode != core.GitWorktreeExistingBranch {
					ui.Select(c, &cr.kind, worktreeReferenceKinds, func(kind string) string {
						switch kind {
						case "remote":
							return t.RemoteBranches
						case "tag":
							return t.Tags
						}
						return t.LocalBranches
					}).Label(t.Reference).FillWidth()
				}
				if len(names) == 0 && cr.mode == core.GitWorktreeExistingBranch {
					ui.Paragraph(c, t.NoFreeBranch, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
				} else if len(names) > 0 {
					ui.Select(c, &cr.reference, names, shortName).Label(t.Reference).FillWidth()
				}
			}
			switch cr.mode {
			case core.GitWorktreeNewBranch:
				submitted = ui.TextField(c, &cr.name, t.BranchName, t.BranchName).FillWidth().Submitted() || submitted
				if problem != "" {
					ui.Paragraph(c, problem, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			case core.GitWorktreeDetached:
				submitted = ui.TextField(c, &cr.revision, t.Revision, t.Revision).FillWidth().Submitted() || submitted
				ui.Paragraph(c, t.RevisionHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				ui.Paragraph(c, t.DetachedHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
			submitted = ui.TextField(c, &cr.destination, t.Destination, t.Destination).FillWidth().Submitted() || submitted
			if !filepath.IsAbs(strings.TrimSpace(cr.destination.Text())) {
				ui.Paragraph(c, t.DestinationAbsolute, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			ui.Checkbox(c, &cr.noCheckout, t.NoCheckout).Disabled(w.busy)
			if cr.noCheckout {
				ui.Paragraph(c, t.NoCheckoutHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
			ui.Select(c, &cr.after, worktreeAfterChoices, func(after worktreeAfterCreate) string {
				if after == worktreeOpenAfter {
					return t.OpenAfter
				}
				return t.Stay
			}).Label(t.AfterCreate).FillWidth()
		})
	}
	footer := func() {
		if ui.Button(c, t.Cancel).Outline().Disabled(w.busy).Clicked() {
			c.After(a.cancelWorktreeDialog)
		}
		if ui.Button(c, t.Create).Disabled(!ready).Clicked() {
			c.After(func() { a.submitCreateWorktree(p) })
		}
	}
	if ui.ModalWith(c, &open, t.CreateTitle, ui.ModalSpec{Width: branchDialogWidth}, body, footer) {
		c.After(a.cancelWorktreeDialog)
	}
	if submitted && ready {
		c.After(func() { a.submitCreateWorktree(p) })
	}
}
