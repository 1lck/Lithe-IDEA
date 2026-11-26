package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// shellMain declares the column between the stripes: the top row, which holds the editor and
// the columns of tool windows at its sides, and under it the bottom area when a bottom tool
// window is open. The columns and the panels have fixed sizes and the editor and the top
// row fill what is left; each splitter is declared right after the pane its Pos measures and
// before the next one, as Viva wants.
func (a *App) shellMain(c ui.C, plan shellPlan, open [slotCount]int, hidden *slot) {
	if a.layout.mainHook == nil {
		a.layout.mainHook = func(d *ui.DrawContext) { a.layout.mainRect = d.Rect }
	}
	ui.Column(c).Fill().Draw(a.layout.mainHook).Children(func() {
		ui.Row(c).Fill().Children(func() {
			if plan.left() {
				a.shellColumn(c, open, hidden, slotLeftTop, slotLeftBottom, shellSplitLeftColumn, plan.leftUpperH).Width(plan.leftW).Shrink(0)
				a.shellSplitter(c, shellSplitLeft).Mins(shellPanelMin, shellEditorMin)
			}
			a.editorArea(c)
			if plan.right() {
				a.shellSplitter(c, shellSplitRight).Mins(shellEditorMin, shellPanelMin)
				a.shellColumn(c, open, hidden, slotRightTop, slotRightBottom, shellSplitRightColumn, plan.rightUpperH).Width(plan.rightW).Shrink(0)
			}
		})
		if !plan.bottom() {
			return
		}
		a.shellSplitter(c, shellSplitBottom).Mins(plan.topMin, shellPanelHeightMin)
		ui.Row(c).Height(plan.bottomH).Children(func() {
			switch {
			case plan.bottomLeft && plan.bottomRight:
				a.shellPanel(c, slotBottomLeft, open[slotBottomLeft], hidden).Width(plan.bottomLeftW).Shrink(0)
				a.shellSplitter(c, shellSplitMid).Mins(shellPanelMin, shellPanelMin)
				a.shellPanel(c, slotBottomRight, open[slotBottomRight], hidden).Fill()
			case plan.bottomLeft:
				a.shellPanel(c, slotBottomLeft, open[slotBottomLeft], hidden).Fill()
			default:
				a.shellPanel(c, slotBottomRight, open[slotBottomRight], hidden).Fill()
			}
		})
	})
}

// shellColumn declares a column of tool windows beside the editor, which is the left or the
// right one depending on its slots. A column with one tool window open shows it over the
// whole height; with both open it shows the upper one (the top slot) over the lower one (the
// bottom slot), the upper one upperH high and the lower one filling, with the column's
// splitter between them. The caller gives the column its width. The splitter is declared
// right after the upper tool window, the pane its Pos measures.
func (a *App) shellColumn(c ui.C, open [slotCount]int, hidden *slot, top, bottom slot, which shellSplit, upperH float32) ui.Box {
	return ui.Column(c).Children(func() {
		switch {
		case open[top] >= 0 && open[bottom] >= 0:
			a.shellPanel(c, top, open[top], hidden).Height(upperH).Shrink(0)
			a.shellSplitter(c, which).Mins(shellPanelHeightMin, shellPanelHeightMin)
			a.shellPanel(c, bottom, open[bottom], hidden).Fill()
		case open[top] >= 0:
			a.shellPanel(c, top, open[top], hidden).Fill()
		default:
			a.shellPanel(c, bottom, open[bottom], hidden).Fill()
		}
	})
}

// shellSplitter declares one of the workbench's splitters. Its accessibility label is set
// because Viva's own is an English word that would ignore the chosen language.
func (a *App) shellSplitter(c ui.C, which shellSplit) ui.Box {
	return ui.Splitter(c, &a.layout.split[which]).Label(a.text.Panel.Resize)
}

// tooltipSide is where the full text of a value the tool window in slot s cuts short with an
// ellipsis opens: toward the editor, on the inner side of the window's edge the slot lies
// along, as the tooltips of the stripe buttons open. A path the Commit tool window cuts short
// shows in full over the editor rather than over the rows below it, and the bottom area, along
// the window's bottom edge, opens it above the text on every row instead of below it on the
// upper rows and flipping above only on the rows near the edge.
func (s slot) tooltipSide() ui.TooltipSide {
	switch s {
	case slotLeftTop, slotLeftBottom:
		return ui.TooltipRight
	case slotRightTop, slotRightBottom:
		return ui.TooltipLeft
	}
	return ui.TooltipTop
}

// shellPanel declares the tool window open in slot s, the catalog item index: a header with
// its name and a button that hides it, over a body. Most tool windows have no contents yet,
// so their body says so, in the middle. The Git tool window has more in its header, the tabs
// its views will be shown under, and a body of its own on the log tab; the Terminal tool
// window of an open project holds that project's terminals, one tab each in its header, and
// the body shows the selected one.
func (a *App) shellPanel(c ui.C, s slot, index int, hidden *slot) ui.Box {
	tool := a.chrome.catalog[index]
	p := a.project
	tabbed := tool.id == itemGit
	header := float32(toolTitleHeight)
	if tabbed || tool.id == itemTerminal || tool.id == itemCommit || tool.id == itemRun || tool.id == itemReferences || tool.id == itemProblems {
		header = panelHeaderHeight
	}
	if tool.id == itemFind && p != nil {
		header = 39
	}
	return ui.Column(c.KeyInt(int(s))).Background(a.colors.Panel).Radius(workbenchPanelRadius).Clip().
		EllipsisTooltipOn(s.tooltipSide()).Children(func() {
		// The header is a target of its own so a right-click on it offers to hide the tool
		// window, as the earlier client's tool window headers did.
		hk := c.Part("header")
		title := tool.label(a.text)
		headerRow := ui.Row(hk).FillWidth().Height(header).Shrink(0).Items(ui.Center).Gap(shellHeaderGap).PadSides(0, 8, 0, 12).
			HitWith(ui.ID(hk), i18n.Shared(a.language(), "desktop.panel.header"), gfx.HitOptions{Value: title, SkipFocus: true})
		headerRow.Children(func() {
			// The Commit tool window's first tab carries its name, so a project's Commit tool
			// window shows its tabs without the title, which would only repeat it.
			if tool.id == itemCommit && p != nil {
				a.commitTabs(c)
			} else {
				ui.Text(c, tool.label(a.text)).Color(a.colors.Text).Weight(gfx.WeightBold).Ellipsis()
			}
			if tabbed {
				a.gitTabs(c)
			}
			switch {
			case tool.id == itemTerminal && p != nil:
				// The tabs of the open project's terminals take the room a spacer would.
				a.terminalTabs(c)
			case tool.id == itemRun && p != nil:
				// So do the tabs of the Run window's executions.
				a.runSessionTabs(c, p)
			case tool.id == itemReferences && p != nil:
				// And the tab of the usages the References window shows.
				a.referencesSearchTab(c, p)
			case tool.id == itemProblems && p != nil:
				// The Problems window's File and Project tabs come before the spacer.
				a.problemsScopeTabs(c)
				ui.Spacer(c)
			default:
				ui.Spacer(c)
			}
			if tool.id == itemProject && p != nil {
				a.projectTreeActions(c, p)
			}
			if tool.id == itemStructure && p != nil {
				a.outlineActions(c, p)
			}
			if tool.id == itemBuild && p != nil {
				a.buildToolActions(c, p)
			}
			if tool.id == itemNotifications {
				a.notificationClearButton(hk)
			}
			if tool.id == itemPorts && p != nil {
				a.remotePortsActions(c, p)
			}
			if tabbed && p != nil {
				a.drawGitActions(c, p)
			}
			hide := ui.Button(c, a.text.Panel.Hide).Icon(icons.Minus).IconOnly().Ghost().Size(shellHideSize, shellHideSize).Shrink(0).
				Tooltip(a.text.Panel.Hide)
			if hide.Clicked() {
				*hidden = s
			}
		})
		ui.ContextMenu(hk, headerRow, func(menu *ui.MenuItems) {
			menu.WidthRange(180, 280)
			if menu.Item(i18n.SharedFormat(a.language(), "native.hideToolWindow", map[string]string{"arg1": title})).Clicked() {
				c.After(func() {
					a.performed("workbench.toolWindow.hide", surfaceContextMenu)
					a.hidePanel(s)
				})
			}
		})
		a.toolBody(c, tool, p)
	})
}

// remoteToolWindow reports whether the tool window id works in a remote workspace: the project
// listing, search and terminals run on the host, and so do Git's log and commit once the
// workspace is trusted (in safe mode they say so, as in a local project), and so does Run, for the
// built-in process runs; Ports exists only there.
func remoteToolWindow(id string) bool {
	switch id {
	case itemProject, itemNotifications, itemTerminal, itemFind, itemGit, itemCommit, itemRun, itemPorts:
		return true
	}
	return false
}

// toolBody declares the body of a tool window under its header: the component of the tool,
// or the placeholder of a tool that has no contents yet.
func (a *App) toolBody(c ui.C, tool item, p *project) {
	body := ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0)
	if p == nil {
		body.Children(func() { a.toolPlaceholder(c) })
		return
	}
	if p.remote != nil && !remoteToolWindow(tool.id) {
		// The tool window reads or runs the project on this computer, so it says it does not work
		// in a remote workspace yet.
		body.Children(func() { a.remoteLocalOnlyPanel(c) })
		return
	}
	body.Clip().Children(func() {
		switch tool.id {
		case itemGit:
			switch a.layout.gitTab {
			case gitTabLog:
				a.logPageView(c)
			case gitTabWorktrees:
				a.worktreePageView(c)
			default:
				a.consolePageView(c)
			}
		case itemTerminal:
			a.terminalToolBody(c, p)
		case itemCommit:
			switch a.layout.commitTab {
			case commitTabStash:
				a.stashPageView(c, p)
			case commitTabShelf:
				a.shelfPageView(c, p)
			default:
				a.commitPageView(c)
			}
		case itemProject:
			a.projectTree(c, p)
		case itemFind:
			a.searchPanel(c)
		case itemReferences:
			a.referencesPanel(c, p)
		case itemStructure:
			a.outlinePanel(c, p)
		case itemProblems:
			a.problemsPanel(c, p)
		case itemBuild:
			a.buildToolView(c, p)
		case itemOutput:
			a.pluginOutputView(c, p)
		case itemRun:
			a.runView(c, p)
		case itemTests:
			a.testsView(c, p)
		case itemDebug:
			a.debugView(c, p)
		case itemNotifications:
			a.notificationsToolBody(c.Part("notificationHistory"))
		case itemPorts:
			a.remotePortsView(c, p)
		default:
			switch {
			case tool.tool != nil && tool.tool.View != "":
				a.pluginViewBody(c, p, tool.tool)
			case tool.tool != nil && tool.tool.Web != "":
				a.pluginWebBody(c, tool, p)
			case tool.tool != nil:
				a.pluginTextBody(c, tool.tool)
			case tool.vcs != nil:
				a.vcsView(c, p, tool)
			default:
				a.toolPlaceholder(c)
			}
		}
	})
}

func (a *App) toolPlaceholder(c ui.C) {
	ui.Row(c).Fill().Items(ui.Center).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, a.text.Panel.Placeholder, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
	})
}

// toolIconButton declares an icon button of a tool window and reports a click on it. on
// shows it pressed, for the buttons that toggle a view; a disabled one is dimmed and takes no
// click. It returns the button, for a menu or a popover to hang from.
func (a *App) toolIconButton(c ui.C, label string, icon gfx.Icon, on, disabled bool) (ui.Box, bool) {
	return a.gitToolButton(c, label, icon, on, disabled)
}

// gitTabs declares the tabs of the Git tool window's header and takes a click on one as the
// new selection. The tabs may give up width, with the Log tab's branch cut, before they push
// the hide button out of a narrow panel.
func (a *App) gitTabs(c ui.C) {
	labels := [3]string{a.text.Git.Log, a.text.Git.Worktrees, a.text.Git.Console}
	if p := a.project; p != nil && p.log.reference != "" {
		labels[0] = a.text.Git.LogTab(p.log.referenceLabel)
	}
	a.toolTabs(c.Key("git-tabs"), &a.layout.gitTab, labels[:])
}

// The tabs of the Git tool window, in their order on its header.
const (
	gitTabLog = iota
	gitTabWorktrees
	gitTabConsole
)

// commitTabs declares the tabs of the Commit tool window's header: the local changes, the
// stashes and the shelves.
func (a *App) commitTabs(c ui.C) {
	lang := a.language()
	labels := [3]string{i18n.Shared(lang, "workbench.commit"), i18n.Shared(lang, "native.stash"), i18n.Shared(lang, "git.saved.tab")}
	a.toolTabs(c.Key("commit-tabs"), &a.layout.commitTab, labels[:])
}

// The tabs of the Commit tool window, in their order on its header.
const (
	commitTabChanges = iota
	commitTabStash
	commitTabShelf
)

// toolTabs declares the tabs of a tool window's header, as the macOS tool windows draw them
// and as the Terminal's tabs are drawn: each as wide as its label, the selected one on the
// active background and the others lit while the pointer is on them. selected is the index
// of the selected tab, and a click selects another. The row may shrink, the labels cut, in a
// narrow panel.
func (a *App) toolTabs(c ui.C, selected *int, labels []string) {
	a.toolTabsWith(c, *selected, labels, func(index int) { *selected = index })
}

// toolTabsWith is toolTabs for a selection the caller keeps its own way: selected is the
// index of the selected tab, and choose takes the index of a clicked one after the frame.
func (a *App) toolTabsWith(c ui.C, selected int, labels []string, choose func(int)) {
	ui.Row(c).Shrink(1).MinWidth(0).Height(panelHeaderHeight).Items(ui.Center).Gap(2).Clip().Children(func() {
		for i, label := range labels {
			k := c.KeyInt(i)
			on := i == selected
			chip := ui.Row(k).Height(rowHeight).Shrink(1).MinWidth(0).Items(ui.Center).PadX(toolTabPad).
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(ui.ID(k), label, gfx.HitOptions{
					Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: on,
					PosInSet: int32(i + 1), SetSize: int32(len(labels)),
				}).
				Pressed(ui.Look{}.Background(a.colors.Active))
			if on {
				chip = chip.Background(a.colors.TabIdle).Stroke(1, a.colors.TabIdleBorder).Radius(6)
			} else {
				chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
			}
			chip.Children(func() {
				text := ui.Text(c, label).Ellipsis().Shrink(1)
				if on {
					text.Color(a.colors.Text)
				} else {
					text.Color(a.colors.Subtle).StateFrom(chip).Hover(ui.Look{}.Color(a.colors.Text))
				}
			})
			if chip.Clicked() {
				index := i
				c.After(func() { choose(index) })
			}
		}
	})
}

// emptyEditorHint is a command an empty editor shows with its shortcuts.
type emptyEditorHint struct {
	label string
	// command is the keymap command whose fixed gesture and bindings are shown.
	command string
}

// editorArea declares the editor area. Once a terminal has been dragged into it, or a file
// opened, it is the groups of tabs those are in (see editorGroups). Until then there is no
// editor, so it shows what an empty one shows: the commands that open something and where to
// drop files, which is also where a dragged tab opens the first group. The shortcuts are key
// symbols, not words, and so are not translated. They come from the keymap, so each platform
// shows its own defaults and a user's changes, the same as the menus.
func (a *App) editorArea(c ui.C) {
	if a.editorGroups(c) {
		return
	}
	if a.documentOnly {
		ui.Column(c).Fill().Center().Background(a.colors.Editor).Children(func() {
			ui.Text(c, i18n.Shared(a.language(), "desktop.singleFile.help")).Color(a.colors.Subtle)
			if ui.Button(c, i18n.Shared(a.language(), "desktop.singleFile.openFile")).Outline().Clicked() {
				c.After(a.chooseStandaloneFile)
			}
		})
		return
	}
	hints := [...]emptyEditorHint{
		{a.text.Editor.SearchEverywhere, "search.everywhere"},
		{a.text.Editor.FindInFiles, "search.files"},
	}
	if p := a.project; p != nil && p.remote != nil {
		// The notice that says what works in a remote workspace, or that it is in safe mode, stands
		// over its empty editor.
		ui.Column(c.Part("remote")).Fill().Children(func() {
			a.safeModeNotice(c.Part("safeMode"), p)
			a.emptyEditorHints(c, hints[:])
		})
		return
	}
	a.emptyEditorHints(c, hints[:])
}

// emptyEditorHints declares an empty editor: the commands that find something to open, with
// their shortcuts.
func (a *App) emptyEditorHints(c ui.C, hints []emptyEditorHint) {
	editor := ui.Column(c).Fill().Clip().Center().Pad(shellContentPad).Background(a.colors.Editor).Radius(workbenchPanelRadius).Children(func() {
		ui.Column(c).FillWidth().MaxWidth(shellHintWidth).Children(func() {
			// Labels end and shortcuts start at one line down the middle, so the two read as
			// columns however long the words are.
			for _, hint := range hints {
				keys := a.settings.Keymap.Label(hint.command)
				// The gesture, which the keymap does not bind, comes before the bindings.
				if action, ok := shortcuts.Find(hint.command); ok && action.Gesture != "" {
					keys = action.Gesture + "  " + keys
				}
				ui.Row(c).Height(rowHeight).Items(ui.Center).Gap(12).Children(func() {
					ui.Text(c, hint.label).Color(a.colors.Subtle).TextEnd().Ellipsis().FillWidth()
					ui.Text(c, keys).Color(a.colors.Text).FillWidth()
				})
			}
		})
	})
	a.term.emptyHook(editor)
}
