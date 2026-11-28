package workbench

import (
	"math"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

type logGraphRowBounds struct {
	index int
	rect  gfx.Rect
	width float32
	inset float32
}

// logGraphHover owns the geometry of the virtual rows drawn in the last frame.
type logGraphHover struct {
	rows     []logGraphRowBounds
	viewport gfx.Rect
	active   bool
	scale    float32
	chain    int
}

// logGraphPointer follows the window's pointer across project tabs.
type logGraphPointer struct {
	position gfx.Point
	canHover bool
}

func (a *App) trackLogGraphPointer(event gfx.PointerEvent) bool {
	pointer := &a.sessions.graphPointer
	pointer.position = gfx.Point{X: event.X, Y: event.Y}
	// Viva delivers the release to the pressed control before ending capture.
	// The next paint can already use the pointer's actual hovered control.
	dragging := event.Captured && event.Kind != gfx.PointerUp
	pointer.canHover = event.Kind != gfx.PointerExit && event.Device != gfx.PointerTouch && !dragging

	h := &a.logView.graphHover
	chain := 0
	if h.active && pointer.canHover && a.project != nil {
		chain = a.logGraphChainAt(event.Target, pointer.position)
	}
	return chain != h.chain
}

func (a *App) logGraphChainAt(target gfx.ID, point gfx.Point) int {
	if target.IsZero() {
		return 0
	}
	v := &a.logView
	h := &v.graphHover
	if !pointInGraphClip(h.viewport, point) {
		return 0
	}
	for _, visible := range h.rows {
		r := visible.rect
		if point.Y < r.Y || point.Y >= r.Y+r.Height || point.X < r.X+visible.inset {
			continue
		}
		if visible.index >= len(a.project.log.graph.Rows) || target != v.commits.RowID(visible.index) {
			return 0
		}
		clip := intersectGraphClip(
			gfx.Rect{X: visible.inset, Width: visible.width - visible.inset, Height: logRowHeight},
			gfx.Rect{X: h.viewport.X - r.X, Y: h.viewport.Y - r.Y, Width: h.viewport.Width, Height: h.viewport.Height},
		)
		return graphChainInClip(a.project.log.graph.Rows[visible.index], newGraphMetrics(h.scale), clip,
			gfx.Point{X: point.X - r.X, Y: point.Y - r.Y})
	}
	return 0
}

func (a *App) paintLogGraphHover(d *ui.DrawContext) {
	h := &a.logView.graphHover
	h.active, h.scale, h.chain = true, d.Canvas.PixelScale(), 0
	h.viewport = d.Rect
	for _, clip := range d.Canvas.Clips() {
		h.viewport = intersectGraphClip(h.viewport, clip.Bounds)
	}
	pointer := a.sessions.graphPointer
	if a.project == nil || !pointer.canHover {
		return
	}
	h.chain = a.logGraphChainAt(d.Canvas.Hovered(), pointer.position)
	if h.chain == 0 {
		return
	}
	rows := a.project.log.graph.Rows
	m, color := newGraphMetrics(h.scale), a.graphColors()
	d.Canvas.Clip(d.Rect)
	defer d.Canvas.Unclip()
	for _, visible := range h.rows {
		if visible.index < len(rows) {
			a.paintGraphRowWithHover(d.Canvas, m, visible.rect, rows[visible.index], visible.width, visible.inset, color, 0, h.chain)
		}
	}
}

// graphChainAt picks the nearest visible edge or HEAD marker in the row. Core
// supplies the chain shared by the edge and nodes between its branch points.
func graphChainAt(row core.GraphRow, m graphMetrics, width float32, point gfx.Point) int {
	return graphChainInClip(row, m, gfx.Rect{Width: width, Height: logRowHeight}, point)
}

func graphChainInClip(row core.GraphRow, m graphMetrics, clip gfx.Rect, point gfx.Point) int {
	if !pointInGraphClip(clip, point) {
		return 0
	}
	center, headRadius := m.marker(row)
	x, y := point.X-center.X, point.Y-center.Y
	distance := x*x + y*y
	if headRadius > 0 && distance <= headRadius*headRadius {
		dot, innerRing := m.nodeRadius/2, headRadius-m.lineWidth
		if distance <= dot*dot || distance >= innerRing*innerRing {
			return row.HoverChain
		}
		return 0
	}
	if row.HoverChain == 0 && distance <= m.nodeRadius*m.nodeRadius {
		return 0
	}
	best, chain := float32(3*3), 0
	capRadius := m.lineWidth / 2
	for _, edge := range row.PrintElements {
		if edge.HoverChain == 0 {
			continue
		}
		x0, y0, x1, y1 := m.strokeLine(edge, false)
		visitGraphLine(gfx.Point{X: x0, Y: y0}, gfx.Point{X: x1, Y: y1}, center, headRadius, m.dashSpan(edge), func(from, to gfx.Point) {
			dx, dy := to.X-from.X, to.Y-from.Y
			lengthSquared := dx*dx + dy*dy
			if lengthSquared == 0 {
				return
			}
			along := ((point.X-from.X)*dx + (point.Y-from.Y)*dy) / lengthSquared
			closest := min(1, max(0, along))
			overhang := along - closest
			// Widen the target alongside the line, but only hit the painted
			// round cap past an endpoint so the dash gap stays open.
			onLine := gfx.Point{X: from.X + closest*dx, Y: from.Y + closest*dy}
			x, y := onLine.X-point.X, onLine.Y-point.Y
			d := x*x + y*y
			if d >= best || (overhang != 0 && d > capRadius*capRadius) {
				return
			}
			if !pointInGraphClip(clip, onLine) {
				start, end := visibleGraphStrokeInterval(graphArrowWing{from, to}, clip, capRadius, lengthSquared)
				if start > end {
					return
				}
				closest = min(end, max(start, along))
				x, y = from.X+closest*dx-point.X, from.Y+closest*dy-point.Y
				d = x*x + y*y
			}
			if d < best {
				best, chain = d, edge.HoverChain
			}
		})
	}
	return chain
}

func pointInGraphClip(clip gfx.Rect, point gfx.Point) bool {
	return point.X >= clip.X && point.X < clip.Right() && point.Y >= clip.Y && point.Y < clip.Bottom()
}

func intersectGraphClip(a, b gfx.Rect) gfx.Rect {
	left, top := max(a.X, b.X), max(a.Y, b.Y)
	right, bottom := min(a.Right(), b.Right()), min(a.Bottom(), b.Bottom())
	return gfx.Rect{X: left, Y: top, Width: max(0, right-left), Height: max(0, bottom-top)}
}

// visibleGraphStrokeInterval intersects the centerline with the clip expanded
// by the round stroke radius. The expanded rectangle is convex, so the bands
// and corners together give one interval.
func visibleGraphStrokeInterval(line graphArrowWing, clip gfx.Rect, radius, lengthSquared float32) (start, end float32) {
	start, end = 1, 0
	include := func(first, last float32) {
		first, last = max(0, first), min(1, last)
		if first <= last {
			start, end = min(start, first), max(end, last)
		}
	}
	left, top, right, bottom := clip.X, clip.Y, clip.Right(), clip.Bottom()
	include(line.rectInterval(left-radius, top, right+radius, bottom))
	include(line.rectInterval(left, top-radius, right, bottom+radius))
	dx, dy := line.to.X-line.from.X, line.to.Y-line.from.Y
	for _, corner := range [...]gfx.Point{{X: left, Y: top}, {X: right, Y: top}, {X: left, Y: bottom}, {X: right, Y: bottom}} {
		x, y := corner.X-line.from.X, corner.Y-line.from.Y
		cross := x*dy - y*dx
		reachSquared := radius*radius - cross*cross/lengthSquared
		if reachSquared > 0 {
			middle := (x*dx + y*dy) / lengthSquared
			reach := float32(math.Sqrt(float64(reachSquared / lengthSquared)))
			include(middle-reach, middle+reach)
		}
	}
	return start, end
}
