package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// runTreeRatio is the share of the Run window's body the execution tree takes until the
	// divider is dragged; runTreeMinWidth and runConsoleMinWidth keep both panes usable.
	runTreeRatio       = 0.32
	runTreeMinWidth    = 180
	runConsoleMinWidth = 240
	// runStartedLayout is how the tree writes when an execution started, as IntelliJ IDEA's
	// Run window does; the words around it are translated (RunMessages.StartedAt).
	runStartedLayout = "2006/01/02 15:04"
	// runTreeIcon is the side of the status icon in the tree, runToolIcon that of the
	// toolbars' icons, and runTreeChevron the width of the disclosure toggle slot.
	runTreeIcon    = 16
	runToolIcon    = 16
	runTreeChevron = 16
)

// runView declares the Run tool window as IntelliJ IDEA lays it out. Its header holds one tab
// per plugin group or standalone/detached execution (runSessionTabs); the body shows the active
// tab's execution tree beside the selected execution's console, with rerun and stop on the left
// and the console's own actions on its right.
func (a *App) runView(c ui.C, p *project) {
	tab, run, ok := p.activeRunTab()
	body := ui.Column(c).Fill().Background(a.colors.Editor)
	if !ok || run == nil {
		body.Children(func() { a.panelMessage(c, a.text.Run.Empty, a.colors.Subtle) })
		return
	}
	body.Children(func() {
		ui.Row(c).Fill().Clip().Children(func() {
			a.runToolbar(c, p, run)
			ui.Divider(c)
			a.runPanes(c.Key(tab.key), p, tab, run)
		})
	})
}

// runSessionTabs declares the header's tabs: one aggregated tab per plugin group and one tab per
// standalone or user-detached execution, oldest first. A click selects the tab; a finished tab's
// × closes its sessions; tabs can be dragged to reorder or merge back into their plugin group.
func (a *App) runSessionTabs(c ui.C, p *project) {
	tabs, shown := p.runTabs(), p.activeRun()
	places := &a.dnd.runPlaces
	places.beginTabs()
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Height(panelHeaderHeight).Items(ui.Center).Gap(2).Clip().
		Draw(func(d *ui.DrawContext) {
			places.tabBar = d.Rect
		}).
		Children(func() {
			for index, tab := range tabs {
				tab := tab
				k := c.Key(tab.key)
				on := shown != nil && tab.contains(shown.id)
				running := tab.anyRunning()
				remote := tab.anyRemote()
				portRun := tab.firstRunningWithPorts()
				tooltip := tab.label
				if remote {
					tooltip += "\n" + i18n.Shared(a.language(), "desktop.run.remote.badgeHelp")
				}
				chipID := ui.ID(k)
				firstID := ""
				if len(tab.entries) > 0 {
					firstID = tab.entries[0].id
				}
				places.recordSource(chipID, runDragSource{
					isTreeRow: false,
					sessionID: firstID,
					tabKey:    tab.key,
					groupID:   tab.groupID,
					detached:  tab.detached,
					label:     tab.label,
				})
				placeIdx := places.addTab(runTabPlace{
					key:            tab.key,
					groupID:        tab.groupID,
					detached:       tab.detached,
					firstSessionID: firstID,
				})
				chip := ui.Row(k).Height(rowHeight).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).PadX(toolTabPad).
					Radius(a.theme.Metrics.RadiusItem()).
					HitWith(chipID, tab.label, gfx.HitOptions{
						Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: on,
						PosInSet: int32(index + 1), SetSize: int32(len(tabs)),
					}).
					Tooltip(tooltip).
					Pressed(ui.Look{}.Background(a.colors.Active)).
					DragSource(&a.dnd.run).
					Draw(func(d *ui.DrawContext) {
						if placeIdx < len(places.tabs) {
							places.tabs[placeIdx].rect = d.Rect
						}
					})
				if a.dnd.run.Dragging() && a.dnd.run.Source() == chipID {
					chip = chip.Opacity(chromeDragDim)
				}
				if on {
					chip = chip.Background(a.colors.TabIdle).Stroke(1, a.colors.TabIdleBorder).Radius(6)
				} else {
					chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
				}
				if !running {
					// The × sits where the padding would end the tab.
					chip = chip.PadSides(0, 2, 0, toolTabPad)
				}
				var closeButton ui.Box
				chip.Children(func() {
					a.runTabStatusMark(k, tab, terminalChipIcon)
					text := ui.Text(c, tab.label).Ellipsis().Shrink(1)
					if on {
						text.Color(a.colors.Text)
					} else {
						text.Color(a.colors.Subtle).StateFrom(chip).Hover(ui.Look{}.Color(a.colors.Text))
					}
					if remote {
						a.runTabBadge(k.Part("host"), i18n.Shared(a.language(), "desktop.run.remote.badge"), on)
					}
					if portRun != nil {
						a.runTabPortBadge(k.Part("ports"), portRun, on)
					}
					if running {
						return
					}
					cc := k.Part("close")
					closeButton = ui.Row(cc).Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
						Radius(a.theme.Metrics.RadiusItem()).
						HitWith(ui.ID(cc), a.text.Run.CloseSession, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
						Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
					closeButton.Children(func() {
						ui.Icon(cc, icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
							StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
					})
				})
				if tab.detached && tab.groupID != "" {
					ui.ContextMenu(k, chip, func(menu *ui.MenuItems) {
						if menu.Item(a.text.Run.MergeIntoGroup).Clicked() {
							c.After(func() { p.mergeRunSessions(firstID) })
						}
						if !running && menu.Item(a.text.Run.CloseSession).Clicked() {
							c.After(func() { p.closeRunTab(tab) })
						}
					})
				}
				switch {
				case !running && closeButton.Clicked():
					c.After(func() { p.closeRunTab(tab) })
				case chip.Clicked():
					c.After(func() { p.selectRunTab(tab) })
				}
			}
			ui.Spacer(c)
		})
}

// runToolbar declares the column of the selected execution's actions left of its tree, as IDEA
// puts them: rerun, in green, which starts an ended execution again, and stop, in red, while it
// runs. A host's execution reruns only while no other one runs, since the window runs one at a
// time; a stop asked of a host's execution already stopping forces it.
func (a *App) runToolbar(c ui.C, p *project, run *runEntry) {
	ui.Column(c).FillHeight().Shrink(0).Gap(2).Pad(4).Children(func() {
		// A task reruns only while the Build window runs no other; a run reruns at any time,
		// replacing a run of the same key (startRun).
		rerunnable := run.restart != nil && (run.operation == nil || run.operation.key != "" || p.build.operation == nil) || run.restart == nil && run.rerun != nil
		if a.runToolButton(c.Part("rerun"), a.text.Run.Rerun, icons.RotateCcw, a.colors.Success, run.running || !rerunnable) {
			c.After(func() { a.rerunRun(p, run) })
		}
		stop := a.text.Build.Stop
		if run.operation != nil && run.operation.cancelled {
			stop = i18n.Shared(a.language(), "desktop.process.forceStop")
		}
		if a.runToolButton(c.Part("stop"), stop, icons.Square, a.theme.Danger, !run.running) {
			c.After(func() { a.stopRun(p, run) })
		}
	})
}

// runToolButton declares an action of the Run window's toolbars: its icon in tint, as IDEA tints
// rerun and stop, dimmed and inert while disabled, and naming the action when the pointer rests
// on it. It reports a click. Viva's icon buttons draw their icon in the text color, so the
// toolbars draw their own.
func (a *App) runToolButton(c ui.C, label string, icon gfx.Icon, tint gfx.Color, disabled bool) bool {
	return a.runToolIcon(c, label, icon, tint, false, disabled, gfx.HitOptions{Role: gfx.RoleButton, Disabled: disabled})
}

// runToolToggle declares a switch of the Run window's toolbars, which keeps the background the
// Git console's switches take while it is on. It reports a click.
func (a *App) runToolToggle(c ui.C, label string, icon gfx.Icon, on bool) bool {
	return a.runToolIcon(c, label, icon, a.colors.Text, on, false, gfx.HitOptions{Role: gfx.RoleSwitch, Checked: on})
}

// runToolIcon declares the button runToolButton and runToolToggle share.
func (a *App) runToolIcon(c ui.C, label string, icon gfx.Icon, tint gfx.Color, on, disabled bool, options gfx.HitOptions) bool {
	if !disabled {
		options.Cursor = gfx.PointerCursorHand
	}
	button := ui.Row(c).Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), label, options).Tooltip(label)
	if on {
		button = button.Background(a.colors.Active)
	}
	if !disabled {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	}
	button.Children(func() {
		mark := ui.Icon(c, icon).Size(runToolIcon, runToolIcon)
		if disabled {
			mark.Color(a.colors.Subtle).Opacity(0.5)
		} else {
			mark.Color(tint)
		}
	})
	return !disabled && button.Clicked()
}

// runPanes declares the execution tree beside the selected execution's console, with the divider
// between them.
func (a *App) runPanes(c ui.C, p *project, tab runTab, run *runEntry) {
	split := &p.panels.runSplit
	if split.Ratio <= 0 {
		split.Ratio = runTreeRatio
	}
	var tree, console ui.Box
	ui.Row(c).Fill().Clip().Children(func() {
		tree = ui.Column(c.Part("tree")).Children(func() { a.runTree(c, p, tab, run) })
		ui.Splitter(c, split).Mins(runTreeMinWidth, runConsoleMinWidth).Label(a.text.Panel.Resize)
		console = ui.Row(c.Part("console")).Children(func() { a.runConsole(c.Key(run.id), p, run) })
	})
	tree.FillHeight().MinWidth(runTreeMinWidth).Shrink(1)
	console.Fill().MinWidth(runConsoleMinWidth)
}

// runTree declares the scrollable execution tree of the active Run tab. When a plugin group tab
// aggregates several executions, each appears as a selectable collapsible node; clicking a node
// switches the console on the right, clicking its chevron expands or collapses its detail rows,
// and dragging a grouped node up to the tab bar detaches it into its own tab.
func (a *App) runTree(c ui.C, p *project, tab runTab, shown *runEntry) {
	places := &a.dnd.runPlaces
	multi := len(tab.entries) > 1
	ui.Scroll(c.Part("scroll")).Scrollbars().Grow(1).FillWidth().PadY(4).
		Draw(func(d *ui.DrawContext) {
			places.treePane = d.Rect
		}).
		Children(func() {
			for _, entry := range tab.entries {
				a.runTreeNode(c.Key(entry.id), p, entry, entry == shown, multi)
			}
		})
}

func (a *App) runTreeNode(c ui.C, p *project, run *runEntry, selected, multi bool) {
	status := a.runStatusText(run)
	duration := ""
	if !run.running {
		duration = a.text.Run.Duration(int(run.ended.Sub(run.started).Milliseconds()))
	}
	detail := runDetail(p, run)
	hasPorts := run.running && len(run.ports) > 0
	hasChildren := detail != "" || hasPorts
	expanded := hasChildren && p.runNodeExpanded(run)

	rk := c.Part("root")
	rowID := ui.ID(rk)
	label := run.label + ", " + status
	if duration != "" {
		label += ", " + duration
	}
	draggable := run.groupID != "" && !run.detached
	if draggable {
		a.dnd.runPlaces.recordSource(rowID, runDragSource{
			isTreeRow: true,
			sessionID: run.id,
			groupID:   run.groupID,
			detached:  run.detached,
			label:     run.label,
		})
	}
	rowOpts := gfx.HitOptions{Role: gfx.RoleStatus, SkipFocus: true}
	if multi || draggable {
		rowOpts.Cursor = gfx.PointerCursorHand
		rowOpts.Selected = selected
	}
	row := ui.Row(rk).FillWidth().Height(buildRowHeight).Shrink(0).Items(ui.Center).Gap(4).PadSides(0, 6, 0, 4).
		HitWith(rowID, label, rowOpts).Tooltip(status)
	if multi && selected {
		row = row.Background(a.colors.Selection).Radius(a.theme.Metrics.RadiusItem())
	} else if multi {
		row = row.Hover(ui.Look{}.Background(a.colors.Hover)).Radius(a.theme.Metrics.RadiusItem())
	}
	if draggable {
		row = row.DragSource(&a.dnd.run)
		if a.dnd.run.Dragging() && a.dnd.run.Source() == rowID {
			row = row.Opacity(chromeDragDim)
		}
	}

	var toggleButton, closeButton ui.Box
	row.Children(func() {
		if hasChildren {
			tk := rk.Part("toggle")
			chevron := icons.ChevronRight
			toggleLabel := a.text.Run.ExpandDetails
			if expanded {
				chevron = icons.ChevronDown
				toggleLabel = a.text.Run.CollapseDetails
			}
			toggleButton = ui.Row(tk).Size(runTreeChevron, runTreeChevron).Shrink(0).Center().
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(ui.ID(tk), toggleLabel, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expanded: expanded}).
				Tooltip(toggleLabel).
				Hover(ui.Look{}.Background(a.colors.Hover)).
				Pressed(ui.Look{}.Background(a.colors.Active))
			toggleButton.Children(func() {
				ui.Icon(tk, chevron).Size(12, 12).Color(a.colors.Subtle).
					StateFrom(toggleButton).Hover(ui.Look{}.Color(a.colors.Text))
			})
		} else {
			ui.Row(rk.Part("indent")).Size(runTreeChevron, runTreeChevron).Shrink(0)
		}

		a.runStatusMark(rk, run, runTreeIcon)
		// The start follows the name with no gap, since its words begin with the separator.
		ui.Row(rk).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
			name := ui.Text(c, run.label).Color(a.colors.Text).Ellipsis().Shrink(1)
			if selected || !multi {
				name.Weight(gfx.WeightBold)
			}
			ui.Text(c, a.text.Run.StartedAt(run.started.Format(runStartedLayout))).Color(a.colors.Subtle).
				Ellipsis().Shrink(buildDetailShrink)
		})
		ui.Spacer(c)
		if duration != "" {
			ui.Text(c, duration).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		}
		if multi && !run.running {
			ck := rk.Part("close")
			closeButton = ui.Row(ck).Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(ui.ID(ck), a.text.Run.CloseSession, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
				Hover(ui.Look{}.Background(a.colors.Hover)).
				Pressed(ui.Look{}.Background(a.colors.Active))
			closeButton.Children(func() {
				ui.Icon(ck, icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
					StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
			})
		}
	})

	if draggable || (multi && !run.running) {
		ui.ContextMenu(rk, row, func(menu *ui.MenuItems) {
			if draggable && menu.Item(a.text.Run.DetachTab).Clicked() {
				c.After(func() { p.detachRunSession(run.id, -1) })
			}
			if !run.running && menu.Item(a.text.Run.CloseSession).Clicked() {
				c.After(func() { p.closeRunSession(run.id) })
			}
		})
	}

	switch {
	case hasChildren && toggleButton.Clicked():
		c.After(func() { p.toggleRunNodeExpanded(run) })
	case multi && !run.running && closeButton.Clicked():
		c.After(func() { p.closeRunSession(run.id) })
	case row.Clicked():
		if multi && !selected {
			c.After(func() { p.selectRun(run.id) })
		} else if hasChildren && !multi {
			c.After(func() { p.toggleRunNodeExpanded(run) })
		}
	}

	if !expanded {
		return
	}
	childIndent := float32(4 + runTreeChevron + 4 + runTreeIcon + 4)
	if hasPorts {
		a.runPortsRow(c.Part("ports"), run, childIndent)
	}
	if detail != "" {
		ui.Row(c.Part("detail")).FillWidth().Height(buildRowHeight).Shrink(0).Items(ui.Center).
			PadSides(0, 8, 0, childIndent).
			Children(func() {
				ui.Text(c, detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			})
	}
}

// runDetail is the line under an execution in the tree: how it ended, else, while the host's
// execution runs, the Build window's status of it, and while a model loads, the last line the
// load printed; empty for a plugin's run still going.
func runDetail(p *project, run *runEntry) string {
	if run.summary != "" {
		return run.summary
	}
	if run.sync != nil && run.running {
		return run.sync.latest
	}
	if run.operation != nil && p.build.owns(run.operation) {
		return run.operation.status
	}
	return ""
}

// runTabPortBadge declares the badge of a Run tab whose process listens: its first port, and how
// many more it has.
func (a *App) runTabPortBadge(c ui.C, run *runEntry, selected bool) {
	badge := run.ports[0].Label
	if len(run.ports) > 1 {
		badge += " " + a.text.Run.Ports.More(len(run.ports)-1)
	}
	a.runTabBadge(c, badge, selected)
}

// runTabBadge declares a small label after a Run tab's name, such as the host a remote
// workspace's program runs on or the ports it listens on.
func (a *App) runTabBadge(c ui.C, badge string, selected bool) {
	fill := a.colors.Hover
	if selected {
		fill = a.colors.Active
	}
	ui.Row(c).Shrink(0).Height(18).Items(ui.Center).PadX(5).Radius(4).
		Background(fill).Stroke(1, a.colors.TabIdleBorder).
		Children(func() {
			ui.Text(c, badge).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Accent).Shrink(0)
		})
}

func (a *App) runPortsRow(c ui.C, run *runEntry, leftIndent float32) {
	const pillHeight = buildRowHeight - 4
	ui.Column(c).FillWidth().Shrink(0).PadSides(2, 8, 2, leftIndent).Children(func() {
		ui.Flow(c).FillWidth().Gap(6).Children(func() {
			ui.Row(c.Part("label")).Height(pillHeight).Shrink(0).Items(ui.Center).Children(func() {
				ui.Text(c, a.text.Run.Ports.Label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
			})
			for index, port := range run.ports {
				port := port
				pk := c.Key("port" + strconv.Itoa(index))
				pill := ui.Row(pk).Height(pillHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).
					Radius(a.theme.Metrics.RadiusItem()).
					Background(a.colors.Hover).Stroke(1, a.colors.TabIdleBorder).
					Hover(ui.Look{}.Background(a.colors.Active)).
					Pressed(ui.Look{}.Background(a.colors.Active)).
					HitWith(ui.ID(pk), port.URL, gfx.HitOptions{Role: gfx.RoleLink, Cursor: gfx.PointerCursorHand}).
					Tooltip(port.URL)
				pill.Children(func() {
					ui.Icon(pk, icons.ExternalLink).Size(12, 12).Color(a.colors.Accent).Shrink(0)
					ui.Text(pk, port.Label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Accent).Shrink(0)
				})
				if pill.Clicked() {
					c.After(func() { a.openRunPort(port, surfaceButton) })
				}
				ui.ContextMenu(c, pill, func(menu *ui.MenuItems) {
					if menu.Item(a.text.Run.Ports.Open).Clicked() {
						c.After(func() { a.openRunPort(port, surfaceContextMenu) })
					}
					if menu.Item(a.text.Run.Ports.Copy).Clicked() {
						c.After(func() { a.copyRunPortURL(port) })
					}
				})
			}
			if run.portsTruncated {
				ui.Row(c.Part("truncated")).Height(pillHeight).Shrink(0).Items(ui.Center).Children(func() {
					ui.Text(c, "...").FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
				})
			}
		})
	})
}

// runStatusMark declares the icon of where an execution stands, size pixels square, as IDEA marks
// one: a spinner while it is being prepared or a model loads, a green run mark once its process
// runs, a green check once it succeeded, a red cross once it failed, and a grey slash once the
// user stopped it. A service runs until it is stopped, so a spinner for as long as it runs would
// never say it started.
func (a *App) runStatusMark(c ui.C, run *runEntry, size float32) {
	a.runOutcomeMark(c, run.running, run.processRunning, run.outcome, size)
}

func (a *App) runTabStatusMark(c ui.C, tab runTab, size float32) {
	running, processRunning, outcome := tab.aggregateStatus()
	a.runOutcomeMark(c, running, processRunning, outcome, size)
}

func (a *App) runOutcomeMark(c ui.C, running, processRunning bool, outcome runOutcome, size float32) {
	if running && processRunning {
		ui.Icon(c, icons.Play).Size(size, size).Shrink(0).Color(a.colors.Success)
		return
	}
	if running {
		ui.Spinner(c).Size(size, size).Shrink(0)
		return
	}
	icon, tint := icons.CircleCheck, a.colors.Success
	switch outcome {
	case runFailed:
		icon, tint = icons.CircleX, a.theme.Danger
	case runStopped:
		icon, tint = icons.CircleSlash, a.colors.Subtle
	}
	ui.Icon(c, icon).Size(size, size).Shrink(0).Color(tint)
}

// runStatusText names where an execution stands, the words its status icon stands for.
func (a *App) runStatusText(run *runEntry) string {
	t := a.text.Run
	switch {
	case run.running:
		return t.Running
	case run.outcome == runFailed:
		return t.Failed
	case run.outcome == runStopped:
		return t.Stopped
	default:
		return t.Succeeded
	}
}

// runConsole declares the selected execution's console: the CPU and memory of a plugin's run
// above its output, which shows the colors and links it printed and keeps to its end while
// lines arrive, then the console's own actions on its right: scroll to the end and clear. A
// clear drops the lines the console holds, as trimming does, so a reader of the IDE API that
// asks past them is told of the gap.
func (a *App) runConsole(c ui.C, p *project, run *runEntry) {
	ui.Column(c).Grow(1).Shrink(1).MinWidth(0).FillHeight().Clip().Children(func() {
		a.runPerformanceChart(c, run)
		if run.output.empty() {
			ui.Row(c).FillWidth().Grow(1).Items(ui.Center).PadX(shellContentPad).Children(func() {
				ui.Text(c, a.text.Build.EmptyOutput).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
			return
		}
		menu := &outputMenu{
			key: "runconsole/" + run.id,
			all: run.output.all,
			extra: func(menu *ui.MenuItems) {
				if menu.Item(a.text.Run.Snapshot.Menu).Clicked() {
					c.After(func() { a.snapshotRunOutput(p, run) })
				}
			},
		}
		a.outputListWithScroll(c, p, &run.console, outputScopeRun, a.text.Build.Output, &run.output, 0, a.runWrap, &run.scrollToEnd, menu).Grow(1)
	})
	ui.Divider(c)
	lang := a.language()
	ui.Column(c).FillHeight().Shrink(0).Gap(2).Pad(4).Children(func() {
		empty := run.output.empty()
		if a.runToolToggle(c.Part("wrap"), i18n.Shared(lang, "git.console.wrap"), icons.WrapText, a.runWrap) {
			c.After(a.toggleRunWrap)
		}
		if a.runToolButton(c.Part("end"), i18n.Shared(lang, "git.console.scrollToEnd"), icons.ArrowDownToLine, a.colors.Text, empty) {
			c.After(func() {
				run.console.ScrollToEnd()
				run.scrollToEnd = true
			})
		}
		if a.runToolButton(c.Part("clear"), i18n.Shared(lang, "git.console.clear"), icons.Trash2, a.colors.Text, empty) {
			c.After(func() { run.output.clear() })
		}
	})
}

// toggleRunWrap switches the Run window's consoles between breaking long lines and ending them in
// an ellipsis.
func (a *App) toggleRunWrap() {
	a.performed("run.console.wrap", surfaceButton)
	a.runWrap = !a.runWrap
}

// showBuildConsole brings the Run window forward, for an action of the Build window that prints
// there, on the host's execution that runs; a run a plugin starts selects its own tab when it
// starts.
func (a *App) showBuildConsole(p *project) {
	if operation := p.build.latest(); operation != nil && operation.session != nil {
		p.build.view = operation.session.id
	}
	a.openToolWindow(itemRun)
}
