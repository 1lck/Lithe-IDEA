package editorview

import (
	"slices"

	"github.com/vivaui/viva/gfx"
)

// Line breakpoints in the gutter: the debugger's breakpoints of the document, drawn over the line
// numbers in place of the number, as IntelliJ IDEA draws them, so setting one never changes the
// gutter's width or moves the text. A press on a line number asks the host to toggle the line's
// breakpoint; the host owns the breakpoints and sets them again. The paint finds the breakpoints in
// view with the line numbers it already walks and allocates nothing for them. Lines are zero-based.

const (
	// breakpointSize caps the side of a breakpoint's mark, so a tall line still shows a small one.
	breakpointSize = float32(12)
	// breakpointRing is the width of the outline of a disabled breakpoint.
	breakpointRing = float32(1.5)
	// breakpointLogRadius rounds the square a log point is drawn as.
	breakpointLogRadius = float32(2.5)
)

// Breakpoint is the debugger's breakpoint on one line. A disabled breakpoint is drawn as an
// outline, a log point, which prints instead of stopping, as a rounded square, and a breakpoint
// with a condition with a hole in its middle.
type Breakpoint struct {
	Line        int
	Disabled    bool
	Conditional bool
	Log         bool
}

// SetBreakpoints replaces the breakpoints of the gutter, sorted by line. One with a negative line
// is dropped, and the first of several on one line wins. The slice is copied.
func (v *View) SetBreakpoints(points []Breakpoint) {
	g := &v.gutter
	g.breakpoints = g.breakpoints[:0]
	for _, point := range points {
		if point.Line >= 0 {
			g.breakpoints = append(g.breakpoints, point)
		}
	}
	slices.SortStableFunc(g.breakpoints, func(x, y Breakpoint) int { return x.Line - y.Line })
	g.breakpoints = slices.CompactFunc(g.breakpoints, func(x, y Breakpoint) bool { return x.Line == y.Line })
}

// SetBreakpointClick makes a press on a line number call fn with the line, for the host to toggle
// the line's breakpoint. Nil leaves a press on a line number placing the caret, as it does in a
// file the debugger cannot stop in.
func (v *View) SetBreakpointClick(fn func(line int)) { v.gutter.onBreakpoint = fn }

// breakpointFrom is the index of the first breakpoint on line or after it.
func (g *gutterState) breakpointFrom(line int) int {
	lo, hi := 0, len(g.breakpoints)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if g.breakpoints[mid].Line < line {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// breakpointColor is the color of a breakpoint's mark: the Look's, or a default when the theme
// sets none.
func breakpointColor(look Look, log bool) gfx.Color {
	if log {
		if look.LogPoint.Alpha == 0 {
			return gfx.RGB24(0xD9A343)
		}
		return look.LogPoint
	}
	if look.Breakpoint.Alpha == 0 {
		return gfx.RGB24(0xE55765)
	}
	return look.Breakpoint
}

// paintBreakpoint draws the mark of point in the line number cell from left to right of the row
// whose top is y.
func (v *View) paintBreakpoint(canvas *gfx.Canvas, look Look, point Breakpoint, left, right, y float32) {
	side := min(v.lineH-2, breakpointSize)
	rect := gfx.Rect{X: (left + right - side) / 2, Y: y + (v.lineH-side)/2, Width: side, Height: side}
	color := breakpointColor(look, point.Log)
	radius := side / 2
	if point.Log {
		radius = breakpointLogRadius
	}
	if point.Disabled {
		canvas.RoundedBorder(rect, radius, breakpointRing, color, look.Background)
		return
	}
	canvas.Rounded(rect, radius, color)
	if point.Conditional {
		hole := side / 3
		canvas.Rounded(gfx.Rect{X: rect.X + (side-hole)/2, Y: rect.Y + (side-hole)/2, Width: hole, Height: hole}, hole/2, look.Background)
	}
}

// breakpointPointer takes a press on a line number while the host toggles breakpoints. It
// reports whether the press was consumed. The bar of the Git decorations left of the numbers
// keeps its own press.
func (v *View) breakpointPointer(event gfx.PointerEvent) bool {
	g := &v.gutter
	if g.onBreakpoint == nil || event.Button != gfx.PointerButtonPrimary {
		return false
	}
	if event.X < v.area.X+gutterBarX+gutterBarWidth+gutterBarX || event.X >= v.numbersRight {
		return false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	if row < 0 || row >= v.rowCount() {
		return false
	}
	line, _ := v.rowLine(row)
	g.onBreakpoint(line)
	return true
}
