package textview

import (
	"math"
	"time"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Span is a styled byte range of one line: its color, an optional background, and
// whether it is a link a click opens.
type Span struct {
	From, To   int
	Color      gfx.Color
	Background gfx.Color // drawn when its Alpha is above zero
	Bold       bool
	Italic     bool
	Underline  bool
	Strike     bool
	Link       bool
	// Hover is the color of a link while the pointer is over it, when its Alpha is above
	// zero. Label names the link for assistive technology; empty names it by its text.
	Hover gfx.Color
	Label string
}

// Trail is a note drawn after a line, at the view's right edge on the line's first row: a
// badge, or with Button set a button a click presses. It is not part of the text, so a
// selection never takes it and a copy never holds it.
type Trail struct {
	Text   string
	Style  gfx.TextStyle
	Button bool
}

// trailGap is the room between a line's text and its trail.
const trailGap = 6

// ellipsis ends a line cut short; it takes one cell.
const ellipsis = "\u2026"

// Spec is what a view shows and how, given again in every paint.
type Spec struct {
	// Label names the text for assistive technology.
	Label  string
	Source Source
	// Font is the fixed-pitch face and size the text is drawn in; its Color is the color
	// of what no span colors. LineHeight is the height of one row.
	Font       gfx.TextStyle
	LineHeight float32
	PadX, PadY float32
	// Selection is the color behind the selected text.
	Selection gfx.Color
	// Scroll makes the view an area of its own that scrolls, keeps to the newest line
	// while the user has not scrolled up (Follow) and fills the area's height. Without it
	// the view is as tall as its text, to be placed in a scrolling area.
	Scroll bool
	Follow bool
	// Wrap breaks a line wider than the view into rows, at a space where it can.
	Wrap bool
	// Ellipsis cuts a line wider than a view that does not wrap one cell short of the edge,
	// and ends it in an ellipsis in the color it was cut in. The text cut off is still
	// selected and copied.
	Ellipsis bool
	// Revision, when not zero, changes whenever the lines or their trails do, so a view
	// that wraps breaks its lines again only when it or the width changed. Zero breaks them
	// on every paint.
	Revision uint64
	// LineBackground is the color behind line n, across the view, when its Alpha is above
	// zero.
	LineBackground func(n int) gfx.Color
	// Trail is the note drawn after line n; one with no Text draws nothing. PressTrail is
	// called with n when a click without a drag lands on a Button trail.
	Trail      func(n int) Trail
	PressTrail func(n int)
	// Spans styles line n, whose text is text, appending to dst. Nil draws every line in
	// Font. It is asked only for the rows on screen and for the line a click lands on.
	Spans func(n int, text string, dst []Span) []Span
	// Open is called with a link span a click without a drag landed on.
	Open func(n int, span Span)
	// Copy puts the selection Primary+C copies on the clipboard; nil puts it there as it
	// is.
	Copy func(text string)
	// Menu, when set, is the context menu a secondary press opens.
	Menu func(*ui.MenuItems)
}

// View is the state of one read-only text: its selection, the press being followed and
// where the last paint put its rows. Keep it in the model with what it shows.
type View struct {
	Selection Selection

	spec  Spec
	input ui.Handlers
	draw  func(*ui.DrawContext)
	id    gfx.ID

	// rect is the control as the last paint placed it and clip the part of it on screen;
	// cellW and lineH are the grid it was drawn on, width the text width it wrapped at,
	// and rows its rows when it wraps.
	rect, clip   gfx.Rect
	cellW, cellH float32
	lineH        float32
	width        float32
	rows         []row
	wrapCols     int

	// pressed says a primary press on the view is held; press is where it went down and
	// moved whether it has left that spot, and pointer where the pointer is now.
	pressed bool
	moved   bool
	press   gfx.Point
	pointer gfx.Point
	clicks  int
	// stepAt is when the drag past an edge last scrolled the area.
	stepAt time.Duration

	menuOpen bool
	menuAt   gfx.Point
	menuLine int
	menuSet  bool

	toEnd bool
	// scrollLine, when scrollSet, is the line the next paint of a scrolling view centers.
	scrollLine int
	scrollSet  bool
	spans      []Span
	// wrap lays out a view that wraps and does not scroll, at the width the page gives it.
	wrap wrapLayout
	// canvas is the canvas of the last declaration, which measures the trails.
	canvas *gfx.Canvas
	// laid is what the rows were broken for.
	laid layoutKey

	// trails are the Button trails the last paint drew; trailHeld says a press went down on
	// the trail of line trailLine.
	trails    []trailHit
	trailHeld bool
	trailLine int
	// hover is the link under the pointer, when hovering: its line and its first byte.
	hover    Point
	hovering bool
}

// trailHit is where a paint drew the Button trail of a line.
type trailHit struct {
	line int
	rect gfx.Rect
}

// layoutKey is what a wrapped view's rows depend on.
type layoutKey struct {
	revision     uint64
	width, cellW float32
	first, count int
	wrap         bool
}

// row is one row of a wrapped view: the bytes from to to of line.
type row struct {
	line, from, to int
}

// ScrollToEnd keeps a scrolling view at its newest line from the next paint on.
func (v *View) ScrollToEnd() { v.toEnd, v.scrollSet = true, false }

// ScrollTo scrolls a scrolling view in its next paint so that line n is in the middle of
// it, and stops it following the newest line.
func (v *View) ScrollTo(n int) { v.scrollLine, v.scrollSet, v.toEnd = n, true, false }

// MenuLine is the line a secondary press opened the menu on, and false when it was below
// the text.
func (v *View) MenuLine() (int, bool) { return v.menuLine, v.menuSet }

// Has reports whether text is selected.
func (v *View) Has() bool { return v.spec.Source != nil && v.Selection.Has(v.spec.Source) }

// Text is the selected text.
func (v *View) Text() string {
	if v.spec.Source == nil {
		return ""
	}
	return v.Selection.Text(v.spec.Source)
}

// SelectAll selects all the text.
func (v *View) SelectAll() {
	if v.spec.Source != nil {
		v.Selection.SelectAll(v.spec.Source)
	}
}

// RowRect is where the last paint put line n's first row, and false when that row was
// not on screen.
func (v *View) RowRect(n int) (gfx.Rect, bool) {
	index, ok := v.firstRowOf(n)
	if !ok {
		return gfx.Rect{}, false
	}
	r := gfx.Rect{X: v.rect.X, Y: v.rect.Y + v.spec.PadY + float32(index)*v.lineH, Width: v.rect.Width, Height: v.lineH}
	if r.Y+r.Height <= v.clip.Y || r.Y >= v.clip.Y+v.clip.Height {
		return gfx.Rect{}, false
	}
	return r, true
}

// PointOf is a point in the first quarter of the cell the last paint put byte p.Byte of
// line p.Line in, where a click places the caret before that character and a double click
// picks the word it is in; false when its row was not on screen.
func (v *View) PointOf(p Point) (gfx.Point, bool) {
	src := v.spec.Source
	index, ok := v.firstRowOf(p.Line)
	if !ok {
		return gfx.Point{}, false
	}
	for index+1 < v.rowCount() && !v.lastRow(index) {
		if _, _, to := v.rowBytes(index); p.Byte < to {
			break
		}
		index++
	}
	_, from, _ := v.rowBytes(index)
	text := src.Line(p.Line)
	at := min(max(p.Byte, from), len(text))
	x := v.rect.X + v.spec.PadX + (float32(cellsOf(text[from:at], 0))+0.25)*v.cellW
	y := v.rect.Y + v.spec.PadY + (float32(index)+0.5)*v.lineH
	if y < v.clip.Y || y >= v.clip.Y+v.clip.Height {
		return gfx.Point{}, false
	}
	return gfx.Point{X: x, Y: y}, true
}

// Visible is the range of lines the last paint showed, from the first to the one after
// the last.
func (v *View) Visible() (int, int) {
	src := v.spec.Source
	if src == nil || v.lineH <= 0 {
		return 0, 0
	}
	from, to := v.rowRange()
	return v.rowLine(from), v.rowLine(max(to-1, from)) + 1
}

// Declare declares the view with spec and returns its outermost box: the scrolling area,
// or the text itself.
func (v *View) Declare(c ui.C, spec Spec) ui.Box {
	v.spec = spec
	if v.draw == nil {
		v.draw = v.paint
		v.input = ui.Handlers{Role: gfx.RoleGroup, Pointer: v.onPointer, Key: v.onKey}
	}
	canvas := c.Canvas()
	v.canvas = canvas
	v.cellW, v.cellH = canvas.MonoCellSize(spec.Font.Size, spec.Font.MonoFace)
	v.lineH = max(spec.LineHeight, v.cellH)
	v.layout(v.width)
	height := float32(v.rowCount())*v.lineH + 2*spec.PadY
	var control, outer ui.Box
	if spec.Scroll {
		outer = ui.Scroll(c).Scrollbars().Follow(spec.Follow).Label(spec.Label)
		state := outer.ScrollState()
		if v.toEnd {
			v.toEnd = false
			state.ScrollToEnd()
		}
		v.dragScroll(canvas, state)
		if v.scrollSet {
			v.scrollSet = false
			if index, ok := v.firstRowOf(v.scrollLine); ok {
				// The area knows the new height only once it lays it out; it is told now, so
				// the offset is not clamped to the old one and the area stops following.
				state.Content = max(state.Content, height)
				target := spec.PadY + float32(index)*v.lineH - (state.Viewport-v.lineH)/2
				state.ScrollTo(min(max(target, 0), max(state.Content-state.Viewport, 0)))
			}
		}
		height = max(height, state.Viewport)
		outer.Children(func() {
			v.id = ui.ID(c.Part("text"))
			control = ui.Control(c.Part("text"), spec.Label, &v.input).FillWidth().Height(height).Draw(v.draw)
		})
	} else if spec.Wrap {
		// The rows depend on the width, which the page knows only once it lays the view
		// out: the layout wraps the lines there, before it asks for the height.
		v.wrap.v = v
		outer = ui.CustomLayout(c, &v.wrap).FillWidth().Children(func() {
			v.id = ui.ID(c.Part("text"))
			control = ui.Control(c.Part("text"), spec.Label, &v.input).Draw(v.draw)
		})
	} else {
		v.id = ui.ID(c.Part("text"))
		control = ui.Control(c.Part("text"), spec.Label, &v.input).FillWidth().Height(height).Draw(v.draw)
		outer = control
	}
	if control.Shortcut(ui.Primary, "c") && v.Has() {
		text, copy := v.Text(), spec.Copy
		c.After(func() {
			if copy != nil {
				copy(text)
				return
			}
			_ = app.SetClipboardText(text)
		})
	}
	if control.Shortcut(ui.Primary, "a") {
		v.SelectAll()
	}
	if spec.Menu != nil {
		ui.ContextMenuAt(c.Key("menu"), control, &v.menuOpen, v.menuAt, spec.Menu)
	}
	return outer
}

// wrapLayout lays out a view that wraps: the text takes the width it is given and is as
// tall as its rows at that width.
type wrapLayout struct{ v *View }

func (l *wrapLayout) MeasureWidth(*ui.LayoutContext) float32 { return 0 }

func (l *wrapLayout) PlaceWidth(ctx *ui.LayoutContext, bounds ui.Rect) {
	if v := l.v; bounds.Width != v.width {
		v.width = bounds.Width
		v.layout(v.width)
	}
	if ctx.Count() > 0 {
		ctx.SetX(0, bounds.X)
		ctx.SetWidth(0, bounds.Width)
	}
}

func (l *wrapLayout) MeasureHeight(*ui.LayoutContext) float32 {
	v := l.v
	return float32(v.rowCount())*v.lineH + 2*v.spec.PadY
}

func (l *wrapLayout) PlaceHeight(ctx *ui.LayoutContext, bounds ui.Rect) {
	if ctx.Count() > 0 {
		ctx.SetY(0, bounds.Y)
		ctx.SetHeight(0, bounds.Height)
	}
}

// dragScroll scrolls the area while a drag holds the pointer past its top or bottom edge,
// a step of rows every 50 ms that grows with the distance, as IDEA's editor does.
func (v *View) dragScroll(canvas *gfx.Canvas, state *ui.ScrollState) {
	if !v.pressed || !v.moved || v.lineH <= 0 {
		return
	}
	top, bottom := v.clip.Y, v.clip.Y+v.clip.Height
	distance := float32(0)
	switch {
	case v.pointer.Y < top:
		distance = v.pointer.Y - top
	case v.pointer.Y > bottom:
		distance = v.pointer.Y - bottom
	default:
		return
	}
	now := canvas.Now()
	if now-v.stepAt >= dragStep {
		v.stepAt = now
		lines := min(1+float32(math.Abs(float64(distance)))/v.lineH, 8)
		if distance < 0 {
			lines = -lines
		}
		state.ScrollTo(min(max(state.Offset+float32(int(lines))*v.lineH, 0), state.Max()))
	}
	canvas.RequestFrameIn(dragStep)
}

const dragStep = 50 * time.Millisecond

// onPointer selects with the primary button, opens a link a click lands on and opens
// the menu at a secondary press.
func (v *View) onPointer(event gfx.PointerEvent) gfx.EventResult {
	src := v.spec.Source
	if src == nil {
		return gfx.EventResult{}
	}
	at := gfx.Point{X: event.X, Y: event.Y}
	switch event.Kind {
	case gfx.PointerDown:
		if event.Button == gfx.PointerButtonSecondary {
			if v.spec.Menu == nil {
				return gfx.EventResult{}
			}
			v.menuLine, v.menuSet = 0, false
			if p, ok := v.pointAt(at, false); ok {
				v.menuLine, v.menuSet = p.Line, true
			}
			v.menuOpen, v.menuAt = true, at
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if event.Button != gfx.PointerButtonPrimary {
			return gfx.EventResult{}
		}
		if n, ok := v.trailAt(at); ok {
			// A press on a button after a line presses it, and leaves the selection be.
			v.trailHeld, v.trailLine = true, n
			return gfx.EventResult{Handled: true}
		}
		v.pressed, v.moved, v.press, v.pointer, v.clicks = true, false, at, at, max(event.ClickCount, 1)
		p, ok := v.pointAt(at, v.clicks == 1)
		if !ok {
			v.Selection.Clear()
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if event.Modifiers&gfx.ModifierShift != 0 && v.clicks == 1 {
			v.Selection.Extend(p, src.Line(p.Line))
			v.moved = true
		} else {
			v.Selection.Begin(p, src.Line(p.Line), v.clicks)
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.PointerMove:
		if !v.pressed {
			return gfx.EventResult{Handled: v.trailHeld, Repaint: v.hoverAt(at)}
		}
		v.pointer = at
		if !v.moved && math.Abs(float64(at.X-v.press.X)) < 3 && math.Abs(float64(at.Y-v.press.Y)) < 3 {
			return gfx.EventResult{Handled: true}
		}
		v.moved = true
		v.extendTo(at)
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.PointerUp:
		if v.trailHeld {
			v.trailHeld = false
			if n, ok := v.trailAt(at); ok && n == v.trailLine && v.spec.PressTrail != nil {
				v.spec.PressTrail(n)
			}
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if !v.pressed {
			return gfx.EventResult{}
		}
		v.pressed = false
		if !v.moved && v.clicks == 1 && v.spec.Open != nil {
			if n, span, ok := v.linkAt(at); ok {
				v.spec.Open(n, span)
			}
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.PointerExit:
		if v.hovering {
			v.hovering = false
			return gfx.EventResult{Repaint: true}
		}
		return gfx.EventResult{}
	}
	return gfx.EventResult{}
}

// trailAt is the line whose Button trail the last paint drew under a point.
func (v *View) trailAt(at gfx.Point) (int, bool) {
	for _, t := range v.trails {
		if r := t.rect; at.X >= r.X && at.X < r.X+r.Width && at.Y >= r.Y && at.Y < r.Y+r.Height {
			return t.line, true
		}
	}
	return 0, false
}

// hoverAt follows the link under the pointer, for a link with a Hover color, and reports
// whether it changed.
func (v *View) hoverAt(at gfx.Point) bool {
	n, span, ok := v.linkAt(at)
	ok = ok && span.Hover.Alpha > 0
	p := Point{n, span.From}
	if ok == v.hovering && (!ok || p == v.hover) {
		return false
	}
	v.hover, v.hovering = p, ok
	return true
}

// extendTo moves the selection's focus to the point under the pointer, clamped into the
// text.
func (v *View) extendTo(at gfx.Point) {
	src := v.spec.Source
	if src.Count() == 0 {
		return
	}
	if p, ok := v.pointAt(at, v.Selection.unit == unitChar); ok {
		v.Selection.Extend(p, src.Line(p.Line))
	}
}

// onKey clears the selection with Escape.
func (v *View) onKey(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Key != gfx.KeyEscape || v.spec.Source == nil || !v.Has() {
		return gfx.EventResult{}
	}
	v.Selection.Clear()
	return gfx.EventResult{Handled: true, Repaint: true}
}

// linkAt is the link span under a point.
func (v *View) linkAt(at gfx.Point) (int, Span, bool) {
	p, ok := v.pointAt(at, false)
	if !ok || v.spec.Spans == nil {
		return 0, Span{}, false
	}
	text := v.spec.Source.Line(p.Line)
	if p.Byte >= len(text) {
		return 0, Span{}, false
	}
	v.spans = v.spec.Spans(p.Line, text, v.spans[:0])
	for _, span := range v.spans {
		if span.Link && span.From <= p.Byte && p.Byte < span.To {
			return p.Line, span, true
		}
	}
	return 0, Span{}, false
}

// pointAt is the place in the text under a point of the window, clamped into the text:
// a point above it is its start and one below its end. nearest picks the closest
// character boundary rather than the character under the point. ok is false for a view
// with no text.
func (v *View) pointAt(at gfx.Point, nearest bool) (Point, bool) {
	src := v.spec.Source
	count := v.rowCount()
	if src == nil || src.Count() == 0 || count == 0 || v.lineH <= 0 || v.cellW <= 0 {
		return Point{}, false
	}
	index := int(math.Floor(float64((at.Y - v.rect.Y - v.spec.PadY) / v.lineH)))
	if index < 0 {
		return Point{src.First(), 0}, true
	}
	if index >= count {
		last := src.First() + src.Count() - 1
		return Point{last, len(src.Line(last))}, true
	}
	line, from, to := v.rowBytes(index)
	text := src.Line(line)
	column := (at.X - v.rect.X - v.spec.PadX) / v.cellW
	return Point{line, from + byteAt(text[from:to], column, nearest)}, true
}
