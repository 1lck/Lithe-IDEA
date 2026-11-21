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
	// toolbars' icons.
	runTreeIcon = 16
	runToolIcon = 16
)

// runView declares the Run tool window as IntelliJ IDEA lays it out. Its header holds a tab per
// execution (runSessionTabs); the body shows the selected one: rerun and stop on the left, the
// execution's tree with how it stands and how long it took, and its console in the colors it
// printed, with the console's own actions on its right.
func (a *App) runView(c ui.C, p *project) {
	run := p.activeRun()
	body := ui.Column(c).Fill().Background(a.colors.Editor)
	if run == nil {
		body.Children(func() { a.panelMessage(c, a.text.Run.Empty, a.colors.Subtle) })
		return
	}
	body.Children(func() {
		ui.Row(c).Fill().Clip().Children(func() {
			a.runToolbar(c, p, run)
			ui.Divider(c)
			a.runPanes(c.Key(run.id), p, run)
		})
	})
}

// runSessionTabs declares the header's tab of every execution the Run window keeps, oldest
// first, as IntelliJ IDEA names each: its status icon and name, and, once it ended, the × that
// closes it. A click selects one. The row takes the room a spacer would, and its tabs cut their
// names in a narrow panel before they push the hide button out.
func (a *App) runSessionTabs(c ui.C, p *project) {
	runs, shown := p.build.runs, p.activeRun()
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Height(panelHeaderHeight).Items(ui.Center).Gap(2).Clip().Children(func() {
		for index, run := range runs {
			k := c.Key(run.id)
			on := run == shown
			tooltip := run.label
			if run.remote {
				tooltip += "\n" + i18n.Shared(a.language(), "desktop.run.remote.badgeHelp")
			}
			chip := ui.Row(k).Height(rowHeight).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).PadX(toolTabPad).
				Radius(a.theme.Metrics.RadiusItem()).
				HitWith(ui.ID(k), run.label, gfx.HitOptions{
					Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: on,
					PosInSet: int32(index + 1), SetSize: int32(len(runs)),
				}).
				Tooltip(tooltip).
				Pressed(ui.Look{}.Background(a.colors.Active))
			if on {
				chip = chip.Background(a.colors.TabIdle).Stroke(1, a.colors.TabIdleBorder).Radius(6)
			} else {
				chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
			}
			if !run.running {
				// The × sits where the padding would end the tab.
				chip = chip.PadSides(0, 2, 0, toolTabPad)
			}
			var closeButton ui.Box
			chip.Children(func() {
				a.runStatusMark(k, run, terminalChipIcon)
				text := ui.Text(k, run.label).Ellipsis().Shrink(1)
				if on {
					text.Color(a.colors.Text)
				} else {
					text.Color(a.colors.Subtle).StateFrom(chip).Hover(ui.Look{}.Color(a.colors.Text))
				}
				if run.remote {
					a.runTabBadge(k.Part("host"), i18n.Shared(a.language(), "desktop.run.remote.badge"), on)
				}
				if run.running && len(run.ports) > 0 {
					a.runTabPortBadge(k.Part("ports"), run, on)
				}
				if run.running {
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
			id := run.id
			switch {
			case !run.running && closeButton.Clicked():
				c.After(func() { p.closeRunSession(id) })
			case chip.Clicked():
				c.After(func() { p.build.view = id })
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

// runPanes declares the execution's tree beside its console, with the divider between them.
func (a *App) runPanes(c ui.C, p *project, run *runEntry) {
	split := &p.panels.runSplit
	if split.Ratio <= 0 {
		split.Ratio = runTreeRatio
	}
	var tree, console ui.Box
	ui.Row(c).Fill().Clip().Children(func() {
		tree = ui.Column(c.Part("tree")).Children(func() { a.runTree(c, p, run) })
		ui.Splitter(c, split).Mins(runTreeMinWidth, runConsoleMinWidth).Label(a.text.Panel.Resize)
		console = ui.Row(c.Part("console")).Children(func() { a.runConsole(c, p, run) })
	})
	tree.FillHeight().MinWidth(runTreeMinWidth).Shrink(1)
	console.Fill().MinWidth(runConsoleMinWidth)
}

// runTree declares the tree of the selected execution, as IDEA's Run window shows one: the
// execution, with its status icon, its name in bold, when it started and, once it ended, how long
// it took at the end of the row; under it how it ended, or the status line of the host's
// execution still going. When the row is too narrow, the start gives way before the name.
func (a *App) runTree(c ui.C, p *project, run *runEntry) {
	status := a.runStatusText(run)
	duration := ""
	if !run.running {
		duration = a.text.Run.Duration(int(run.ended.Sub(run.started).Milliseconds()))
	}
	ui.Column(c).Fill().Clip().PadY(4).Children(func() {
		k := c.Part("root")
		label := run.label + ", " + status
		if duration != "" {
			label += ", " + duration
		}
		ui.Row(k).FillWidth().Height(buildRowHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).
			HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleStatus, SkipFocus: true}).Tooltip(status).
			Children(func() {
				a.runStatusMark(k, run, runTreeIcon)
				// The start follows the name with no gap, since its words begin with the separator.
				ui.Row(k).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
					ui.Text(k, run.label).Color(a.colors.Text).Weight(gfx.WeightBold).Ellipsis().Shrink(1)
					ui.Text(k, a.text.Run.StartedAt(run.started.Format(runStartedLayout))).Color(a.colors.Subtle).
						Ellipsis().Shrink(buildDetailShrink)
				})
				ui.Spacer(k)
				if duration != "" {
					ui.Text(k, duration).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
				}
			})
		if run.running && len(run.ports) > 0 {
			a.runPortsRow(c.Part("ports"), run)
		}
		if detail := runDetail(p, run); detail != "" {
			// Indented under the root's name, past its icon and the gap after it.
			ui.Row(c).FillWidth().Height(buildRowHeight).Shrink(0).Items(ui.Center).PadSides(0, 8, 0, 8+runTreeIcon+6).Children(func() {
				ui.Text(c, detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			})
		}
	})
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

func (a *App) runPortsRow(c ui.C, run *runEntry) {
	const pillHeight = buildRowHeight - 4
	ui.Column(c).FillWidth().Shrink(0).PadSides(2, 8, 2, 8+runTreeIcon+6).Children(func() {
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
				ui.ContextMenu(pk.Part("menu"), pill, func(menu *ui.MenuItems) {
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
	k := c.Part("status")
	if run.running && run.processRunning {
		ui.Icon(k, icons.Play).Size(size, size).Shrink(0).Color(a.colors.Success)
		return
	}
	if run.running {
		ui.Spinner(k).Size(size, size).Shrink(0)
		return
	}
	icon, tint := icons.CircleCheck, a.colors.Success
	switch run.outcome {
	case runFailed:
		icon, tint = icons.CircleX, a.theme.Danger
	case runStopped:
		icon, tint = icons.CircleSlash, a.colors.Subtle
	}
	ui.Icon(k, icon).Size(size, size).Shrink(0).Color(tint)
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
		a.outputList(c, p, &run.console, outputScopeRun, a.text.Build.Output, &run.output, 0, a.runWrap, menu).Grow(1)
	})
	ui.Divider(c)
	lang := a.language()
	ui.Column(c).FillHeight().Shrink(0).Gap(2).Pad(4).Children(func() {
		empty := run.output.empty()
		if a.runToolToggle(c.Part("wrap"), i18n.Shared(lang, "git.console.wrap"), icons.WrapText, a.runWrap) {
			c.After(a.toggleRunWrap)
		}
		if a.runToolButton(c.Part("end"), i18n.Shared(lang, "git.console.scrollToEnd"), icons.ArrowDownToLine, a.colors.Text, empty) {
			c.After(func() { run.console.ScrollToEnd() })
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
