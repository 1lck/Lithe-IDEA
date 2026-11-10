package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
)

// tabDrag is the gesture that moves a tab, a terminal's or a file's: within its strip, to
// another group, into a split beside a group, or, for a terminal, back into the Terminal tool
// window. The zero value is no gesture.
type tabDrag struct {
	// active says the tab of group member is being dragged.
	active bool
	member string
	// x and y are where the pointer is now.
	x, y float32
	// viewport is the window's size at the last move, which keeps the ghost inside it.
	viewport gfx.Size
	// target is where the tab would land if it were dropped now.
	target dropTarget
}

// tabAccept is the tab target's accept callback: it follows the pointer of the drag of a
// tab, works out where dropping it would put it and says whether that is a place.
func (a *App) tabAccept(source, _ gfx.ID) bool {
	member, ok := a.term.tabOf(source)
	if !ok {
		return false
	}
	d := &a.term.drag
	point := a.dnd.tab.At()
	d.active, d.member, d.x, d.y, d.viewport = true, member, point.X, point.Y, a.viewport()
	d.target = a.tabDragLocate(member, point.X, point.Y, d.viewport)
	return d.target.kind != dropNone
}

// tabDrop does what dropping the dragged tab where tabAccept last aimed it asks for.
func (a *App) tabDrop(_, _ gfx.ID) {
	d := a.term.drag
	a.term.drag = tabDrag{}
	if d.active {
		a.dropTab(d.member, d.target)
	}
}

// tabDragLocate finds where dropping the tab of group member at (x, y) would put it, from
// where the last frame laid the groups out. Outside the window there is no place. viewport
// is the window's size.
func (a *App) tabDragLocate(member string, x, y float32, viewport gfx.Size) dropTarget {
	if x < 0 || y < 0 || x >= viewport.Width || y >= viewport.Height {
		return dropTarget{}
	}
	return dropAt(a.term.places(), a.term.emptyRect, member, x, y)
}

// paintTabDrag paints the gesture on top of the frame, in the manner of paintDrag: the area
// the tab would fill is lightly tinted, a tab dropped between two others shows the
// insertion line in the accent color, and a small copy of the tab follows the pointer below
// and to the right of it, so it never hides the line. The tab itself stays where it is,
// dimmed (see drawTerminalTab).
func (a *App) paintTabDrag(canvas *gfx.Canvas) {
	d := &a.term.drag
	if !d.active || a.project == nil {
		return
	}
	title, icon, ok := a.tabLook(d.member)
	if !ok {
		return
	}
	canvas.PushLayer(dragLayer)
	defer canvas.PopLayer()

	if target := d.target; target.kind != dropNone {
		preview := target.preview
		if target.kind == dropJoin {
			preview = preview.Inset(gfx.All(-dragZoneOutset))
		}
		canvas.Rounded(preview, dragZoneRadius, a.colors.Accent.WithAlpha(dragTargetTint))
		if target.hasLine {
			canvas.Rounded(target.line, dragMark/2, a.colors.Accent)
		}
	}

	// The copy is the tab's icon and title in a box of the width of the words, kept inside
	// the window and no wider than a tab is.
	style := gfx.TextStyle{Size: a.theme.Metrics.FontSizeM, Weight: gfx.WeightRegular, Color: a.colors.Text}
	width := min(chromeEdge+terminalChipIcon+terminalChipGap+canvas.TextWidthStyle(title, style)+chromeEdge, terminalChipMaxWidth)
	ghost := gfx.Rect{X: d.x + dragGhostOffset, Y: d.y + dragGhostOffset, Width: width, Height: rowHeight}
	if d.viewport.Width > 0 {
		ghost.X = max(min(ghost.X, d.viewport.Width-ghost.Width-dragGhostMargin), 0)
		ghost.Y = max(min(ghost.Y, d.viewport.Height-ghost.Height-dragGhostMargin), 0)
	}
	canvas.RoundedBorder(ghost, dragGhostRadius, 1, a.colors.Accent, a.colors.Editor)
	canvas.DrawIcon(icon, gfx.Rect{
		X:      ghost.X + chromeEdge,
		Y:      ghost.Y + (ghost.Height-terminalChipIcon)/2,
		Width:  terminalChipIcon,
		Height: terminalChipIcon,
	}, a.colors.Subtle)
	canvas.Label(title, gfx.Rect{
		X:      ghost.X + chromeEdge + terminalChipIcon + terminalChipGap,
		Y:      ghost.Y,
		Width:  ghost.Width - 2*chromeEdge - terminalChipIcon - terminalChipGap,
		Height: ghost.Height,
	}, style)
}

// tabLook is the title and the icon of the tab of group member, a terminal's or a file's, and
// false for a member that is no longer open.
func (a *App) tabLook(member string) (string, gfx.Icon, bool) {
	p := a.project
	if p == nil {
		return "", gfx.Icon{}, false
	}
	if id, ok := memberTerminal(member); ok {
		if t := p.terms.find(id); t != nil {
			return a.terminalTitle(t), icons.SquareTerminal, true
		}
		return "", gfx.Icon{}, false
	}
	if id, ok := memberDocument(member); ok {
		if doc := p.docs.find(id); doc != nil {
			return doc.name, fileicons.ForFile(doc.name, a.colors.Dark), true
		}
	}
	return "", gfx.Icon{}, false
}
