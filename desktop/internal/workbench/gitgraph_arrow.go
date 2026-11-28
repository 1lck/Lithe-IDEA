package workbench

import (
	"math"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// graphArrowPoints uses the same row coordinates for the drawn arrow and its hit area.
func graphArrowPoints(m graphMetrics, edge core.GraphElement) (gfx.Point, [2]gfx.Point) {
	x0, y0, x1, y1 := m.line(edge)
	length := max(1, float32(math.Hypot(float64(x1-x0), float64(y1-y0))))
	vx, vy := (x0-x1)/length*logRowHeight*0.3, (y0-y1)/length*logRowHeight*0.3
	tip := gfx.Point{X: x1, Y: y1}
	return tip, [2]gfx.Point{
		{X: x1 + vx*sqrt07 + vy*sqrt03, Y: y1 - vx*sqrt03 + vy*sqrt07},
		{X: x1 + vx*sqrt07 - vy*sqrt03, Y: y1 + vx*sqrt03 + vy*sqrt07},
	}
}

type graphArrowWing struct{ from, to gfx.Point }

type graphArrowShape struct {
	bounds gfx.Rect
	radius float32
	wings  [4]graphArrowWing // HEAD can split each of the two wings.
	count  int
}

func newGraphArrowShape(m graphMetrics, edge core.GraphElement, center gfx.Point, headRadius float32) graphArrowShape {
	tip, wings := graphArrowPoints(m, edge)
	shape := graphArrowShape{radius: m.lineWidth / 2}
	left, right := float32(math.Inf(1)), float32(math.Inf(-1))
	top, bottom := left, right
	for _, wing := range wings {
		visitGraphLine(tip, wing, center, headRadius, 0, func(from, to gfx.Point) {
			shape.wings[shape.count] = graphArrowWing{from, to}
			shape.count++
			left = min(left, from.X, to.X)
			right = max(right, from.X, to.X)
			top, bottom = min(top, from.Y, to.Y), max(bottom, from.Y, to.Y)
		})
	}
	if shape.count != 0 {
		left = max(0, left-shape.radius)
		top, bottom = max(0, top-shape.radius), min(logRowHeight, bottom+shape.radius)
		right += max(shape.radius, 2)
		shape.bounds = gfx.Rect{X: left, Y: top, Width: right - left, Height: bottom - top}
	}
	return shape
}

func (shape graphArrowShape) visibleIn(rect gfx.Rect, clips []gfx.Clip) bool {
	left, top, right, bottom := rect.X, rect.Y, rect.Right(), rect.Bottom()
	for _, clip := range clips {
		left, top = max(left, clip.Bounds.X), max(top, clip.Bounds.Y)
		right, bottom = min(right, clip.Bounds.Right()), min(bottom, clip.Bounds.Bottom())
	}
	if left >= right || top >= bottom {
		return false
	}
	if left == rect.X && top == rect.Y && right == rect.Right() && bottom == rect.Bottom() {
		return true
	}
	visible := gfx.Rect{
		X: left - rect.X + shape.bounds.X, Y: top - rect.Y + shape.bounds.Y,
		Width: right - left, Height: bottom - top,
	}
	for _, wing := range shape.wings[:shape.count] {
		if wing.intersects(visible, shape.radius) {
			return true
		}
	}
	return false
}

// A round stroke meets the clip when its centerline reaches the clip expanded
// by the radius: the two rectangular bands and the four round corners.
func (wing graphArrowWing) intersects(clip gfx.Rect, radius float32) bool {
	from, to := wing.from, wing.to
	dx, dy := to.X-from.X, to.Y-from.Y
	left, top, right, bottom := clip.X, clip.Y, clip.Right(), clip.Bottom()
	if start, end := wing.rectInterval(left-radius, top, right+radius, bottom); start <= end {
		return true
	}
	if start, end := wing.rectInterval(left, top-radius, right, bottom+radius); start <= end {
		return true
	}
	length := dx*dx + dy*dy
	for _, corner := range [...]gfx.Point{{X: left, Y: top}, {X: right, Y: top}, {X: left, Y: bottom}, {X: right, Y: bottom}} {
		x, y := from.X-corner.X, from.Y-corner.Y
		if length != 0 {
			along := min(1, max(0, -(x*dx+y*dy)/length))
			x, y = x+dx*along, y+dy*along
		}
		if x*x+y*y < radius*radius {
			return true
		}
	}
	return false
}

func (wing graphArrowWing) rectInterval(left, top, right, bottom float32) (start, end float32) {
	start, end = 0, 1
	clipAxis := func(origin, delta, lo, hi float32) bool {
		if delta == 0 {
			return origin >= lo && origin <= hi
		}
		a, b := (lo-origin)/delta, (hi-origin)/delta
		start, end = max(start, min(a, b)), min(end, max(a, b))
		return start <= end
	}
	if !clipAxis(wing.from.X, wing.to.X-wing.from.X, left, right) ||
		!clipAxis(wing.from.Y, wing.to.Y-wing.from.Y, top, bottom) {
		return 1, 0
	}
	return start, end
}

// Expanded history can place a terminal and a continuing arrow to the same
// target on the same row and in the same direction.
func logGraphArrowVariant(edge core.GraphElement) int {
	variant := 0
	if edge.Direction == "up" {
		variant += 2
	}
	if edge.IsTerminal {
		variant++
	}
	return variant
}

// logGraphArrowHighlight ties an active arrow to the edge drawn in this frame.
// The plus-one row leaves the zero value empty.
type logGraphArrowHighlight struct {
	row, edge int
}

// The virtual list may reuse a hit ID while a pointer press is still held.
// Keep the arrow's logical identity from the start of that press.
type logGraphArrowPress struct {
	source logCommitIdentity
	key    string
}

type logGraphArrowPainter struct {
	shape graphArrowShape
	id    gfx.ID
	tip   string
	draw  func(*ui.DrawContext)
}

func (p *logGraphArrowPainter) paint(d *ui.DrawContext) {
	if p.shape.visibleIn(d.Rect, d.Canvas.Clips()) {
		d.Canvas.HitWithOptions(p.id, d.Rect, p.tip, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
	}
}

// The ordinary viewport reuses its paint callbacks. A crowded frame may need
// more arrow hits, but does not increase the number of painters kept afterward.
type logGraphArrowPainters struct {
	slots []*logGraphArrowPainter
	used  int
}

func (p *logGraphArrowPainters) painter(shape graphArrowShape, id gfx.ID, tip string) func(*ui.DrawContext) {
	var slot *logGraphArrowPainter
	if p.used < len(p.slots) {
		slot = p.slots[p.used]
	} else {
		slot = new(logGraphArrowPainter)
		slot.draw = slot.paint
		if len(p.slots) < logRowSlots {
			p.slots = append(p.slots, slot)
		}
	}
	p.used++
	slot.shape, slot.id, slot.tip = shape, id, tip
	return slot.draw
}

func (p *logGraphArrowPainters) endFrame() {
	for _, slot := range p.slots[:min(p.used, len(p.slots))] {
		slot.tip = ""
	}
	p.used = 0
}

// drawLogGraphArrows gives each arrow its own primary action and shares the row's
// context menu so a secondary click on the graph still opens the commit menu.
func (a *App) drawLogGraphArrows(p *project, row ui.ListRow, graphRow core.GraphRow, menu func(*ui.MenuItems)) {
	c := row.C
	canvas := c.Canvas()
	v := &a.logView
	m := newGraphMetrics(canvas.PixelScale())
	var arrowArea ui.Box
	var center gfx.Point
	var headRadius float32
	for i, edge := range graphRow.PrintElements {
		if !edge.HasArrow || edge.TargetHash == "" {
			continue
		}
		target, ok := p.log.commit(edge.TargetHash)
		if !ok {
			continue
		}
		if arrowArea == (ui.Box{}) {
			center, headRadius = m.marker(graphRow)
			arrowArea = ui.Slot(c).Absolute().Left(0).Right(v.metadataWidth(canvas)).Top(0).Height(logRowHeight).Clip()
		}
		shape := newGraphArrowShape(m, edge, center, headRadius)
		bounds := shape.bounds
		if bounds.Width <= 0 || bounds.Height <= 0 {
			continue
		}
		arrowArea.Children(func() {
			key, tip := a.logGraphArrowTip(p, target, edge)
			id := ui.ID(c.Key(key))
			if canvas.Hovered() == id {
				v.hoveredGraphArrow = logGraphArrowHighlight{row.Index + 1, i}
			}
			if canvas.FocusVisible() == id {
				v.focusedGraphArrow = logGraphArrowHighlight{row.Index + 1, i}
			}
			// Give the slot an identity for click, tooltip and menu routing. Emit
			// its hit during drawing, when the list and column clips are known.
			button := ui.Slot(c).Absolute().Left(bounds.X).Top(bounds.Y).Size(bounds.Width, bounds.Height)
			button.N().ID = id
			button.Tooltip(tip).TooltipOn(ui.TooltipRight).Draw(v.arrowPainters.painter(shape, id, tip))
			ui.ContextMenu(c, button, menu)
			clicked, pressed := button.Clicked(), canvas.Pressed() == id
			if !clicked && !pressed {
				return
			}
			press := logGraphArrowPress{source: p.logCommitIdentity(graphRow.CommitHash), key: key}
			if event, ok := canvas.PointerOn(id); pressed && ok && event.Kind == gfx.PointerDown && event.Button == gfx.PointerButtonPrimary {
				v.pressedGraphArrow = press
			}
			if clicked && (canvas.ClickedByKey(id) || v.pressedGraphArrow == press) {
				c.After(func() { a.jumpLogGraphArrow(p, edge.TargetHash) })
			}
		})
	}
}

func (a *App) jumpLogGraphArrow(p *project, hash string) {
	if p == a.project && !p.logReads.retired && p.log.visibleRow(hash) >= 0 {
		a.selectCommit(p, hash)
		p.log.reveal = logRevealWithFocus
	}
}
