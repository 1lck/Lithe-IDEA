package workbench

import (
	"fmt"
	"math"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func TestGraphHalfEdgesMeetAtRowBoundary(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 1.75, 2, 3} {
		for _, lanes := range [][2]int{{0, 0}, {0, 1}, {1, 0}, {0, 3}, {3, 1}} {
			t.Run(fmt.Sprintf("%gx/%d-%d", scale, lanes[0], lanes[1]), func(t *testing.T) {
				m := newGraphMetrics(scale)
				x0, y0, x1, y1 := m.line(core.GraphElement{Position: lanes[0], AdjacentPosition: lanes[1], Direction: "down"})
				x2, y2, x3, y3 := m.line(core.GraphElement{Position: lanes[1], AdjacentPosition: lanes[0], Direction: "up"})
				if y1 != logRowHeight || y3 != 0 || !graphNear(x1, x3) {
					t.Fatalf("half edges miss shared boundary: down=(%g,%g), next up=(%g,%g)", x1, y1, x3, logRowHeight+y3)
				}
				// The join must lie on the line between the two node centers, including
				// scales where the aligned center is not half the logical row height.
				cross := (x1-x0)*(logRowHeight+y2-y0) - (y1-y0)*(x2-x0)
				if math.Abs(float64(cross)) > 0.001 {
					t.Fatalf("edge changes direction at boundary: cross=%g", cross)
				}
			})
		}
	}
}

func TestGraphBoundaryCapsStayOutsideRow(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 1.75, 2} {
		m := newGraphMetrics(scale)
		overlap := max(m.lineWidth, 1)
		for _, e := range []core.GraphElement{
			{Position: 0, AdjacentPosition: 0, Direction: "down"},
			{Position: 0, AdjacentPosition: 0, Direction: "up"},
			{Position: 0, AdjacentPosition: 1, Direction: "down"},
			{Position: 1, AdjacentPosition: 0, Direction: "up"},
			{Position: 0, AdjacentPosition: 8, Direction: "down"},
			{Position: 8, AdjacentPosition: 0, Direction: "up"},
		} {
			t.Run(fmt.Sprintf("%gx/%s/%d-%d", scale, e.Direction, e.Position, e.AdjacentPosition), func(t *testing.T) {
				x0, y0, x1, y1 := m.line(e)
				gotX, gotY := extendGraphEndpoint(x0, y0, x1, y1, overlap)
				if math.Abs(float64(gotY-y1)) < float64(overlap)-0.0001 || (gotY-y1)*(y1-y0) <= 0 {
					t.Fatalf("edge cap stays too close to row boundary: (%g,%g) -> (%g,%g)", x1, y1, gotX, gotY)
				}
				if cross := (gotX-x0)*(y1-y0) - (gotY-y0)*(x1-x0); math.Abs(float64(cross)) > .001 {
					t.Fatalf("extended edge changes direction: cross=%g", cross)
				}
			})
		}
		x0, y0, x1, y1 := m.line(core.GraphElement{Position: 0, AdjacentPosition: 0, Direction: "down", IsTerminal: true})
		gotX, gotY := extendGraphEndpoint(x0, y0, x1, y1, overlap)
		if gotX != x1 || gotY != y1 {
			t.Fatalf("terminal edge moved away from its node: want (%g,%g), got (%g,%g)", x1, y1, gotX, gotY)
		}
	}
}

func TestGraphNodeSharesItsEdgesCenter(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 2} {
		t.Run(fmt.Sprintf("%gx", scale), func(t *testing.T) {
			var canvas gfx.Canvas
			canvas.SetPixelScale(scale)
			m := newGraphMetrics(scale)
			rect := gfx.Rect{X: 7.2, Y: 10.3, Width: 240, Height: logRowHeight}
			row := core.GraphRow{Lane: 2, ColorID: 1}
			new(App).paintGraphRow(&canvas, m, rect, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
			left, top, right, bottom := float32(math.Inf(1)), float32(math.Inf(1)), float32(math.Inf(-1)), float32(math.Inf(-1))
			point := func(x, y float32) {
				left, top, right, bottom = min(left, x), min(top, y), max(right, x), max(bottom, y)
			}
			for _, r := range canvas.Rectangles() {
				point(r.Bounds.X, r.Bounds.Y)
				point(r.Bounds.X+r.Bounds.Width, r.Bounds.Y+r.Bounds.Height)
			}
			for _, tri := range canvas.Triangles() {
				for _, p := range tri.Points {
					point(p.X, p.Y)
				}
			}
			x, y, _, _ := m.line(core.GraphElement{Position: row.Lane, AdjacentPosition: row.Lane, Direction: "down"})
			if !graphNear((left+right)/2, rect.X+x) || !graphNear((top+bottom)/2, rect.Y+y) {
				t.Fatalf("node center=(%g,%g), edge center=(%g,%g)", (left+right)/2, (top+bottom)/2, rect.X+x, rect.Y+y)
			}
		})
	}
}

func TestGraphHeadHasConcentricRingAndDot(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 2} {
		for _, head := range []bool{false, true} {
			t.Run(fmt.Sprintf("%gx/head=%t", scale, head), func(t *testing.T) {
				var canvas gfx.Canvas
				canvas.SetPixelScale(scale)
				m := newGraphMetrics(scale)
				row := core.GraphRow{Lane: 0, ColorID: 1, PrintElements: []core.GraphElement{
					{Position: 0, AdjacentPosition: 0, Direction: "up", ColorID: 1},
					{Position: 0, AdjacentPosition: 1, Direction: "down", ColorID: 1},
				}}
				if head {
					row.Labels = []core.GraphLabel{{Kind: "head", Title: "HEAD"}}
				} else {
					row.Labels = []core.GraphLabel{{Kind: "branch", Title: "main"}}
				}
				new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
				if !graphInkAt(&canvas, m.laneCenter, m.rowCenter) {
					t.Fatal("node has no central dot")
				}
				for _, direction := range []gfx.Point{{X: 1}, {X: -1}, {Y: -1}, {X: .6, Y: .8}} {
					x, y := m.laneCenter+direction.X*m.nodeRadius*.8, m.rowCenter+direction.Y*m.nodeRadius*.8
					if got := graphInkAt(&canvas, x, y); got == head {
						t.Fatalf("gap at (%g,%g): painted=%t, head=%t", x, y, got, head)
					}
				}
				if head && !graphInkAt(&canvas, m.laneCenter-m.nodeRadius-m.lineWidth, m.rowCenter) {
					t.Fatal("HEAD has no outer ring")
				}
			})
		}
	}
}

func TestGraphDottedEdgesKeepTheirGaps(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 2} {
		for _, dotted := range []bool{false, true} {
			t.Run(fmt.Sprintf("%gx/dotted=%t", scale, dotted), func(t *testing.T) {
				var canvas gfx.Canvas
				canvas.SetPixelScale(scale)
				m := newGraphMetrics(scale)
				e := core.GraphElement{Position: 2, AdjacentPosition: 2, Direction: "down", ColorID: 1, IsDotted: dotted}
				row := core.GraphRow{Lane: 0, ColorID: 1, PrintElements: []core.GraphElement{e}}
				new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
				x, y0, _, y1 := m.line(e)
				ink, gaps := 0, 0
				for y := y0 + 2; y < y1-1; y += .25 {
					if graphInkAt(&canvas, x, y) {
						ink++
					} else {
						gaps++
					}
				}
				if ink == 0 || dotted && gaps == 0 || !dotted && gaps != 0 {
					t.Fatalf("dotted=%t: painted samples=%d, gap samples=%d", dotted, ink, gaps)
				}
			})
		}
	}
}

func TestGraphArrowsRetainSolidShaftAndBothWings(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 2} {
		for _, direction := range []string{"up", "down"} {
			for _, terminal := range []bool{false, true} {
				t.Run(fmt.Sprintf("%gx/%s/terminal=%t", scale, direction, terminal), func(t *testing.T) {
					var canvas gfx.Canvas
					canvas.SetPixelScale(scale)
					m := newGraphMetrics(scale)
					e := core.GraphElement{Position: 2, AdjacentPosition: 2, Direction: direction, ColorID: 1, HasArrow: true, IsDotted: true, IsTerminal: terminal}
					row := core.GraphRow{Lane: 0, ColorID: 1, PrintElements: []core.GraphElement{e}}
					new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
					x, y0, _, y1 := m.line(e)
					for y := min(y0, y1) + 1; y < max(y0, y1)-1; y += .25 {
						if !graphInkAt(&canvas, x, y) {
							t.Fatalf("arrow shaft has a gap at (%g,%g)", x, y)
						}
					}
					back := float32(-4)
					if direction == "up" {
						back = 4
					}
					for _, side := range []float32{-2.5, 2.5} {
						if !graphInkAt(&canvas, x+side, y1+back) {
							t.Fatalf("arrow wing missing at (%g,%g)", x+side, y1+back)
						}
					}
				})
			}
		}
	}
}

func TestGraphHeadPreservesIncidentDottedEdgePhase(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 2} {
		t.Run(fmt.Sprintf("%gx", scale), func(t *testing.T) {
			m := newGraphMetrics(scale)
			e := core.GraphElement{Position: 0, AdjacentPosition: 3, Direction: "down", ColorID: 1, IsDotted: true}
			paint := func(head bool) *gfx.Canvas {
				canvas := new(gfx.Canvas)
				canvas.SetPixelScale(scale)
				row := core.GraphRow{Lane: 0, ColorID: 1, PrintElements: []core.GraphElement{e}}
				if head {
					row.Labels = []core.GraphLabel{{Kind: "head", Title: "HEAD"}}
				}
				new(App).paintGraphRow(canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
				return canvas
			}
			normal, head := paint(false), paint(true)
			x0, y0, x1, y1 := m.line(e)
			length := float32(math.Hypot(float64(x1-x0), float64(y1-y0)))
			// Compare beyond both markers, where a HEAD ring must not change the
			// existing edge's dash or gap pattern.
			ink, gaps := 0, 0
			for distance := float32(8); distance < length-1; distance += .5 {
				x := x0 + (x1-x0)*distance/length
				y := y0 + (y1-y0)*distance/length
				want, got := graphInkAt(normal, x, y), graphInkAt(head, x, y)
				if got != want {
					t.Fatalf("HEAD changes dash phase at distance %g: head=%t, normal=%t", distance, got, want)
				}
				if want {
					ink++
				} else {
					gaps++
				}
			}
			if ink == 0 || gaps == 0 {
				t.Fatalf("comparison did not cover both dashes and gaps: ink=%d, gaps=%d", ink, gaps)
			}
		})
	}
}

func TestGraphHeadClipsCrossingEdge(t *testing.T) {
	for _, scale := range []float32{1, 1.25, 1.5, 2} {
		t.Run(fmt.Sprintf("%gx", scale), func(t *testing.T) {
			var canvas gfx.Canvas
			canvas.SetPixelScale(scale)
			m := newGraphMetrics(scale)
			e := core.GraphElement{Position: 7, AdjacentPosition: 1, Direction: "down", ColorID: 2}
			row := core.GraphRow{Lane: 6, ColorID: 1, PrintElements: []core.GraphElement{e}, Labels: []core.GraphLabel{{Kind: "head", Title: "HEAD"}}}
			new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
			x0, y0, x1, y1 := m.line(e)
			x, y := m.laneCenter+float32(row.Lane)*m.laneSpacing, m.rowCenter
			dx, dy := x1-x0, y1-y0
			fraction := ((x-x0)*dx + (y-y0)*dy) / (dx*dx + dy*dy)
			if graphInkAt(&canvas, x0+dx*fraction, y0+dy*fraction) {
				t.Fatal("an edge from another lane crosses the HEAD marker gap")
			}
			for _, outside := range []float32{.1, .8} {
				if !graphInkAt(&canvas, x0+dx*outside, y0+dy*outside) {
					t.Fatalf("crossing edge lost its outer segment at fraction %g", outside)
				}
			}
		})
	}
}

func TestGraphWideDiagonalKeepsItsBoundaryAndHit(t *testing.T) {
	const scale, chain = 1.25, 7
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	m := newGraphMetrics(scale)
	edge := core.GraphElement{Direction: "down", AdjacentPosition: 40, ColorID: 1, HoverChain: chain}
	row := core.GraphRow{ColorID: 1, PrintElements: []core.GraphElement{edge}}
	new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 900, Height: logRowHeight}, row, func(int32) gfx.Color { return gfx.RGB(220, 70, 80) })
	x0, y0, x1, y1 := m.line(edge)
	y := y1 - .1
	x := x1 - (x1-x0)*(y1-y)/(y1-y0)
	if !graphInkAt(&canvas, x, y) {
		t.Errorf("wide diagonal is clipped before its boundary at (%g,%g)", x, y)
	}
	if got := graphChainAt(row, m, m.titleOffset(row), gfx.Point{X: x, Y: y}); got != chain {
		t.Errorf("wide diagonal near the boundary hit chain %d, want %d", got, chain)
	}
}

func TestGraphDiagonalDashPhaseCrossesRowBoundary(t *testing.T) {
	const scale, chain = 1.25, 7
	m := newGraphMetrics(scale)
	color := func(int32) gfx.Color { return gfx.RGB(220, 70, 80) }
	var paint, hit [2]bool
	for i, edge := range []core.GraphElement{
		{Direction: "down", Position: 0, AdjacentPosition: 4, IsDotted: true, ColorID: 1, HoverChain: chain},
		{Direction: "up", Position: 4, AdjacentPosition: 0, IsDotted: true, ColorID: 1, HoverChain: chain},
	} {
		var canvas gfx.Canvas
		canvas.SetPixelScale(scale)
		row := core.GraphRow{Lane: edge.Position, ColorID: 1, PrintElements: []core.GraphElement{edge}}
		new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, color)
		x0, y0, x1, y1 := m.line(edge)
		point := gfx.Point{X: x1 + (x0-x1)*.025, Y: y1 + (y0-y1)*.025}
		paint[i] = graphInkAt(&canvas, point.X, point.Y)
		hit[i] = graphChainAt(row, m, m.titleOffset(row), point) == chain
	}
	if paint[0] != paint[1] || hit != paint {
		t.Fatalf("dash phase differs across the row boundary: paint %v, hit %v", paint, hit)
	}
}

func TestGraphDiagonalDashKeepsStrokeWidthAtRowBoundary(t *testing.T) {
	const scale, chain = 1.25, 7
	m := newGraphMetrics(scale)
	color := func(int32) gfx.Color { return gfx.RGB(220, 70, 80) }
	for _, edge := range []core.GraphElement{
		{Direction: "down", Position: 0, AdjacentPosition: 3, IsDotted: true, ColorID: 1, HoverChain: chain},
		{Direction: "up", Position: 3, AdjacentPosition: 0, IsDotted: true, ColorID: 1, HoverChain: chain},
	} {
		var canvas gfx.Canvas
		canvas.SetPixelScale(scale)
		row := core.GraphRow{Lane: edge.Position, ColorID: 1, PrintElements: []core.GraphElement{edge}}
		width := new(App).paintGraphRow(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, color)
		x0, y0, x1, y1 := m.line(edge)
		dy := float32(math.Copysign(.1, float64(y0-y1)))
		x := x1 + (x1-x0)*dy/(y1-y0)
		// At this slope the leading side of the dash still lies within its
		// true width, past the centerline endpoint of a half cut too short.
		x += float32(math.Copysign(.65, float64(x1-x0)))
		if !graphInkAt(&canvas, x, y1+dy) {
			t.Errorf("%s dash loses its leading fringe by the row clip", edge.Direction)
		}
		if got := graphChainAt(row, m, width, gfx.Point{X: x, Y: y1 + dy}); got != chain {
			t.Errorf("%s dash fringe hit chain %d, want %d", edge.Direction, got, chain)
		}
	}
}

func TestGraphHeadHighlightPreservesRingGap(t *testing.T) {
	const scale, chain = 2, 7
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	m := newGraphMetrics(scale)
	a := new(App)
	a.colors.Text = gfx.RGB(235, 240, 250)
	row := core.GraphRow{
		ColorID:       1,
		HoverChain:    chain,
		Labels:        []core.GraphLabel{{Kind: "head"}},
		PrintElements: []core.GraphElement{{Direction: "down", ColorID: 1, HoverChain: chain}},
	}
	rect := gfx.Rect{Width: 240, Height: logRowHeight}
	color := func(int32) gfx.Color { return gfx.RGB(220, 70, 80) }
	width := a.paintGraphRow(&canvas, m, rect, row, color)
	a.paintGraphRowWithHover(&canvas, m, rect, row, width, 0, color, 0, chain)
	x := m.laneCenter + m.nodeRadius*.66
	if graphInkAt(&canvas, x, m.rowCenter) {
		t.Fatalf("highlight closed the gap between the HEAD ring and dot at x=%g", x)
	}
	if y := m.rowCenter + m.nodeRadius*.9; graphInkAt(&canvas, m.laneCenter, y) {
		t.Fatalf("the highlighted outgoing edge covers the HEAD ring gap at y=%g", y)
	}
	if x := m.laneCenter + m.nodeRadius + m.lineWidth*1.5; !graphInkAt(&canvas, x, m.rowCenter) {
		t.Fatalf("highlight did not outline the outside of the HEAD ring at x=%g", x)
	}
}

func TestGraphSolidHighlightKeepsStrokeWidthAtRowBoundary(t *testing.T) {
	const scale, chain = 1.25, 7
	m := newGraphMetrics(scale)
	a := &App{colors: palette{Text: gfx.RGB(235, 240, 250)}}
	color := func(int32) gfx.Color { return gfx.RGB(220, 70, 80) }
	for _, edge := range []core.GraphElement{
		{Direction: "down", Position: 0, AdjacentPosition: 8, ColorID: 1, HoverChain: chain},
		{Direction: "up", Position: 8, AdjacentPosition: 0, ColorID: 1, HoverChain: chain},
	} {
		var canvas gfx.Canvas
		canvas.SetPixelScale(scale)
		row := core.GraphRow{Lane: edge.Position, ColorID: 1, PrintElements: []core.GraphElement{edge}}
		a.paintGraphRowWithHover(&canvas, m, gfx.Rect{Width: 240, Height: logRowHeight}, row, m.titleOffset(row), 0, color, 0, chain)
		x0, y0, x1, y1 := m.line(edge)
		dy := float32(math.Copysign(.1, float64(y0-y1)))
		x := x1 + (x1-x0)*dy/(y1-y0) + float32(math.Copysign(7.9, float64(x1-x0)))
		if !graphInkAt(&canvas, x, y1+dy) {
			t.Errorf("%s highlighted stroke narrows near the row boundary at (%g,%g)", edge.Direction, x, y1+dy)
		}
	}
}

func TestGraphArrowHighlightKeepsHEADGap(t *testing.T) {
	const scale = 1.75
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	m := newGraphMetrics(scale)
	a := &App{colors: palette{Text: gfx.RGB(235, 240, 250)}}
	color := func(int32) gfx.Color { return gfx.RGB(220, 70, 80) }
	edge := core.GraphElement{Direction: "up", Position: 0, AdjacentPosition: 5, ColorID: 1, HasArrow: true}
	row := core.GraphRow{Lane: 2, ColorID: 1, PrintElements: []core.GraphElement{edge}, Labels: []core.GraphLabel{{Kind: "head"}}}
	rect := gfx.Rect{Width: 240, Height: logRowHeight}
	a.logView.focusedGraphArrow = logGraphArrowHighlight{row: 1}
	a.paintGraphRowWithHover(&canvas, m, rect, row, m.titleOffset(row), 0, color, 1, 0)
	center, _ := m.marker(row)
	_, wings := graphArrowPoints(m, edge)
	wing := wings[0]
	dx, dy := wing.X-center.X, wing.Y-center.Y
	distance := float32(math.Hypot(float64(dx), float64(dy)))
	x, y := center.X+4*dx/distance, center.Y+4*dy/distance
	if graphInkAt(&canvas, x, y) {
		t.Fatalf("focused arrow outline covers the HEAD gap at (%g,%g)", x, y)
	}
	if !graphInkAt(&canvas, wing.X, wing.Y) {
		t.Fatalf("the arrow lost its colored wing at %+v", wing)
	}
}

func graphNear(a, b float32) bool { return math.Abs(float64(a-b)) < 0.0001 }

// graphInkAt samples retained geometry before rasterization, so marker tests
// also detect an incident edge leaking through the transparent ring gap.
func graphInkAt(canvas *gfx.Canvas, x, y float32) bool {
	for _, r := range canvas.Rectangles() {
		b := r.Bounds
		if x < b.X || x > b.X+b.Width || y < b.Y || y > b.Y+b.Height {
			continue
		}
		cx, cy := max(b.X+r.Radius, min(x, b.X+b.Width-r.Radius)), max(b.Y+r.Radius, min(y, b.Y+b.Height-r.Radius))
		if (x-cx)*(x-cx)+(y-cy)*(y-cy) <= r.Radius*r.Radius {
			return true
		}
	}
	for _, tri := range canvas.Triangles() {
		if tri.HasClip && (x < tri.ClipOf.X || x >= tri.ClipOf.Right() || y < tri.ClipOf.Y || y >= tri.ClipOf.Bottom()) {
			continue
		}
		a, b, c := tri.Points[0], tri.Points[1], tri.Points[2]
		d1 := (x-b.X)*(a.Y-b.Y) - (a.X-b.X)*(y-b.Y)
		d2 := (x-c.X)*(b.Y-c.Y) - (b.X-c.X)*(y-c.Y)
		d3 := (x-a.X)*(c.Y-a.Y) - (c.X-a.X)*(y-a.Y)
		if !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0)) {
			return true
		}
	}
	return false
}
