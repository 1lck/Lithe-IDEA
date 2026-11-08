package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// tabDrag is the gesture that moves a terminal's tab: within its strip, to another group,
// into a split beside a group, or back into the Terminal tool window. The zero value is no
// gesture.
type tabDrag struct {
	// pressed says the primary button went down on the tab of terminal term; active says the
	// pointer then moved far enough for the press to be a drag.
	pressed, active bool
	term            int
	// startX and startY are where the press began and x and y where the pointer is now.
	startX, startY float32
	x, y           float32
	// viewport is the window's size at the last move, which keeps the ghost inside it.
	viewport ui.Size
	// target is where the tab would land if it were dropped now.
	target dropTarget
}

// tabDragPointer follows a press on a terminal's tab, the way dragPointer follows a press
// on a button: it leaves the press alone until the pointer has moved by dragThreshold, so
// the tab still gets its ordinary click, and from then on it takes every event of the
// gesture. Taking an event is what keeps the release from becoming a click, because the
// runtime clicks only when neither the press nor the release was handled.
func (a *App) tabDragPointer(event ui.PointerEvent) (ui.EventResult, bool) {
	d := &a.term.drag
	switch event.Kind {
	case ui.PointerDown:
		*d = tabDrag{}
		if event.Button != ui.PointerButtonPrimary {
			return ui.EventResult{}, false
		}
		if id, ok := event.Target.In(termTabs); ok && a.project != nil && a.project.terms.find(id) != nil {
			*d = tabDrag{pressed: true, term: id, startX: event.X, startY: event.Y}
		}
		// The tab under the pointer still gets its press.
		return ui.EventResult{}, false

	case ui.PointerMove:
		if !d.pressed {
			return ui.EventResult{}, false
		}
		if !d.active {
			dx, dy := event.X-d.startX, event.Y-d.startY
			if dx*dx+dy*dy < dragThreshold*dragThreshold {
				return ui.EventResult{}, false
			}
			d.active = true
		}
		d.x, d.y, d.viewport = event.X, event.Y, event.Viewport
		d.target = a.tabDragLocate(d.term, event.X, event.Y, event.Viewport)
		return ui.EventResult{Handled: true, Repaint: true}, true

	case ui.PointerUp:
		if !d.active {
			*d = tabDrag{}
			return ui.EventResult{}, false
		}
		// The place is worked out again at the release: the last move may be older than the
		// release by a frame in which the layout changed.
		term := d.term
		target := a.tabDragLocate(term, event.X, event.Y, event.Viewport)
		*d = tabDrag{}
		a.dropTerminal(term, target)
		return ui.EventResult{Handled: true, Repaint: true}, true

	case ui.PointerExit:
		// The runtime reports an exit during a held press only once the button is released,
		// so this ends a gesture whose release was lost.
		active := d.active
		*d = tabDrag{}
		return ui.EventResult{Repaint: active}, active
	}
	return ui.EventResult{}, false
}

// cancelTabDrag drops the gesture without moving anything and reports whether a drag was
// under way, so that the key that cancelled it is not also given to something else.
func (a *App) cancelTabDrag() bool {
	active := a.term.drag.active
	a.term.drag = tabDrag{}
	return active
}

// tabDragLocate finds where dropping terminal term at (x, y) would put it, from where the
// last frame laid the groups out. Outside the window there is no place. viewport is the
// window's size.
func (a *App) tabDragLocate(term int, x, y float32, viewport ui.Size) dropTarget {
	if x < 0 || y < 0 || x >= viewport.Width || y >= viewport.Height {
		return dropTarget{}
	}
	return dropAt(a.term.places, a.term.emptyRect, term, x, y)
}

// paintTabDrag paints the gesture on top of the frame, in the manner of paintDrag: the area
// the tab would fill is lightly tinted, a tab dropped between two others shows the
// insertion line in the accent color, and a small copy of the tab follows the pointer below
// and to the right of it, so it never hides the line. The tab itself stays where it is,
// dimmed (see drawTerminalTab).
func (a *App) paintTabDrag(canvas *ui.Canvas) {
	d := &a.term.drag
	if !d.active || a.project == nil {
		return
	}
	t := a.project.terms.find(d.term)
	if t == nil {
		return
	}
	canvas.PushLayer(dragLayer)
	defer canvas.PopLayer()

	if target := d.target; target.kind != dropNone {
		preview := target.preview
		if target.kind == dropJoin {
			preview = preview.Inset(ui.All(-dragZoneOutset))
		}
		canvas.Rounded(preview, dragZoneRadius, a.colors.Accent.WithAlpha(dragTargetTint))
		if target.hasLine {
			canvas.Rounded(target.line, dragMark/2, a.colors.Accent)
		}
	}

	// The copy is the tab's icon and title in a box of the width of the words, kept inside
	// the window and no wider than a tab is.
	title := a.text.Terminal.Tab(t.number)
	style := ui.TextStyle{Size: a.theme.Metrics.FontSizeM, Weight: ui.WeightRegular, Color: a.colors.Text}
	width := min(chromeEdge+terminalChipIcon+terminalChipGap+canvas.TextWidthStyle(title, style)+chromeEdge, terminalChipMaxWidth)
	ghost := ui.Rect{X: d.x + dragGhostOffset, Y: d.y + dragGhostOffset, Width: width, Height: rowHeight}
	if d.viewport.Width > 0 {
		ghost.X = max(min(ghost.X, d.viewport.Width-ghost.Width-dragGhostMargin), 0)
		ghost.Y = max(min(ghost.Y, d.viewport.Height-ghost.Height-dragGhostMargin), 0)
	}
	canvas.RoundedBorder(ghost, dragGhostRadius, 1, a.colors.Accent, a.colors.Editor)
	canvas.DrawIcon(icons.SquareTerminal, ui.Rect{
		X:      ghost.X + chromeEdge,
		Y:      ghost.Y + (ghost.Height-terminalChipIcon)/2,
		Width:  terminalChipIcon,
		Height: terminalChipIcon,
	}, a.colors.Subtle)
	canvas.Label(title, ui.Rect{
		X:      ghost.X + chromeEdge + terminalChipIcon + terminalChipGap,
		Y:      ghost.Y,
		Width:  ghost.Width - 2*chromeEdge - terminalChipIcon - terminalChipGap,
		Height: ghost.Height,
	}, style)
}
