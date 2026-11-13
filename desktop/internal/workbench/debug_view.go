package workbench

import (
	"sort"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	debugRowHeight = 24
	// debugDisabledOpacity is the opacity of a disabled breakpoint's row, the fade the earlier
	// client gave it.
	debugDisabledOpacity = 0.55
	// debugAdapterPickerWidth fits an adapter's display name such as "Go (Delve)" without
	// taking the toolbar's free space.
	debugAdapterPickerWidth = 160
	// debugGutterDot is the side of an instruction breakpoint's dot, the editor gutter's
	// breakpoint size; debugGutterRing is the outline of a muted one and debugGutterHintAlpha
	// how strongly the dot a click would set shows under the pointer.
	debugGutterDot       = 12
	debugGutterRing      = 1.5
	debugGutterHintAlpha = 0.35
)

// debugView declares the Debug tool window the way IntelliJ IDEA lays it out: one row of icon
// actions for the session that ends with the adapter picker, the session picker, then the
// tabs of the shown session (see debugSections): its threads and variables, its console, and
// the disassembly and memory where the adapter serves them.
func (a *App) debugView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	if !d.loaded && !d.loading {
		a.loadDebugAdapters(p)
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.debugToolbar(c, p)
		ui.Divider(c)
		if len(d.sessions) > 1 {
			a.debugSessionRow(c, p)
		}
		if d.activeSession() == nil && len(d.adapters) > 0 && debugAttachOnly(d.adapters[d.selectedAdapter]) {
			a.debugAttachForm(c)
		}
		a.debugRemotePrompt(c, p)
		// The breakpoint editor is declared after the breakpoints dialog it opens from, so it
		// stacks above that dialog.
		a.debugBreakpointsDialog(c, p)
		a.debugBreakpointEditor(c, p)
		if d.failure != "" {
			ui.Column(c).FillWidth().Shrink(0).PadX(shellContentPad).PadY(6).Children(func() {
				ui.Paragraph(c, d.failure, 3).Color(a.theme.Danger)
			})
		}
		if len(d.adapters) == 0 && !d.loading {
			a.panelMessage(c, t.NoAdapters, a.colors.Subtle)
			return
		}
		a.debugSections(c, p)
	})
}

// debugToolbar declares the Debug window's actions as IntelliJ IDEA groups them: rerun and
// stop the session; resume, pause and the steps of the paused thread; the breakpoints dialog
// and the switch that mutes every breakpoint; then the More menu. Start stands in for Stop
// while no session runs. Each icon names its action when the pointer rests on it. The status
// of the shown session and the compact adapter picker close the row.
func (a *App) debugToolbar(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	lang := a.language()
	session := d.activeSession()
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(2).PadX(6).Children(func() {
		if _, clicked := a.toolIconButton(c.Part("rerun"), i18n.Shared(lang, "native.rerun"), icons.RotateCcw, false, d.rerun == nil || d.preparing); clicked {
			c.After(func() { a.rerunDebug(p) })
		}
		if session == nil {
			if _, clicked := a.toolIconButton(c.Part("start"), t.Start, icons.Bug, false, len(d.adapters) == 0 || d.preparing); clicked {
				c.After(func() { a.startDebug(p) })
			}
		} else if _, clicked := a.toolIconButton(c.Part("stop"), t.Stop, icons.Square, false, false); clicked {
			c.After(func() { a.stopDebugByUser(p) })
		}
		a.debugToolbarDivider(c)
		paused := session != nil && d.state == "paused"
		if _, clicked := a.toolIconButton(c.Part("continue"), t.Continue, icons.Play, false, !paused); clicked {
			c.After(func() { a.continueDebug(p) })
		}
		if _, clicked := a.toolIconButton(c.Part("pause"), t.Pause, icons.Pause, false, session == nil || d.state != "running"); clicked {
			c.After(func() { a.pauseDebug(p) })
		}
		// Steps need a stopped debuggee and a stopped thread to step; the adapter decides
		// which commands it serves and Core rejects the rest with a visible failure.
		stepDisabled := !paused || (d.pausedThread != nil && d.resumedThreads[*d.pausedThread])
		granularity := debugStepGranularity(d)
		if _, clicked := a.toolIconButton(c.Part("step-over"), t.StepOver, icons.RedoDot, false, stepDisabled); clicked {
			c.After(func() { a.executeDebugWithGranularity(p, "next", granularity) })
		}
		if _, clicked := a.toolIconButton(c.Part("step-into"), t.StepInto, icons.ArrowDownToDot, false, stepDisabled); clicked {
			c.After(func() { a.executeDebugWithGranularity(p, "stepIn", granularity) })
		}
		if _, clicked := a.toolIconButton(c.Part("step-out"), t.StepOut, icons.ArrowUpFromDot, false, stepDisabled); clicked {
			c.After(func() { a.executeDebugWithGranularity(p, "stepOut", granularity) })
		}
		a.debugToolbarDivider(c)
		if _, clicked := a.toolIconButton(c.Part("view-breakpoints"), i18n.Shared(lang, "native.viewBreakpoints"), icons.CircleDot, p.panels.breakpointsOpen, false); clicked {
			c.After(func() {
				a.performed("debug.viewBreakpoints", surfaceButton)
				p.panels.breakpointsOpen = true
			})
		}
		mute := i18n.Shared(lang, "native.muteBreakpoints")
		if d.muted {
			mute = i18n.Shared(lang, "desktop.debug.unmuteBreakpoints")
		}
		if _, clicked := a.toolIconButton(c.Part("mute"), mute, icons.CircleSlash, d.muted, false); clicked {
			c.After(func() { a.toggleMuteBreakpoints(p) })
		}
		more, clicked := a.toolIconButton(c.Part("more"), i18n.Shared(lang, "native.moreActions"), icons.EllipsisVertical, p.panels.debugMoreOpen, false)
		if clicked {
			c.After(func() { p.panels.debugMoreOpen = !p.panels.debugMoreOpen })
		}
		if p.panels.debugMoreOpen {
			a.debugMoreMenu(c, more, p)
		}
		ui.Spacer(c)
		if d.status != "" {
			status := d.status
			// The picker names the session's adapter while it shows that adapter; a child
			// session, or a session whose adapter the user switched away from, is named here.
			if session != nil && !d.pickerShows(session) {
				status = a.debugSessionLabel(session) + " · " + status
			}
			ui.Text(c, status).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		}
		a.debugAdapterPicker(c.Part("adapter"), p)
	})
}

// pickerShows reports whether the toolbar's adapter picker shows the adapter session runs: a
// session the user started from it, not one another session started.
func (d *debugState) pickerShows(session *debugSession) bool {
	if session.parent != nil || len(d.adapters) == 0 {
		return false
	}
	picked := d.adapters[d.selectedAdapter]
	return picked.PluginID == session.adapter.PluginID && picked.Declaration.ID == session.adapter.Declaration.ID
}

// debugStepGranularity is the unit the toolbar's steps take: one instruction while the
// Disassembly tab is shown and the adapter accepts a granularity, as IntelliJ IDEA steps in its
// disassembly view, and the adapter's own unit otherwise. Core forwards the granularity only
// when the adapter advertised it.
func debugStepGranularity(d *debugState) string {
	if d.section == debugSectionDisassembly && d.capabilities != nil && d.capabilities.SupportsSteppingGranularity {
		return "instruction"
	}
	return ""
}

// debugToolbarDivider is the thin rule between two groups of the toolbar's actions.
func (a *App) debugToolbarDivider(c ui.C) {
	ui.Row(c).Height(16).Shrink(0).PadX(4).Children(func() {
		ui.Column(c).Width(1).FillHeight().Background(a.colors.Line)
	})
}

// debugMoreMenu declares the Debug toolbar's More menu: how the variables are shown, whether
// the stack folds the frames the stepping filters match, and, while the Disassembly tab is
// shown, the way back to the current instruction.
func (a *App) debugMoreMenu(c ui.C, anchor ui.Box, p *project) {
	t, d := a.text.Debug, &p.debug
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		if menu.Item(t.ViewTree).Chosen(!d.vars.json).Clicked() {
			c.After(func() { d.vars.json = false })
		}
		if menu.Item(t.ViewJSON).Chosen(d.vars.json).Clicked() {
			c.After(func() { d.vars.json = true })
		}
		menu.Separator()
		if menu.Item(i18n.Shared(a.language(), "native.collapseFilteredFrames")).Checked(d.hideFiltered).Clicked() {
			c.After(func() {
				a.performed("debug.collapseFilteredFrames", surfaceMenu)
				d.hideFiltered, d.framesExpanded = !d.hideFiltered, false
			})
		}
		if d.section == debugSectionDisassembly {
			menu.Separator()
			if menu.Item(t.Reload).Disabled(!canDisassemble(d) || d.disassembly.loading).Clicked() {
				c.After(func() {
					a.performed("debug.disassembly.currentInstruction", surfaceMenu)
					a.loadDisassembly(p)
				})
			}
		}
	})
	if !open {
		p.panels.debugMoreOpen = false
	}
}

// debugAdapterPicker declares the compact adapter picker at the end of the toolbar. It stays
// switchable while a session runs, as IntelliJ IDEA's run configuration does: a running
// session keeps its adapter, and the choice is the one Start and the next session use.
func (a *App) debugAdapterPicker(c ui.C, p *project) {
	d := &p.debug
	if len(d.adapters) == 0 {
		return
	}
	indexes := make([]int, len(d.adapters))
	for index := range indexes {
		indexes[index] = index
	}
	ui.Select(c, &d.selectedAdapter, indexes, func(index int) string {
		return d.adapters[index].Declaration.DisplayName
	}).Label(i18n.Shared(a.language(), "desktop.debug.adapter")).Width(debugAdapterPickerWidth).Height(24).Shrink(1)
}

// debugAttachOnly is true for an adapter that has no launch: the target is a
// running debuggee whose host and port the user names.
func debugAttachOnly(adapter debugAdapter) bool {
	return !adapter.Declaration.Serves("launch") && adapter.Declaration.AcceptsConnection
}

// debugAttachForm declares the host and port of the debuggee to attach to. An
// empty host means this machine.
func (a *App) debugAttachForm(c ui.C) {
	t := a.text.Debug
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.TextField(c, &a.debugAttach.host, t.AttachHost, t.AttachHost).Grow(2)
		ui.TextField(c, &a.debugAttach.port, t.AttachPort, t.AttachPort).Grow(1)
	})
}

// debugRemotePrompt asks before attaching to an endpoint Core could not prove
// local. The answer is for this start only; closing the dialog is a refusal.
func (a *App) debugRemotePrompt(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	open := &p.panels.remoteOpen
	*open = d.remote != nil
	if !*open {
		return
	}
	endpoint := d.remote.endpoint
	closed := ui.Modal(c, open, t.RemoteTitle, func() {
		ui.Paragraph(c, t.RemotePrompt(endpoint), 4).Color(a.colors.Warning)
	}, func() {
		if ui.Button(c, t.RemoteCancel).Outline().Clicked() {
			*open = false
		}
		if ui.Button(c, t.RemoteAttach).Clicked() {
			c.After(func() { a.confirmRemoteDebug(p) })
		}
	})
	if closed || !*open {
		d.remote = nil
	}
}

// debugBreakpointRow is one stored breakpoint line.
type debugBreakpointRow struct {
	path       string
	breakpoint debugBreakpoint
}

// debugBreakpointList lists the stored breakpoints by file and line.
func debugBreakpointList(d *debugState) []debugBreakpointRow {
	paths := make([]string, 0, len(d.breakpoints))
	for path := range d.breakpoints {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	var rows []debugBreakpointRow
	for _, path := range paths {
		for _, breakpoint := range d.breakpoints[path] {
			rows = append(rows, debugBreakpointRow{path: path, breakpoint: breakpoint})
		}
	}
	return rows
}

// debugBreakpointsHeight is the height of the breakpoints dialog's list of lines.
const debugBreakpointsHeight = 220

// debugBreakpointsDialog declares the dialog the toolbar's View Breakpoints opens, IntelliJ
// IDEA's Breakpoints dialog: the action that toggles a breakpoint on the caret's line, the
// method breakpoints, the line breakpoints and the exception filters the adapter offers.
func (a *App) debugBreakpointsDialog(c ui.C, p *project) {
	open := &p.panels.breakpointsOpen
	if !*open {
		return
	}
	t := a.text.Debug
	k := c.Part("breakpoints-dialog")
	closed := ui.ModalWith(k, open, t.Breakpoints, ui.ModalSpec{Width: 560}, func() {
		ui.Column(k).FillWidth().Gap(6).Children(func() {
			a.debugBreakpoints(k, p)
			a.debugExceptionsView(k, p)
		})
	}, func() {
		if ui.Button(k, i18n.Shared(a.language(), "ui.done")).Clicked() {
			*open = false
		}
	})
	if closed {
		*open = false
	}
}

// debugBreakpoints declares the toggle action and the stored breakpoints: the method names,
// then the lines. A line row removes that breakpoint when clicked.
func (a *App) debugBreakpoints(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).Children(func() {
		ui.Text(c, i18n.Shared(a.language(), "native.lineBreakpoints")).Color(a.colors.Text).Weight(gfx.WeightMedium).Shrink(0)
		ui.Spacer(c)
		if ui.Button(c, t.ToggleBreakpoint).Outline().Clicked() {
			c.After(func() { a.toggleBreakpoint(p) })
		}
	})
	rows := debugBreakpointList(d)
	ui.Column(c).FillWidth().Height(debugBreakpointsHeight).Shrink(0).Border(1, a.colors.Line).Clip().Children(func() {
		if len(rows) == 0 {
			a.panelMessage(c, t.NoBreakpoints, a.colors.Subtle)
			return
		}
		list := &p.panels.breakpoints
		list.Label = func(i int) string {
			return debugFileName(rows[i].path) + ":" + strconv.FormatInt(rows[i].breakpoint.line, 10)
		}
		ui.List(c, list, len(rows), func(row ui.ListRow) {
			spec := rows[row.Index]
			row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(6).Tooltip(t.RemoveBreakpoint).
				Hover(ui.Look{}.Background(a.colors.Hover))
			// A disabled breakpoint is shown faded, as the earlier client's list showed it, and
			// so is every breakpoint while they are muted.
			if spec.breakpoint.disabled || d.muted {
				row.Element.Opacity(debugDisabledOpacity)
			}
			ui.Icon(row.C, icons.CircleX).Size(12, 12).Shrink(0).Color(a.theme.Danger)
			ui.Text(row.C, debugFileName(spec.path)).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
			ui.Text(row.C, ":"+strconv.FormatInt(spec.breakpoint.line, 10)).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
			if marker := breakpointMarker(spec.breakpoint, t.Breakpoint.Conditional, t.Breakpoint.LogPoint); marker != "" {
				ui.Text(row.C, marker).Shrink(0).FontSize(11.5).Color(a.colors.Accent).Ellipsis()
			}
			a.debugBreakpointMenu(row.C, row.Element, p, spec.path, spec.breakpoint.line, spec.breakpoint.disabled)
			if row.Element.Clicked() {
				row.C.After(func() { a.removeBreakpoint(p, spec.path, spec.breakpoint.line) })
			}
		}).Label(t.Breakpoints).Fill()
	})
	ui.Text(c, t.Breakpoint.FunctionName).Color(a.colors.Text).Weight(gfx.WeightMedium)
	a.debugFunctionBreakpoints(c, p)
}

// removeBreakpoint drops one stored line and tells the active adapter.
func (a *App) removeBreakpoint(p *project, path string, line int64) {
	lines := p.debug.breakpoints[path]
	index, found := breakpointIndex(lines, line)
	if !found {
		return
	}
	lines = append(lines[:index], lines[index+1:]...)
	if len(lines) == 0 {
		delete(p.debug.breakpoints, path)
	} else {
		p.debug.breakpoints[path] = lines
	}
	if p.debug.activeSession() != nil {
		a.sendDebugBreakpoints(p, path)
	}
}

// debugFrames declares the left pane of Threads & Variables: the thread picker and the paused
// thread's call stack, each frame written "name (file:line)" as IntelliJ IDEA writes it and
// faded when the stepping filters match it. A click selects the frame and opens its source.
func (a *App) debugFrames(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	a.debugThreadPicker(c, p)
	if len(d.frames) == 0 {
		message := i18n.Shared(a.language(), "debugger.stackEmpty")
		if d.activeSession() != nil {
			message = t.NoFrames
		}
		a.panelMessage(c, message, a.colors.Subtle)
		return
	}
	list := &p.panels.frames
	rows := debugFrameRows(d.frameRows[:0], d.frames, d.hideFiltered && !d.framesExpanded, d.vars.frame)
	d.frameRows = rows
	language := a.language()
	hiddenLabel := func(n int) string {
		return i18n.SharedFormat(language, "desktop.debug.filteredFrames", map[string]string{"count": strconv.Itoa(n)})
	}
	list.Label = func(i int) string {
		if r := rows[i]; r.hidden > 0 {
			return hiddenLabel(r.hidden)
		}
		return d.frames[rows[i].frame].Name
	}
	ui.List(c, list, len(rows), func(row ui.ListRow) {
		r := rows[row.Index]
		element := row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(4).Hover(ui.Look{}.Background(a.colors.Hover))
		if r.hidden > 0 {
			// A run of frames the stepping filters match: a click shows them all again.
			ui.Text(row.C, hiddenLabel(r.hidden)).Grow(1).Shrink(1).FontSize(12).Color(a.colors.Subtle).Ellipsis()
			if element.Clicked() {
				row.C.After(func() { p.debug.framesExpanded = true })
			}
			return
		}
		frame := d.frames[r.frame]
		index := r.frame
		if index == d.vars.frame {
			element.Background(a.colors.Active)
		}
		color, place := a.colors.Text, a.colors.Subtle
		if frame.IsFiltered {
			color = a.colors.Subtle
		}
		ui.Text(row.C, frame.Name).Shrink(1).FontSize(12.5).Color(color).Ellipsis()
		if frame.SourcePath != "" {
			position := "(" + debugFileName(frame.SourcePath) + ":" + strconv.FormatInt(frame.Line, 10) + ")"
			ui.Text(row.C, position).Shrink(0).FontSize(12.5).Color(place)
		}
		ui.Spacer(row.C)
		a.debugFrameMenu(row.C, element, p, index)
		if element.Clicked() && index != d.vars.frame {
			// The selected frame decides which scopes and variables are shown.
			row.C.After(func() { a.selectDebugFrame(p, index) })
		}
		if frame.SourcePath == "" {
			return
		}
		element.Tooltip(t.OpenFrame)
		if element.Clicked() {
			line := int(frame.Line)
			if line > 0 {
				line--
			}
			row.C.After(func() { a.openFileAtPosition(p, frame.SourcePath, line, 0) })
		}
	}).Label(t.Frames).Fill()
}

// debugConsole declares the Console tab: the output the adapter reported for the session, in
// a list that follows new lines while it shows its end.
func (a *App) debugConsole(c ui.C, p *project) {
	d, panels := &p.debug, &p.panels
	if len(d.output) == 0 {
		a.panelMessage(c, i18n.Shared(a.language(), "desktop.debug.consoleEmpty"), a.colors.Subtle)
		return
	}
	list := &panels.console
	if panels.consoleSeen != d.outputCount {
		if panels.consoleSeen == 0 || list.AtEnd() {
			list.ScrollToEnd()
		}
		panels.consoleSeen = d.outputCount
	}
	lines := d.output
	list.Label = func(i int) string { return lines[i] }
	ui.List(c, list, len(lines), func(row ui.ListRow) {
		row.Element.Height(debugRowHeight - 4).PadX(10).Items(ui.Center)
		ui.Text(row.C, lines[row.Index]).FontSize(12.5).Color(a.colors.Text).Mono()
	}).Label(i18n.Shared(a.language(), "debugger.console")).Fill()
}
