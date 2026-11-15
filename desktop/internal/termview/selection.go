package termview

import (
	"math"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/gfx"
)

// terminalSelection is anchored to buffer lines, not view rows, so it stays on
// the same text while the view scrolls under a drag.
type terminalSelection struct {
	anchor, focus term.Point
	dragging      bool
	selected      bool
	edge          selectionEdge
	// mark is where the last press was, kept after a click that selected nothing
	// so that a Shift-click can select from it to another point, however far the
	// view was scrolled in between.
	mark   term.Point
	marked bool
	// unit is how far one step of a drag reaches: a cell, or, after a double or
	// triple click, a whole word or line. origin is the word or line that was
	// clicked; the drag keeps it selected whichever way it goes.
	unit   selectionUnit
	origin [2]term.Point
}

// selectionUnit is the granularity a drag snaps to.
type selectionUnit uint8

const (
	unitCell selectionUnit = iota
	unitWord
	unitLine
)

// selectionEdge is the auto-scroll a drag asks for while the pointer is held
// beyond the top or bottom of the grid.
type selectionEdge struct {
	direction int // +1 scrolls back into history, -1 toward the live screen, 0 rests
	lines     int // lines per step, growing with the distance from the grid
	column    int // the column the focus keeps while the view moves under it
	last      time.Duration
	stepped   bool
}

const (
	selectionScrollInterval = 50 * time.Millisecond
	selectionScrollMaxLines = 8
	// selectionScrollMaxSteps caps what one frame may pay back after a stall.
	selectionScrollMaxSteps = 4
)

// clear drops the selection and any drag in progress, and reports whether there
// was one to drop.
func (selection *terminalSelection) clear() bool {
	changed := selection.dragging || selection.selected
	*selection = terminalSelection{}
	return changed
}

// dismiss drops a selection that came to nothing, a click, and keeps where the
// click was.
func (selection *terminalSelection) dismiss() bool {
	mark, marked := selection.mark, selection.marked
	changed := selection.clear()
	selection.mark, selection.marked = mark, marked
	return changed
}

// beginUnit selects the word or line at point and leaves the drag running, so
// that holding the button and moving on grows the selection by words or lines.
func (selection *terminalSelection) beginUnit(screen *term.Terminal, point term.Point, unit selectionUnit) {
	selection.clear()
	selection.unit = unit
	selection.origin[0], selection.origin[1] = selection.unitRange(screen, point)
	selection.anchor, selection.focus = selection.origin[0], selection.origin[1]
	selection.dragging, selection.selected = true, true
	selection.mark, selection.marked = selection.origin[0], true
}

// unitRange is the word or line around point, by the selection's unit.
func (selection *terminalSelection) unitRange(screen *term.Terminal, point term.Point) (term.Point, term.Point) {
	if selection.unit == unitLine {
		return screen.LineRange(point)
	}
	return screen.WordRange(point)
}

// extendUnit moves the drag's focus to point, snapped to whole words or lines.
// The clicked word or line stays inside the selection: dragging before it
// anchors at its end, and dragging after it anchors at its start.
func (selection *terminalSelection) extendUnit(screen *term.Terminal, point term.Point) bool {
	if selection.unit == unitCell {
		return selection.extend(point)
	}
	if !selection.dragging {
		return false
	}
	start, end := selection.unitRange(screen, point)
	anchor, focus := selection.origin[0], end
	if pointBefore(point, selection.origin[0]) {
		anchor, focus = selection.origin[1], start
	}
	if selection.anchor == anchor && selection.focus == focus {
		return false
	}
	selection.anchor, selection.focus = anchor, focus
	return true
}

// begin starts a drag at point, dropping the selection that was there. It
// reports whether it dropped one.
func (selection *terminalSelection) begin(point term.Point) bool {
	changed := selection.clear()
	selection.anchor = point
	selection.focus = point
	selection.dragging = true
	selection.mark, selection.marked = point, true
	return changed
}

// extendTo is a Shift-click: the selection, or failing one the last press, is
// stretched to point, as terminals have always done. With a selection the end
// nearer to point moves and the other stays, so it grows or shrinks from either
// side; the drag that may follow goes on adjusting the same end. It reports false
// when there is nothing to extend from.
func (selection *terminalSelection) extendTo(point term.Point) (changed, ok bool) {
	var anchor term.Point
	switch {
	case selection.selected:
		start, end := selection.anchor, selection.focus
		if pointBefore(end, start) {
			start, end = end, start
		}
		switch {
		case pointBefore(point, start):
			anchor = end
		case pointBefore(end, point):
			anchor = start
		case closerToStart(point, start, end):
			anchor = end
		default:
			anchor = start
		}
	case selection.marked:
		anchor = selection.mark
	default:
		return false, false
	}
	previous := *selection
	selection.anchor, selection.focus = anchor, point
	selection.unit = unitCell
	selection.dragging = true
	selection.selected = anchor != point
	selection.mark, selection.marked = anchor, true
	selection.edge = selectionEdge{}
	return previous.anchor != anchor || previous.focus != point || previous.selected != selection.selected, true
}

// pointBefore reports whether left lies before right in reading order.
func pointBefore(left, right term.Point) bool {
	return left.Line < right.Line || left.Line == right.Line && left.Column < right.Column
}

// closerToStart reports whether point, lying inside start..end, is nearer to start
// than to end: by lines first, then by columns when it is level with both.
func closerToStart(point, start, end term.Point) bool {
	fromStart, toEnd := point.Line-start.Line, end.Line-point.Line
	if fromStart != toEnd {
		return fromStart < toEnd
	}
	return point.Column-start.Column < end.Column-point.Column
}

// extend moves the drag's focus to point by single cells. It reports whether the
// selection changed.
func (selection *terminalSelection) extend(point term.Point) bool {
	if !selection.dragging || selection.focus == point {
		return false
	}
	selection.focus = point
	selection.selected = selection.anchor != selection.focus
	return true
}

// selectRange selects anchor..focus outright, with no drag running.
func (selection *terminalSelection) selectRange(anchor, focus term.Point) {
	selection.anchor = anchor
	selection.focus = focus
	selection.dragging = false
	selection.selected = true
	selection.unit = unitCell
	selection.edge = selectionEdge{}
}

// text is the selected text, wherever in the retained buffer it lies.
func (selection terminalSelection) text(screen *term.Terminal) string {
	return screen.SelectedRange(selection.anchor, selection.focus)
}

// span is the part of one displayed row the selection covers; lineNumber is the
// buffer line that row shows.
func (selection terminalSelection) span(lineNumber uint64, line term.Row, cols int) (int, int, bool) {
	if !selection.selected {
		return 0, 0, false
	}
	start, end := selection.anchor, selection.focus
	if end.Line < start.Line || end.Line == start.Line && end.Column < start.Column {
		start, end = end, start
	}
	if lineNumber < start.Line || lineNumber > end.Line {
		return 0, 0, false
	}
	from, to := 0, cols
	if lineNumber == start.Line {
		from = start.Column
	}
	if lineNumber == end.Line {
		to = end.Column + 1
	}
	if from < len(line.Cells) && line.Cells[from].Attr&term.WideTail != 0 && from > 0 {
		from--
	}
	if to > 0 && to <= len(line.Cells) && line.Cells[to-1].Attr&term.WideHead != 0 {
		to++
	}
	return max(from, 0), min(to, cols), from < to
}

// Pointer handles a pointer event for the view: the scrollbar's, or the grid's.
// The second result is false for an event that is none of the view's, so the
// caller can hand it on. Every press on the grid takes the keyboard.
func (v *View) Pointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	if event.Target == v.cfg.BarID || v.bar.dragging {
		return v.barPointer(event)
	}
	if !v.holdsPointer(event) {
		return gfx.EventResult{}, false
	}
	result := v.terminalPointer(event)
	if event.Kind == gfx.PointerDown {
		result.Focus = v.cfg.HitID
	}
	return result, true
}

// holdsPointer reports whether a pointer event is the grid's: it is over the grid,
// or it continues a drag or a held button the grid started. A held pointer keeps
// reporting to the hit it was pressed on, but the grid does not rely on that to
// end a drag it began.
func (v *View) holdsPointer(event gfx.PointerEvent) bool {
	if event.Target == v.cfg.HitID {
		return true
	}
	return event.Kind != gfx.PointerDown && (v.selection.dragging || v.mouseButton != term.MouseButtonNone)
}

// terminalPointer is the grid's pointer handling: a program's mouse reports when
// it asked for the mouse, the middle-click paste, and otherwise the selection.
func (v *View) terminalPointer(event gfx.PointerEvent) gfx.EventResult {
	selection := &v.selection
	position := v.positionAt(event.X, event.Y)
	if result, handled := v.terminalMousePointer(event, position); handled {
		return result
	}
	if v.openLinkAt(event, position) {
		return gfx.EventResult{Handled: true}
	}
	row := v.screen.Row(position.Row)
	if position.Column < len(row.Cells) && row.Cells[position.Column].Attr&term.WideTail != 0 && position.Column > 0 {
		position.Column--
	}
	switch event.Kind {
	case gfx.PointerDown:
		switch event.Button {
		case gfx.PointerButtonMiddle:
			// A program that asked for the mouse already had this press; what reaches
			// here is the terminal's own. Nothing can take the text once the shell
			// has ended.
			if v.shell != nil {
				v.paste()
			}
			return gfx.EventResult{Handled: true, Repaint: true}
		case gfx.PointerButtonPrimary, gfx.PointerButtonNone:
		default:
			// The secondary button has no menu to open, and the side buttons mean
			// nothing to a terminal.
			return gfx.EventResult{}
		}
		if event.ClickCount >= 2 {
			// A double click takes the word, a triple click the whole line, soft
			// wraps included. The button is still down, so the drag goes on by
			// the same unit.
			unit := unitWord
			if event.ClickCount >= 3 {
				unit = unitLine
			}
			selection.beginUnit(v.screen, v.screen.PointAt(position), unit)
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if event.Modifiers&gfx.ModifierShift != 0 {
			// Shift-click stretches the selection to here. It is the terminal's own
			// selection even when a program has the mouse, which Shift hands back.
			if changed, ok := selection.extendTo(v.screen.PointAt(position)); ok {
				return gfx.EventResult{Handled: true, Repaint: changed}
			}
		}
		return gfx.EventResult{Handled: true, Repaint: selection.begin(v.screen.PointAt(position))}
	case gfx.PointerMove:
		if !selection.dragging || !event.Captured {
			return gfx.EventResult{}
		}
		changed := selection.extendUnit(v.screen, v.screen.PointAt(position))
		v.armSelectionScroll(event, position.Column)
		return gfx.EventResult{Handled: true, Repaint: changed}
	case gfx.PointerUp, gfx.PointerExit:
		if !selection.dragging {
			return gfx.EventResult{Handled: event.Captured}
		}
		changed := false
		if event.Kind == gfx.PointerUp {
			changed = selection.extendUnit(v.screen, v.screen.PointAt(position))
		}
		selection.dragging = false
		selection.edge = selectionEdge{}
		if !selection.selected {
			// A click selects nothing; it only leaves the mark a Shift-click starts from.
			changed = selection.dismiss() || changed
		}
		return gfx.EventResult{Handled: true, Repaint: changed}
	}
	return gfx.EventResult{}
}

// armSelectionScroll decides from where a drag's pointer is whether the view
// has to follow it. A pointer held above or below the grid keeps scrolling
// even when it stops moving, so the steps come from the frames paint asks for
// (see stepSelectionScroll), not from further pointer events.
func (v *View) armSelectionScroll(event gfx.PointerEvent, column int) {
	selection := &v.selection
	_, rows := v.screen.Size()
	bottom := v.layout.top + float32(rows)*v.rowH
	edge := selectionEdge{column: column, last: selection.edge.last, stepped: selection.edge.stepped}
	var distance float32
	switch {
	case event.Y < v.layout.top && v.screen.ViewOffset() < v.screen.Scrollback():
		edge.direction, distance = 1, v.layout.top-event.Y
	case event.Y >= bottom && v.screen.ViewOffset() > 0:
		edge.direction, distance = -1, event.Y-bottom
	default:
		selection.edge = selectionEdge{}
		return
	}
	if v.rowH > 0 {
		edge.lines = min(1+int(distance/v.rowH), selectionScrollMaxLines)
	} else {
		edge.lines = 1
	}
	selection.edge = edge
}

// stepSelectionScroll scrolls a dragging terminal toward the pointer, at the
// rate the edge asked for, and moves the selection's focus onto the row it
// uncovers. It runs from paint, on the frames paint asked for. A frame arrives
// when the compositor has one, so how many intervals have passed decides the
// step: a frame a little early is not a lost step, and a stalled one is not
// paid back all at once.
func (v *View) stepSelectionScroll(now time.Duration) {
	selection := &v.selection
	edge := selection.edge
	if !selection.dragging || edge.direction == 0 {
		return
	}
	steps, next := 1, now
	if edge.stepped {
		elapsed := now - edge.last
		if elapsed < selectionScrollInterval {
			return
		}
		steps = min(int(elapsed/selectionScrollInterval), selectionScrollMaxSteps)
		next = edge.last + time.Duration(steps)*selectionScrollInterval
	}
	if !v.screen.Scroll(edge.direction * edge.lines * steps) {
		selection.edge = selectionEdge{}
		return
	}
	row := 0
	if edge.direction < 0 {
		_, rows := v.screen.Size()
		row = rows - 1
	}
	selection.edge.last, selection.edge.stepped = next, true
	selection.extendUnit(v.screen, v.screen.PointAt(term.Position{Row: row, Column: edge.column}))
}

// terminalMousePointer reports a press, a move or a release to a program that
// asked for the mouse. It reports false when the event is the terminal's own: no
// program wants the mouse, Shift hands it back, a selection is being dragged, or
// the shell has ended and nothing is left to report to.
func (v *View) terminalMousePointer(event gfx.PointerEvent, position term.Position) (gfx.EventResult, bool) {
	if v.selection.dragging {
		return gfx.EventResult{}, false
	}
	if v.shell == nil {
		// A session that ended with a button held would otherwise keep reporting a
		// release to nobody; the selection still works on what it left in the grid.
		v.mouseButton, v.mousePositionValid = term.MouseButtonNone, false
		return gfx.EventResult{}, false
	}
	modes := v.screen.Modes()
	switch event.Kind {
	case gfx.PointerDown:
		if modes.Mouse == term.MouseOff || event.Modifiers&gfx.ModifierShift != 0 {
			return gfx.EventResult{}, false
		}
		button, ok := terminalMouseButton(event.Button)
		if !ok {
			return gfx.EventResult{}, false
		}
		v.mouseButton = button
		v.mousePosition = position
		v.mousePositionValid = true
		repaint := v.sendMouse(term.MouseEvent{
			Kind: term.MousePress, Button: button, Modifiers: terminalMouseModifiers(event.Modifiers),
			Column: position.Column, Row: position.Row,
		})
		return gfx.EventResult{Handled: true, Repaint: repaint}, true
	case gfx.PointerMove:
		button := v.mouseButton
		if button == term.MouseButtonNone {
			if modes.Mouse != term.MouseAny || event.Modifiers&gfx.ModifierShift != 0 {
				return gfx.EventResult{}, false
			}
		}
		if v.mousePositionValid && v.mousePosition == position {
			return gfx.EventResult{Handled: true}, true
		}
		v.mousePosition = position
		v.mousePositionValid = true
		repaint := v.sendMouse(term.MouseEvent{
			Kind: term.MouseMotion, Button: button, Modifiers: terminalMouseModifiers(event.Modifiers),
			Column: position.Column, Row: position.Row,
		})
		return gfx.EventResult{Handled: true, Repaint: repaint}, true
	case gfx.PointerUp:
		button := v.mouseButton
		if button == term.MouseButtonNone {
			return gfx.EventResult{}, false
		}
		v.mouseButton = term.MouseButtonNone
		v.mousePosition = position
		v.mousePositionValid = true
		repaint := v.sendMouse(term.MouseEvent{
			Kind: term.MouseRelease, Button: button, Modifiers: terminalMouseModifiers(event.Modifiers),
			Column: position.Column, Row: position.Row,
		})
		return gfx.EventResult{Handled: true, Repaint: repaint}, true
	case gfx.PointerExit:
		button := v.mouseButton
		if button == term.MouseButtonNone {
			return gfx.EventResult{}, false
		}
		v.mouseButton = term.MouseButtonNone
		// The pointer left the grid with the button down: release where it was last
		// seen, not at the edge it was clamped to.
		if v.mousePositionValid {
			position = v.mousePosition
		}
		repaint := v.sendMouse(term.MouseEvent{
			Kind: term.MouseRelease, Button: button, Modifiers: terminalMouseModifiers(event.Modifiers),
			Column: position.Column, Row: position.Row,
		})
		return gfx.EventResult{Handled: true, Repaint: repaint}, true
	}
	return gfx.EventResult{}, false
}

// sendMouse writes the report of one mouse event, if the program's mouse mode
// takes it. Like typing, it drops the selection and returns the view to the live
// screen, and it reports whether either changed the picture.
func (v *View) sendMouse(event term.MouseEvent) bool {
	report, ok := term.AppendMouse(v.mouseReport[:0], v.screen.Modes(), event)
	if !ok {
		return false
	}
	repaint := v.selection.clear()
	if v.screen.ScrollToBottom() {
		repaint = true
	}
	v.sendInput(report)
	return repaint
}

// terminalMouseButton maps a pointer button to the button a mouse report names.
// The side buttons have no report.
func terminalMouseButton(button gfx.PointerButton) (term.MouseEventButton, bool) {
	switch button {
	case gfx.PointerButtonPrimary:
		return term.MouseButtonLeft, true
	case gfx.PointerButtonMiddle:
		return term.MouseButtonMiddle, true
	case gfx.PointerButtonSecondary:
		return term.MouseButtonRight, true
	default:
		return term.MouseButtonNone, false
	}
}

// terminalMouseModifiers maps the held modifiers to the ones a mouse report carries.
func terminalMouseModifiers(modifiers gfx.Modifiers) term.MouseModifiers {
	var result term.MouseModifiers
	if modifiers&gfx.ModifierShift != 0 {
		result |= term.MouseModifierShift
	}
	if modifiers&gfx.ModifierMeta != 0 {
		result |= term.MouseModifierMeta
	}
	if modifiers&gfx.ModifierControl != 0 {
		result |= term.MouseModifierControl
	}
	return result
}

// positionAt is the cell under a point of the window, clamped into the grid so a
// drag that leaves the pane still names a cell at its edge.
func (v *View) positionAt(x, y float32) term.Position {
	// The painted grid can lead the screen's resize while a window changes. Clamp
	// against both so a click in the painted pane stays in the screen.
	cols, rows := v.screen.Size()
	if cols <= 0 || rows <= 0 || v.layout.cols <= 0 || v.layout.rows <= 0 {
		return term.Position{}
	}
	column, row := 0, 0
	if v.cellW > 0 {
		column = int(math.Floor(float64((x - v.layout.left) / v.cellW)))
	}
	if v.rowH > 0 {
		row = int(math.Floor(float64((y - v.layout.top) / v.rowH)))
	}
	return term.Position{
		Row:    min(max(row, 0), min(v.layout.rows, rows)-1),
		Column: min(max(column, 0), min(v.layout.cols, cols)-1),
	}
}
