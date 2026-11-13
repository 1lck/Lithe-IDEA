package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

// The debugger in the editor's gutter, as the earlier client's editor showed it: a file's line
// breakpoints are drawn over the line numbers, a press on a line number adds or removes the
// line's breakpoint, and while the debuggee is paused the line of the selected frame is tinted.
// The marks are worked out before each paint, into buffers the document keeps, and handed to the
// view only when they change, so an idle frame allocates nothing for them.

// debugExecutionAlpha is how strongly the paused line is tinted with the accent color.
const debugExecutionAlpha = 0.28

// debugGutter is what the view of one document was last given of the debugger.
type debugGutter struct {
	// shown are the breakpoints handed to the view, next the ones being worked out.
	shown, next []editorview.Breakpoint
	// execution is the zero-based paused line handed to the view, -1 for none, and executionSet
	// says the view has been told anything at all.
	execution    int
	executionSet bool
	// click toggles a line's breakpoint; it is made once for the document.
	click func(line int)
}

// applyDebugGutter gives the view of d the file's breakpoints and the paused line when they
// changed, and lets a press on a line number toggle a breakpoint in a file that can have one.
func (a *App) applyDebugGutter(p *project, d *document) {
	g := &d.debugGutter
	if d.virtual {
		d.view.SetBreakpointClick(nil)
	} else {
		if g.click == nil {
			path := d.path
			g.click = func(line int) {
				a.performed("debug.gutter.toggleBreakpoint", "editor")
				a.toggleBreakpointAt(p, path, int64(line+1))
			}
		}
		d.view.SetBreakpointClick(g.click)
	}
	g.next = g.next[:0]
	for _, point := range p.debug.breakpoints[d.path] {
		g.next = append(g.next, editorview.Breakpoint{
			Line:        int(point.line - 1),
			Disabled:    point.disabled || p.debug.muted,
			Conditional: point.condition != "" || point.hitCondition != "",
			Log:         point.logMessage != "",
		})
	}
	if !slices.Equal(g.next, g.shown) {
		g.shown, g.next = g.next, g.shown
		d.view.SetBreakpoints(g.shown)
	}
	execution := debugExecutionLine(&p.debug, d.path)
	if g.executionSet && execution == g.execution {
		return
	}
	g.execution, g.executionSet = execution, true
	if execution < 0 {
		d.view.SetLineHighlights(nil)
		return
	}
	tint := a.colors.Accent
	tint.Alpha *= debugExecutionAlpha
	d.view.SetLineHighlights([]editorview.LineHighlight{{StartLine: execution, EndLine: execution, Color: tint}})
}

// debugExecutionLine is the zero-based line of path the debuggee is paused at in the selected
// frame, or -1.
func debugExecutionLine(d *debugState, path string) int {
	if d.state != "paused" || len(d.frames) == 0 {
		return -1
	}
	index := d.vars.frame
	if index < 0 || index >= len(d.frames) {
		index = 0
	}
	frame := d.frames[index]
	if frame.SourcePath != path || frame.Line < 1 {
		return -1
	}
	return int(frame.Line - 1)
}
