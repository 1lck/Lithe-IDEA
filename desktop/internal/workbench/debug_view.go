package workbench

import (
	"sort"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	debugStartID            = tree.ID(shellPage, "debug-start")
	debugStopID             = tree.ID(shellPage, "debug-stop")
	debugContinueID         = tree.ID(shellPage, "debug-continue")
	debugPauseID            = tree.ID(shellPage, "debug-pause")
	debugToggleBreakpointID = tree.ID(shellPage, "debug-toggle-breakpoint")
	debugBreakpointsID      = tree.Sub(shellPage, tree.Name("debug-breakpoints"))
	debugFramesListID       = tree.ID(shellPage, "debug-frames-list")
	debugFrameRowsID        = tree.Sub(shellPage, tree.Name("debug-frame-rows"))
)

const (
	debugRowHeight = 24
)

// drawDebugPanel declares the Debug tool window: one stdio adapter session,
// its breakpoints, pause/continue controls and the paused call stack.
func (a *App) drawDebugPanel(f *ui.Frame, p *project) {
	if p == nil {
		return
	}
	t, d := a.text.Debug, &p.debug
	if !d.loaded && !d.loading {
		a.loadDebugAdapters(p)
	}
	f.Column().Fill().Background(a.colors.Editor).Children(func() {
		f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			if f.Button(debugStartID, t.Start).Disabled(d.session != nil || len(d.adapters) == 0).Clicked() {
				a.startDebug(p)
			}
			if d.session != nil {
				if f.Button(debugStopID, t.Stop).Outline().Clicked() {
					a.stopDebug(p)
				}
			}
			if f.Button(debugContinueID, t.Continue).Outline().Disabled(d.session == nil || d.state != "paused").Clicked() {
				a.continueDebug(p)
			}
			if f.Button(debugPauseID, t.Pause).Outline().Disabled(d.session == nil || d.state != "running").Clicked() {
				a.pauseDebug(p)
			}
			f.Spacer()
			if d.status != "" {
				f.Text(d.status).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
		})
		f.Divider()
		if d.failure != "" {
			f.Column().Shrink(0).PadX(shellContentPad).PadY(6).Children(func() {
				f.Paragraph(d.failure, 3).Color(a.theme.Danger)
			})
		}
		if len(d.adapters) == 0 && !d.loading {
			a.testMessage(f, t.NoAdapters, a.colors.Subtle)
			a.drawDebugOutput(f, p)
			return
		}
		a.drawDebugBreakpoints(f, p)
		f.Divider()
		a.drawDebugFrames(f, p)
	})
}

// drawDebugBreakpoints declares the toggle action and the stored breakpoint
// lines. A line row removes that breakpoint when clicked.
func (a *App) drawDebugBreakpoints(f *ui.Frame, p *project) {
	t, d := a.text.Debug, &p.debug
	f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		f.Text(t.Breakpoints).Color(a.colors.Text).Weight(gfx.WeightMedium).Shrink(0)
		f.Spacer()
		if f.Button(debugToggleBreakpointID, t.ToggleBreakpoint).Outline().Clicked() {
			a.toggleBreakpoint(p)
		}
	})
	paths := make([]string, 0, len(d.breakpoints))
	for path := range d.breakpoints {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		f.Row().Height(debugRowHeight).Shrink(0).PadX(10).Items(ui.Center).Children(func() {
			f.Text(t.NoBreakpoints).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		})
		return
	}
	row := 0
	for _, path := range paths {
		for _, line := range d.breakpoints[path] {
			currentPath, currentLine := path, line
			box := f.Row().Height(debugRowHeight).Shrink(0).PadX(10).Items(ui.Center).Gap(6).
				HitWith(debugBreakpointsID.At(row), debugFileName(path)+":"+strconv.FormatInt(line, 10), gfx.HitOptions{
					Role:   gfx.RoleButton,
					Cursor: gfx.PointerCursorHand,
					Hint:   t.RemoveBreakpoint,
				}).Hover(ui.Look{}.Background(a.colors.Hover))
			box.Children(func() {
				f.Icon(icons.CircleX).Size(12, 12).Shrink(0).Color(a.theme.Danger)
				f.Text(debugFileName(path)).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
				f.Text(":" + strconv.FormatInt(line, 10)).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
			})
			if box.Clicked() {
				a.removeBreakpoint(p, currentPath, currentLine)
			}
			row++
		}
	}
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

// drawDebugFrames declares the paused call stack. A frame with a source path
// opens that location.
func (a *App) drawDebugFrames(f *ui.Frame, p *project) {
	t, d := a.text.Debug, &p.debug
	f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
		f.Text(t.Frames).Color(a.colors.Text).Weight(gfx.WeightMedium).Ellipsis()
	})
	if len(d.frames) == 0 {
		f.Row().FillWidth().Shrink(0).Height(debugRowHeight).PadX(10).Items(ui.Center).Children(func() {
			f.Text(t.NoFrames).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		})
		return
	}
	f.ScrollArea(debugFramesListID).FillWidth().Grow(1).Children(func() {
		for index, frame := range d.frames {
			box := f.Row().FillWidth().Height(debugRowHeight).Shrink(0).PadX(10).Items(ui.Center).Gap(6).
				Hover(ui.Look{}.Background(a.colors.Hover))
			if frame.SourcePath != "" {
				box = box.HitWith(debugFrameRowsID.At(index), frame.Name, gfx.HitOptions{
					Role:   gfx.RoleButton,
					Cursor: gfx.PointerCursorHand,
					Hint:   t.OpenFrame,
				})
			}
			box.Children(func() {
				f.Text(frame.Name).Grow(1).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis()
				if frame.SourcePath != "" {
					position := debugFileName(frame.SourcePath) + ":" + strconv.FormatInt(frame.Line, 10)
					f.Text(position).Shrink(0).FontSize(11.5).Color(a.colors.Subtle)
				}
			})
			if frame.SourcePath != "" && box.Clicked() {
				line := int(frame.Line)
				if line > 0 {
					line--
				}
				a.openFileAtPosition(p, frame.SourcePath, line, 0)
			}
		}
	})
}

// drawDebugOutput shows the adapter's bounded diagnostics when something failed
// or no adapter was found.
func (a *App) drawDebugOutput(f *ui.Frame, p *project) {
	if len(p.debug.output) == 0 {
		return
	}
	lines := p.debug.output
	if len(lines) > 8 {
		lines = lines[len(lines)-8:]
	}
	f.Divider()
	f.Column().Height(120).Shrink(0).Clip().Pad(8).Children(func() {
		f.Paragraph(joinLines(lines), 6).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
}

func joinLines(lines []string) string {
	text := ""
	for _, line := range lines {
		text += line + "\n"
	}
	return text
}
