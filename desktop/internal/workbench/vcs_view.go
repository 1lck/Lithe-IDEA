package workbench

import (
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the tool window of a plugin version control provider: the working copy it
// shows and where it is, the toolbar of the provider's actions, and either the local changes over
// the commit area or the revisions. What Core found decides which working copies exist, and what
// the provider negotiated decides which actions show. State and actions are in vcs.go.

const (
	// vcsListHeight is the first height of the revisions over the details of one, and vcsListMin
	// the least either keeps. The changes over the commit area share the Commit window's sizes.
	vcsListHeight = 240
	vcsListMin    = 80
	// vcsRollbackShown is how many paths the rollback dialog names before it only counts them.
	vcsRollbackShown = 8
)

// vcsView declares the window of the provider of it in project p.
func (a *App) vcsView(c ui.C, p *project, it item) {
	window, s, lang := it.vcs, &p.vcs, a.language()
	// The first paint of the window starts the detection, as the Run window starts its own:
	// After only runs in the paint of a click, and nothing has to be clicked here.
	if !s.detected && !s.detecting {
		a.detectVcsRoots(p)
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		if reason := s.rejection(window.PluginID); reason != "" {
			a.panelMessage(c, reason, a.theme.Danger)
			return
		}
		switch {
		case !s.detected:
			a.gitEmpty(c, i18n.Shared(lang, "native.detectingWorkingCopies"))
			return
		case s.failure != "":
			a.vcsDetectAgain(c, p, s.failure, a.theme.Danger)
			return
		}
		a.drawVcsAmbiguous(c, p, window)
		if s.detection.Truncated {
			a.vcsWarning(c, i18n.Shared(lang, "native.theWorkspaceIsTooLargeToSearchCompletelySomeWorkingCopiesMayBeMissing"))
		}
		t, ok := p.vcsTarget(it.id, window)
		if !ok {
			message := i18n.SharedFormat(lang, "native.noArg1WorkingCopyWasDetectedInThisWorkspace", map[string]string{"arg1": window.DisplayName})
			a.vcsDetectAgain(c, p, message, a.colors.Subtle)
			return
		}
		a.drawVcsHeader(c, p, t)
		ui.Divider(c)
		a.drawVcsToolbar(c, p, t)
		ui.Divider(c)
		if t.view.history && t.view.can(core.VcsCapabilityHistory) {
			a.drawVcsHistory(c, p, t)
		} else {
			a.drawVcsChanges(c, p, t)
		}
	})
	if t, ok := p.vcsTarget(it.id, window); ok && t.view.rollback != nil {
		a.drawVcsRollbackDialog(c, p, t)
	}
}

// vcsWarning declares a line that says what the window may not show.
func (a *App) vcsWarning(c ui.C, message string) {
	ui.Row(c).FillWidth().Shrink(0).PadX(8).PadY(4).Children(func() {
		ui.Paragraph(c, message, 3).Grow(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
	})
}

// vcsDetectAgain declares a message in place of the working copies, with the button that has
// Core look for them again.
func (a *App) vcsDetectAgain(c ui.C, p *project, message string, color gfx.Color) {
	ui.Column(c).Fill().Center().Gap(8).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, message, 4).TextCenter().Color(color)
		if ui.Button(c, i18n.Shared(a.language(), "native.detectAgain2")).Outline().Disabled(p.vcs.detecting).Clicked() {
			c.After(func() {
				a.performed("vcs.detect", surfaceButton)
				a.detectVcsRoots(p)
			})
		}
	})
}

// vcsRootLabel names a working copy or an ambiguous directory by its place in the workspace.
func (a *App) vcsRootLabel(id string) string {
	if id == "" {
		return i18n.Shared(a.language(), "native.theWorkspace")
	}
	return id
}

// drawVcsAmbiguous declares, for each directory holding the metadata of the window's VCS among
// others, the question of which one manages it, with a button for each candidate.
func (a *App) drawVcsAmbiguous(c ui.C, p *project, window *vcsWindow) {
	s, lang := &p.vcs, a.language()
	for _, directory := range s.ambiguous(window.Vcs) {
		ui.Column(c.Key("ambiguous:" + directory.ID)).FillWidth().Shrink(0).Gap(6).PadX(8).PadY(6).Children(func() {
			ui.Paragraph(c, i18n.SharedFormat(lang, "native.arg1HoldsTheMetadataOfSeveralVersionControlSystemsChooseTheOneThatManagesIt",
				map[string]string{"arg1": a.vcsRootLabel(directory.ID)}), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
			ui.Row(c).FillWidth().Gap(6).Children(func() {
				for _, vcs := range directory.Vcs {
					name := vcs
					if descriptor := s.detection.Provider(vcs); descriptor != nil && descriptor.DisplayName != "" {
						name = descriptor.DisplayName
					}
					if ui.Button(c.Key(vcs), name).Outline().Small().Disabled(s.detecting).Clicked() {
						id, chosen := directory.ID, vcs
						c.After(func() {
							a.performed("vcs.mapRoot", surfaceButton)
							a.mapVcsRoot(p, id, chosen)
						})
					}
				}
			})
		})
		ui.Divider(c)
	}
}

// drawVcsHeader declares the working copy the window shows, a picker when Core found several,
// where it is in the repository, and the tabs of the changes and the revisions.
func (a *App) drawVcsHeader(c ui.C, p *project, t vcsTarget) {
	lang := a.language()
	roots := p.vcs.roots(t.window.Vcs)
	ui.Row(c).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		if len(roots) > 1 {
			ids := make([]string, len(roots))
			for index, root := range roots {
				ids[index] = root.ID
			}
			selected := t.view.root
			ui.Select(c.Part("vcs-root"), &selected, ids, a.vcsRootLabel).
				Label(i18n.Shared(lang, "native.workingCopy")).Shrink(1).MinWidth(0).MaxWidth(240)
			if selected != t.view.root {
				c.After(func() { t.view.root = selected })
			}
		} else {
			ui.Text(c, a.vcsRootLabel(t.root.ID)).Weight(gfx.WeightMedium).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		}
		if head := vcsHeadLine(t.state.status); head != "" {
			ui.Text(c, head).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		}
		ui.Spacer(c)
		if t.view.can(core.VcsCapabilityHistory) {
			tab := "changes"
			if t.view.history {
				tab = "history"
			}
			ui.Tabs(c.Part("vcs-tabs"), &tab, []string{"changes", "history"}, func(id string) string {
				if id == "history" {
					return i18n.Shared(lang, "native.history")
				}
				return i18n.Shared(lang, "native.changes")
			}).Shrink(0)
			if history := tab == "history"; history != t.view.history {
				c.After(func() { t.view.history = history })
			}
		}
	})
}

// vcsHeadLine is where the working copy is: its revision, branch and remote location, as the
// provider names them.
func vcsHeadLine(status *core.VcsStatusReply) string {
	if status == nil {
		return ""
	}
	var parts []string
	if label := status.Head.Revision.Label(); label != "" {
		parts = append(parts, label)
	}
	for _, part := range []*string{status.Head.Branch, status.Head.Location} {
		if part != nil && *part != "" {
			parts = append(parts, *part)
		}
	}
	return strings.Join(parts, " · ")
}

// drawVcsToolbar declares the provider's actions on the working copy and the selected change:
// read the changes again, update the working copy, roll back or show the diff of the selected
// change, mark its conflict resolved, clean up the working copy, and look for working copies
// again. An action shows only when the provider negotiated it.
func (a *App) drawVcsToolbar(c ui.C, p *project, t vcsTarget) {
	lang, view, state := a.language(), t.view, t.state
	busy := view.busy != ""
	change := state.change(state.selected)
	ui.Row(c).Height(logToolbarHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		if a.gitIconButton(c, i18n.Shared(lang, "desktop.gitReview.refresh"), icons.RefreshCw, false, state.loading) {
			c.After(func() {
				a.performed("vcs.refresh", surfaceButton)
				a.refreshVcsStatus(p, t)
				if state.historyLoaded {
					a.loadVcsHistory(p, t, false)
				}
			})
		}
		if view.can(core.VcsCapabilityUpdate) && a.gitIconButton(c, i18n.Shared(lang, "native.updateProject"), icons.ArrowDownToLine, false, busy) {
			c.After(func() { a.updateVcs(p, t) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "git.showDiff"), icons.Eye, false, change == nil) {
			selected := *change
			c.After(func() { a.showVcsDiff(p, t, selected) })
		}
		if a.gitIconButton(c, i18n.Shared(lang, "native.rollBack.variant2"), icons.Undo2, false, busy || change == nil || !vcsVersioned(change)) {
			paths := vcsPaths(change)
			c.After(func() { view.rollback = paths })
		}
		if view.can(core.VcsCapabilityConflicts) && a.gitIconButton(c, i18n.Shared(lang, "native.markAsResolved"), icons.CircleCheck, false,
			busy || change == nil || vcsSection(change) != vcsSectionConflicts) {
			paths := []string{change.Path}
			c.After(func() { a.resolveVcs(p, t, paths) })
		}
		if view.can(core.VcsCapabilityCleanup) && a.gitIconButton(c, i18n.Shared(lang, "native.cleanUpWorkingCopy"), icons.Eraser, false, busy) {
			c.After(func() { a.cleanupVcs(p, t) })
		}
		ui.Spacer(c)
		if a.gitIconButton(c, i18n.Shared(lang, "native.detectAgain2"), icons.Locate, false, p.vcs.detecting) {
			c.After(func() {
				a.performed("vcs.detect", surfaceButton)
				a.detectVcsRoots(p)
			})
		}
	})
}

// drawVcsChanges declares the changes of the working copy over the commit area, and the result
// of the last action.
func (a *App) drawVcsChanges(c ui.C, p *project, t vcsTarget) {
	lang, view, state := a.language(), t.view, t.state
	if state.status == nil && !state.loading && state.failure == "" {
		a.refreshVcsStatus(p, t)
	}
	view.commit.begin()
	if state.status != nil && state.status.Truncated {
		a.vcsWarning(c, i18n.Shared(lang, "native.thereAreTooManyChangesToListSomeAreNotShown"))
	}
	// The commit area keeps its height and the changes take the rest, as in the Commit window,
	// so a short tool window still shows the message and the Commit button.
	a.drawCommitBody(c, &view.commit, func() ui.Box { return a.drawVcsChangeList(c, p, t) },
		func() ui.Box { return a.drawVcsCommitArea(c, p, t) })
	for _, line := range []struct {
		text  string
		color gfx.Color
	}{{view.notice, a.colors.Success}, {view.failure, a.theme.Danger}} {
		if line.text != "" {
			ui.Row(c).FillWidth().Shrink(0).PadX(8).PadY(4).Children(func() {
				ui.Paragraph(c, line.text, 3).Grow(1).FontSize(a.theme.Metrics.FontSizeS).Color(line.color)
			})
		}
	}
}

// drawVcsChangeList declares the changes of the working copy by section, or why there are none.
func (a *App) drawVcsChangeList(c ui.C, p *project, t vcsTarget) ui.Box {
	lang, state := a.language(), t.state
	return ui.Column(c.Part("vcs-changes")).FillWidth().Clip().Children(func() {
		switch {
		case state.failure != "":
			a.panelMessage(c, state.failure, a.theme.Danger)
		case state.status == nil:
			a.gitEmpty(c, i18n.Shared(lang, "native.readingChanges"))
		case len(state.rows) == 0:
			a.gitEmpty(c, i18n.Shared(lang, "native.noLocalChanges"))
		default:
			ui.Scroll(c).Grow(1).FillWidth().PadY(4).Children(func() {
				for _, row := range state.rows {
					if row.change < 0 {
						a.drawVcsSection(c, state, row.section)
						continue
					}
					a.drawVcsChangeRow(c, p, t, &state.status.Changes[row.change])
				}
			})
		}
	})
}

// drawVcsSection declares the title of a section of the changes, with how many it holds.
func (a *App) drawVcsSection(c ui.C, state *vcsRootView, section int) {
	lang := a.language()
	title := i18n.Shared(lang, "native.changes")
	switch section {
	case vcsSectionConflicts:
		title = i18n.Shared(lang, "native.conflicts")
	case vcsSectionUnversioned:
		title = i18n.Shared(lang, "native.unversionedFiles")
	}
	ui.Row(c.Key("section:" + strconv.Itoa(section))).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.Text(c, title).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		ui.Text(c, strconv.Itoa(state.sectionCount(section))).Muted().Shrink(0)
	})
}

// drawVcsChangeRow declares the row of one change: whether it is in the commit, its name and
// folder in the color of its status, what else the provider says of it, and its status. A click
// selects it, a double click opens its diff, and its context menu has the actions on it.
func (a *App) drawVcsChangeRow(c ui.C, p *project, t vcsTarget, change *core.VcsChange) {
	lang, view, state := a.language(), t.view, t.state
	busy := view.busy != ""
	selected := change.Path == state.selected
	section := vcsSection(change)
	dir, name := path.Split(change.Path)
	rowC := c.Key(change.Path)
	row := ui.Row(rowC).Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).
		PadSides(0, 8, 0, float32(8+logIndent)).Hover(ui.Look{}.Background(a.colors.Hover)).
		HitWith(ui.ID(rowC), change.Path, gfx.HitOptions{Cursor: gfx.PointerCursorHand})
	if selected {
		row = row.Background(a.colors.Selection)
	}
	current := *change
	ui.ContextMenu(rowC, row, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "git.showDiff")).Clicked() {
			rowC.After(func() { a.showVcsDiff(p, t, current) })
		}
		if section == vcsSectionConflicts && view.can(core.VcsCapabilityConflicts) {
			if menu.Item(i18n.Shared(lang, "native.markAsResolved")).Disabled(busy).Clicked() {
				rowC.After(func() { a.resolveVcs(p, t, []string{current.Path}) })
			}
		}
		if vcsVersioned(&current) {
			menu.Separator()
			if menu.Item(i18n.Shared(lang, "native.rollBack.variant2")).Destructive().Disabled(busy).Clicked() {
				rowC.After(func() { view.rollback = vcsPaths(&current) })
			}
		}
	})
	row.Children(func() {
		included := state.included(change)
		if ui.Checkbox(rowC, &included, "").Label(i18n.Shared(lang, "native.includeInCommit")).
			Disabled(busy || section == vcsSectionConflicts).Clicked() {
			path, include := change.Path, !state.included(change)
			rowC.After(func() {
				if state.include == nil {
					state.include = map[string]bool{}
				}
				state.include[path] = include
			})
		}
		ui.Icon(rowC, fileicons.ForFile(name, a.colors.Dark)).Size(14, 14).Color(a.colors.Subtle)
		ui.Text(rowC, name).Color(a.vcsStatusColor(change)).Ellipsis().Shrink(0).MaxWidth(320)
		ui.Text(rowC, strings.TrimSuffix(dir, "/")).Muted().Ellipsis().Grow(1)
		if detail := a.vcsChangeDetail(change); detail != "" {
			ui.Text(rowC, detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		}
		ui.Text(rowC, a.vcsStatusTitle(change.Status)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
	if row.Clicked() {
		path := change.Path
		rowC.After(func() { state.selected = path })
	}
	if row.DoubleClicked() {
		rowC.After(func() { a.showVcsDiff(p, t, current) })
	}
}

// vcsStatusColor is the color of a change's name by its status.
func (a *App) vcsStatusColor(change *core.VcsChange) gfx.Color {
	switch {
	case vcsSection(change) == vcsSectionConflicts, change.Status == "unversioned":
		return a.colors.Warning
	case change.Status == "added" || change.Status == "copied":
		return a.colors.Success
	case change.Status == "deleted" || change.Status == "missing":
		return a.colors.Deleted
	case change.Status == "ignored":
		return a.colors.Subtle
	}
	return a.colors.Accent
}

// vcsStatusTitle names a status of the contract.
func (a *App) vcsStatusTitle(status string) string {
	lang := a.language()
	switch status {
	case "added":
		return i18n.Shared(lang, "native.added")
	case "copied":
		return i18n.Shared(lang, "native.copied")
	case "deleted":
		return i18n.Shared(lang, "native.deleted")
	case "missing":
		return i18n.Shared(lang, "native.missing")
	case "renamed":
		return i18n.Shared(lang, "native.renamed")
	case "replaced":
		return i18n.Shared(lang, "native.replaced")
	case "typeChanged":
		return i18n.Shared(lang, "native.typeChanged")
	case "unversioned":
		return i18n.Shared(lang, "native.unversioned")
	case "ignored":
		return i18n.Shared(lang, "native.ignored")
	case "conflicted":
		return i18n.Shared(lang, "native.conflicted")
	case "switched":
		return i18n.Shared(lang, "native.switched")
	}
	return i18n.Shared(lang, "native.modified")
}

// vcsChangeDetail is what the provider says of a change beyond its status: where it moved from,
// a tree conflict, a lock, and changed properties.
func (a *App) vcsChangeDetail(change *core.VcsChange) string {
	lang := a.language()
	var details []string
	if change.OldPath != nil && *change.OldPath != change.Path {
		details = append(details, i18n.SharedFormat(lang, "native.movedFromArg1", map[string]string{"arg1": *change.OldPath}))
	}
	for _, flag := range change.Flags {
		switch flag {
		case "treeConflict":
			details = append(details, i18n.Shared(lang, "native.treeConflict"))
		case "locked":
			details = append(details, i18n.Shared(lang, "native.lockedInThisWorkingCopy"))
		case "lockedByOther":
			details = append(details, i18n.Shared(lang, "native.lockedByAnotherUser"))
		case "propertiesModified":
			details = append(details, i18n.Shared(lang, "native.propertiesModified"))
		}
	}
	return strings.Join(details, " · ")
}

// drawVcsCommitArea declares the commit message, the button that commits the included changes,
// how many are included, and, for a VCS without a separate push, that a commit goes to the
// repository right away.
func (a *App) drawVcsCommitArea(c ui.C, p *project, t vcsTarget) ui.Box {
	view, state, text, lang := t.view, t.state, a.text.Commit, a.language()
	busy := view.busy != ""
	paths := state.commitPaths()
	ready := !busy && len(paths) > 0 && strings.TrimSpace(view.message.Text()) != ""
	return ui.Column(c).FillWidth().Clip().Pad(8).Gap(6).Children(func() {
		message := ui.TextArea(c, &view.message, text.MessageLabel, text.MessagePlaceholder).FillWidth().Grow(1).Disabled(busy)
		if message.Shortcut(ui.Primary, "enter") && ready {
			c.After(func() { a.commitVcs(p, t) })
		}
		if !view.can(core.VcsCapabilityPush) {
			ui.Paragraph(c, i18n.Shared(lang, "desktop.vcs.commitDirectly"), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			label := text.Commit
			if view.busy == core.VcsCheckin {
				label = text.Committing
			}
			if ui.Button(c, label).Disabled(!ready).Clicked() {
				c.After(func() { a.commitVcs(p, t) })
			}
			ui.Spacer(c)
			count := 0
			if state.status != nil {
				for index := range state.status.Changes {
					if state.included(&state.status.Changes[index]) {
						count++
					}
				}
			}
			ui.Text(c, i18n.SharedFormat(lang, "native.arg1FilesSelected", map[string]string{"arg1": strconv.Itoa(count)})).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		})
	})
}

// drawVcsHistory declares the revisions of the working copy, newest first, over the selected
// one's message and changed paths, with the button that reads older revisions.
func (a *App) drawVcsHistory(c ui.C, p *project, t vcsTarget) {
	lang, view, state := a.language(), t.view, t.state
	if !state.historyLoaded && !state.historyLoading && state.historyFailure == "" {
		a.loadVcsHistory(p, t, false)
	}
	switch {
	case state.historyFailure != "" && len(state.history) == 0:
		a.panelMessage(c, state.historyFailure, a.theme.Danger)
		return
	case !state.historyLoaded:
		a.gitEmpty(c, a.text.Git.Loading)
		return
	case len(state.history) == 0:
		a.gitEmpty(c, i18n.Shared(lang, "native.noRevisions"))
		return
	}
	if view.split.Pos == 0 {
		view.split.Pos = vcsListHeight
	}
	if !view.revisions.Changed() && view.revisions.Selected() != state.revision {
		view.revisions.Select(state.revision)
	}
	ui.Column(c.Part("vcs-history")).FillWidth().Height(view.split.Pos).Shrink(0).Clip().Children(func() {
		ui.List(c, &view.revisions, len(state.history), func(row ui.ListRow) {
			a.drawVcsRevisionRow(row, &state.history[row.Index], row.Index == state.revision)
		}).Label(i18n.Shared(lang, "native.history")).Grow(1).FillWidth()
		if view.revisions.Changed() {
			if index := view.revisions.Selected(); index >= 0 && index < len(state.history) {
				c.After(func() { state.revision = index })
			}
		}
		if state.cursor != nil || state.historyFailure != "" {
			ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).PadY(4).Children(func() {
				if ui.Button(c, i18n.Shared(lang, "native.loadMore")).Outline().Small().Disabled(state.historyLoading || state.cursor == nil).Clicked() {
					c.After(func() {
						a.performed("vcs.history.loadMore", surfaceButton)
						a.loadVcsHistory(p, t, true)
					})
				}
				if state.historyFailure != "" {
					ui.Text(c, state.historyFailure).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis().Grow(1)
				}
			})
		}
	})
	ui.Splitter(c, &view.split).Mins(vcsListMin, vcsListMin).Label(a.text.Panel.Resize)
	ui.Scroll(c.Part("vcs-revision")).Grow(1).FillWidth().Children(func() {
		if state.revision < 0 || state.revision >= len(state.history) {
			return
		}
		entry := &state.history[state.revision]
		ui.Column(c).FillWidth().Pad(8).Gap(4).Children(func() {
			ui.Wrap(c, entry.Message).Color(a.colors.Text)
			for index := range entry.Changes {
				change := &entry.Changes[index]
				ui.Row(c.Key(change.Path)).FillWidth().Items(ui.Center).Gap(6).Children(func() {
					ui.Text(c, vcsStatusLetter(change.Status)).Color(a.vcsStatusColor(change)).Shrink(0)
					ui.Text(c, change.Path).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
					if detail := a.vcsChangeDetail(change); detail != "" {
						ui.Text(c, detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
					}
				})
			}
			if entry.ChangesTruncated {
				ui.Text(c, i18n.Shared(lang, "native.thereAreTooManyChangesToListSomeAreNotShown")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
			}
		})
	})
}

// drawVcsRevisionRow declares the row of one revision: its name, the first line of its message,
// its author and its local date.
func (a *App) drawVcsRevisionRow(row ui.ListRow, entry *core.VcsHistoryEntry, selected bool) {
	box := row.Element.Height(logItemHeight).Items(ui.Center).Gap(6).PadX(8).Radius(a.theme.Metrics.RadiusItem())
	if selected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	summary, _, _ := strings.Cut(entry.Message, "\n")
	box.Children(func() {
		ui.Text(row.C, entry.Revision.Label()).Weight(gfx.WeightMedium).Color(a.colors.Text).Shrink(0)
		ui.Text(row.C, summary).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		ui.Spacer(row.C)
		if entry.Author != nil {
			ui.Text(row.C, *entry.Author).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MaxWidth(160)
		}
		if entry.Date != nil {
			ui.Text(row.C, vcsDate(*entry.Date)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		}
	})
}

// vcsDate is a revision's date in local time, or as the provider wrote it when it is not a
// timestamp of the contract.
func vcsDate(date string) string {
	if at, err := time.Parse(time.RFC3339, date); err == nil {
		return at.Local().Format(logDateFormat)
	}
	return date
}

// drawVcsRollbackDialog declares the dialog that confirms discarding the local edits of the
// paths it names, which cannot be undone.
func (a *App) drawVcsRollbackDialog(c ui.C, p *project, t vcsTarget) {
	lang, view := a.language(), t.view
	paths := view.rollback
	open, confirmed := true, false
	spec := ui.ModalSpec{Width: 440, Description: i18n.Shared(lang, "native.localEditsToTheseFilesAreLost")}
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "native.rollBackTheSelectedChanges"), spec, func() {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			for index, path := range paths {
				if index == vcsRollbackShown {
					ui.Text(c, i18n.SharedFormat(lang, "native.arg1FilesSelected", map[string]string{"arg1": strconv.Itoa(len(paths))})).Muted()
					break
				}
				ui.Text(c.Key(path), path).Color(a.colors.Text).Ellipsis()
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.gitReview.cancel")).Outline().Clicked() {
			open = false
		}
		if ui.Button(c, i18n.Shared(lang, "native.rollBack")).Destructive().Disabled(view.busy != "").Clicked() {
			confirmed = true
		}
	})
	switch {
	case confirmed && view.busy == "":
		c.After(func() {
			view.rollback = nil
			a.rollbackVcs(p, t, paths)
		})
	case closed || !open:
		c.After(func() { view.rollback = nil })
	}
}
