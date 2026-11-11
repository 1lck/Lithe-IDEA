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
	// debugBreakpointRows is how many breakpoint rows show before the list scrolls.
	debugBreakpointRows = 6
)

// debugView declares the Debug tool window: one adapter session, its breakpoints,
// pause/continue controls and the paused call stack.
func (a *App) debugView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	if !d.loaded && !d.loading {
		a.loadDebugAdapters(p)
	}
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.debugAdapterRow(c, p)
		if len(d.adapters) > 0 && d.session == nil && debugAttachOnly(d.adapters[d.selectedAdapter]) {
			a.debugAttachForm(c)
		}
		a.debugRemotePrompt(c, p)
		ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			if ui.Button(c, t.Start).Disabled(d.session != nil || len(d.adapters) == 0).Clicked() {
				a.startDebug(p)
			}
			if d.session != nil {
				if ui.Button(c, t.Stop).Outline().Clicked() {
					a.stopDebugByUser(p)
				}
			}
			if ui.Button(c, t.Continue).Outline().Disabled(d.session == nil || d.state != "paused").Clicked() {
				a.continueDebug(p)
			}
			if ui.Button(c, t.Pause).Outline().Disabled(d.session == nil || d.state != "running").Clicked() {
				a.pauseDebug(p)
			}
			// Steps need a stopped debuggee; the adapter decides which commands it
			// serves and Core rejects the rest with a visible failure.
			stepDisabled := d.session == nil || d.state != "paused"
			if ui.Button(c, t.StepInto).Outline().Disabled(stepDisabled).Clicked() {
				a.executeDebug(p, "stepIn")
			}
			if ui.Button(c, t.StepOver).Outline().Disabled(stepDisabled).Clicked() {
				a.executeDebug(p, "next")
			}
			if ui.Button(c, t.StepOut).Outline().Disabled(stepDisabled).Clicked() {
				a.executeDebug(p, "stepOut")
			}
			ui.Spacer(c)
			if d.status != "" {
				ui.Text(c, d.status).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
		})
		ui.Divider(c)
		if d.failure != "" {
			ui.Column(c).FillWidth().Shrink(0).PadX(shellContentPad).PadY(6).Children(func() {
				ui.Paragraph(c, d.failure, 3).Color(a.theme.Danger)
			})
		}
		if len(d.adapters) == 0 && !d.loading {
			a.panelMessage(c, t.NoAdapters, a.colors.Subtle)
			a.debugOutput(c, p)
			return
		}
		a.debugBreakpoints(c, p)
		ui.Divider(c)
		a.debugSections(c, p)
	})
}

// debugAdapterRow declares the adapter picker. While a session runs the adapter
// is fixed, so the picker gives way to its name.
func (a *App) debugAdapterRow(c ui.C, p *project) {
	d := &p.debug
	if len(d.adapters) == 0 {
		return
	}
	indexes := make([]int, len(d.adapters))
	for index := range indexes {
		indexes[index] = index
	}
	label := i18n.Shared(a.language(), "desktop.debug.adapter")
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).PadX(8).Items(ui.Center).Children(func() {
		if d.session != nil {
			ui.Text(c, d.adapters[d.selectedAdapter].Declaration.DisplayName).Color(a.colors.Text).Ellipsis().Grow(1).Label(label)
			return
		}
		ui.Select(c, &d.selectedAdapter, indexes, func(index int) string {
			return d.adapters[index].Declaration.DisplayName
		}).Label(label).Grow(1)
	})
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
	path string
	line int64
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
		for _, line := range d.breakpoints[path] {
			rows = append(rows, debugBreakpointRow{path: path, line: line})
		}
	}
	return rows
}

// debugBreakpoints declares the toggle action and the stored breakpoint lines.
// A line row removes that breakpoint when clicked.
func (a *App) debugBreakpoints(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.Text(c, t.Breakpoints).Color(a.colors.Text).Weight(gfx.WeightMedium).Shrink(0)
		ui.Spacer(c)
		if ui.Button(c, t.ToggleBreakpoint).Outline().Clicked() {
			a.toggleBreakpoint(p)
		}
	})
	rows := debugBreakpointList(d)
	if len(rows) == 0 {
		ui.Row(c).FillWidth().Height(debugRowHeight).Shrink(0).PadX(10).Items(ui.Center).Children(func() {
			ui.Text(c, t.NoBreakpoints).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		})
		return
	}
	list := &p.panels.breakpoints
	list.Label = func(i int) string { return debugFileName(rows[i].path) + ":" + strconv.FormatInt(rows[i].line, 10) }
	ui.List(c, list, len(rows), func(row ui.ListRow) {
		spec := rows[row.Index]
		row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(6).Tooltip(t.RemoveBreakpoint).
			Hover(ui.Look{}.Background(a.colors.Hover))
		ui.Icon(row.C, icons.CircleX).Size(12, 12).Shrink(0).Color(a.theme.Danger)
		ui.Text(row.C, debugFileName(spec.path)).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
		ui.Text(row.C, ":"+strconv.FormatInt(spec.line, 10)).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
		if row.Element.Clicked() {
			row.C.After(func() { a.removeBreakpoint(p, spec.path, spec.line) })
		}
	}).Label(t.Breakpoints).FillWidth().Height(float32(min(len(rows), debugBreakpointRows)) * debugRowHeight).Shrink(0)
}

// removeBreakpoint drops one stored line and tells the active adapter.
func (a *App) removeBreakpoint(p *project, path string, line int64) {
	lines := p.debug.breakpoints[path]
	index := sort.Search(len(lines), func(i int) bool { return lines[i] >= line })
	if index >= len(lines) || lines[index] != line {
		return
	}
	lines = append(lines[:index], lines[index+1:]...)
	if len(lines) == 0 {
		delete(p.debug.breakpoints, path)
	} else {
		p.debug.breakpoints[path] = lines
	}
	if p.debug.session != nil {
		a.sendDebugBreakpoints(p, path)
	}
}

// debugFrames declares the paused call stack. A frame with a source path opens
// that location.
func (a *App) debugFrames(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	a.debugThreadPicker(c, p)
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
		ui.Text(c, t.Frames).Color(a.colors.Text).Weight(gfx.WeightMedium).Ellipsis()
	})
	if len(d.frames) == 0 {
		ui.Row(c).FillWidth().Shrink(0).Height(debugRowHeight).PadX(10).Items(ui.Center).Children(func() {
			ui.Text(c, t.NoFrames).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		})
		return
	}
	list := &p.panels.frames
	list.Label = func(i int) string { return d.frames[i].Name }
	ui.List(c, list, len(d.frames), func(row ui.ListRow) {
		frame := d.frames[row.Index]
		element := row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center).Gap(6).Hover(ui.Look{}.Background(a.colors.Hover))
		ui.Text(row.C, frame.Name).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
		index := row.Index
		if element.Clicked() && index != d.vars.frame {
			// The selected frame decides which scopes and variables are shown.
			row.C.After(func() { a.selectDebugFrame(p, index) })
		}
		if frame.SourcePath == "" {
			return
		}
		element.Tooltip(t.OpenFrame)
		position := debugFileName(frame.SourcePath) + ":" + strconv.FormatInt(frame.Line, 10)
		ui.Text(row.C, position).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
		if element.Clicked() {
			line := int(frame.Line)
			if line > 0 {
				line--
			}
			row.C.After(func() { a.openFileAtPosition(p, frame.SourcePath, line, 0) })
		}
	}).Label(t.Frames).FillWidth().Grow(1)
}

// debugOutput shows the adapter's bounded diagnostics when something failed or no
// adapter was found.
func (a *App) debugOutput(c ui.C, p *project) {
	if len(p.debug.output) == 0 {
		return
	}
	lines := p.debug.output
	if len(lines) > 8 {
		lines = lines[len(lines)-8:]
	}
	ui.Divider(c)
	ui.Column(c).FillWidth().Height(120).Shrink(0).Clip().Pad(8).Children(func() {
		ui.Paragraph(c, joinLines(lines), 6).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
}

func joinLines(lines []string) string {
	text := ""
	for _, line := range lines {
		text += line + "\n"
	}
	return text
}
