package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func TestGraphHoverHitsOnlyVisibleStrokeSegments(t *testing.T) {
	m := newGraphMetrics(1.25)
	const chain = 7
	passing := core.GraphRow{
		Lane:          1,
		PrintElements: []core.GraphElement{{Direction: "down", IsDotted: true, HoverChain: chain}},
	}
	head := core.GraphRow{
		HoverChain:    chain,
		Labels:        []core.GraphLabel{{Kind: "head"}},
		PrintElements: []core.GraphElement{{Direction: "down", HoverChain: chain}},
	}
	for _, tt := range []struct {
		name string
		row  core.GraphRow
		y    float32
		want int
	}{
		{"dash", passing, m.rowCenter + 4, chain},
		{"dash gap", passing, logRowHeight - 2, 0},
		{"HEAD dot", head, m.rowCenter, chain},
		{"HEAD ring gap", head, m.rowCenter + m.nodeRadius*.75, 0},
		{"stroke outside HEAD ring", head, m.rowCenter + m.nodeRadius + m.lineWidth + 2, chain},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := graphChainAt(tt.row, m, m.titleOffset(tt.row), gfx.Point{X: m.laneCenter, Y: tt.y}); got != tt.want {
				t.Errorf("hover chain = %d, want %d", got, tt.want)
			}
		})
	}
	outside := gfx.Point{X: m.laneCenter - 2, Y: m.rowCenter + 4}
	if got := graphChainAt(passing, m, m.laneCenter-1, outside); got != 0 {
		t.Errorf("a stroke just past the graph clip still hits chain %d", got)
	}
}

func TestGraphHighlightLeavesRepositoryStripClear(t *testing.T) {
	const scale, chain = 2, 7
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	a := &App{theme: ui.LightTheme(), colors: palette{Text: gfx.RGB(235, 240, 250)}, project: &project{log: newGitLogState()}, sessions: &windowSessions{}}
	a.project.nested = nestedState{
		repos: []nestedRepo{{id: "nested"}}, showColors: true, slots: map[string]int{"nested": 0}, logRepo: "nested",
	}
	a.project.log.graph.Rows = []core.GraphRow{{ColorID: 1, HoverChain: chain, Labels: []core.GraphLabel{{Kind: "head"}}}}
	v := &a.logView
	page := ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
		v.graphHover.rows = v.graphHover.rows[:0]
		ui.List(c, &v.commits, 1, func(row ui.ListRow) {
			row.Element.Height(logRowHeight).FillWidth().Draw(v.rowPainter(a, row.Index))
		}).Fill().DrawOver(a.paintLogGraphHover)
	}})
	size := gfx.Size{Width: 240, Height: 65}
	page.Paint(&canvas, size)
	if len(v.graphHover.rows) != 1 {
		t.Fatalf("painted %d graph rows", len(v.graphHover.rows))
	}
	row := v.graphHover.rows[0].rect
	m := newGraphMetrics(scale)
	a.sessions.graphPointer = logGraphPointer{position: gfx.Point{X: row.X + m.laneCenter, Y: row.Y + m.rowCenter}, canHover: true}
	canvas.Reset()
	canvas.SetInteraction(v.commits.RowID(0), gfx.ID{}, gfx.ID{}, false)
	page.Paint(&canvas, size)
	if v.graphHover.chain != chain {
		t.Fatalf("hover chain = %d, want %d", v.graphHover.chain, chain)
	}
	var highlightDrawn bool
	for _, triangle := range canvas.Triangles() {
		if triangle.Color != a.colors.Text {
			continue
		}
		highlightDrawn = true
		if !triangle.HasClip || triangle.ClipOf.X < row.X+logRootStripWidth {
			t.Fatalf("highlight can paint over the repository strip: %+v", triangle)
		}
	}
	if !highlightDrawn {
		t.Fatal("the hovered HEAD has no highlight")
	}
}

func TestGraphLogKeepsMetadataClearInNarrowPane(t *testing.T) {
	const scale, chain = 1.25, 7
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	p := &project{log: newGitLogState()}
	a := &App{theme: ui.LightTheme(), colors: palette{Text: gfx.RGB(235, 240, 250)}, project: p, sessions: &windowSessions{}}
	m := newGraphMetrics(scale)
	size := gfx.Size{Width: logCommitsMin, Height: 65}
	graphRight := size.Width - a.logView.dateColumn(&canvas) - logMetaGap
	hiddenLane := int((graphRight-m.laneCenter+2*logDatePad)/m.laneSpacing) + 1
	page := narrowLogGraphPage(a, hiddenLane, chain)
	v := &a.logView
	page.Paint(&canvas, size)
	if len(v.graphHover.rows) != 1 {
		t.Fatalf("painted %d graph rows, want 1", len(v.graphHover.rows))
	}
	row := v.graphHover.rows[0].rect
	visible := gfx.Point{X: row.X + m.laneCenter, Y: row.Y + m.rowCenter + 7}
	hidden := gfx.Point{X: visible.X + float32(hiddenLane)*m.laneSpacing, Y: visible.Y}
	graphRight = row.Right() - v.dateColumn(&canvas) - logMetaGap
	assertClipped := func(name string, color gfx.Color) {
		t.Helper()
		found := false
		for _, triangle := range canvas.Triangles() {
			if triangle.Color != color {
				continue
			}
			found = true
			if !triangle.HasClip || triangle.ClipOf.Right() > graphRight+.01 {
				t.Errorf("%s clip reaches x=%g, want at most %g", name, triangle.ClipOf.Right(), graphRight)
				break
			}
		}
		if !found {
			t.Errorf("the %s did not paint", name)
		}
	}
	assertClipped("base graph stroke", graphColor(1, a.colors.Dark, a.colors.Text))
	_, visibleTip := a.logGraphArrowTip(p, p.log.commits[1], p.log.graph.Rows[0].PrintElements[1])
	_, hiddenTip := a.logGraphArrowTip(p, p.log.commits[2], p.log.graph.Rows[0].PrintElements[2])
	var hasVisibleArrow bool
	for _, hit := range canvas.Hits() {
		if hit.Label == hiddenTip {
			t.Error("a graph arrow is still interactive in the author column")
		}
		hasVisibleArrow = hasVisibleArrow || hit.Label == visibleTip
	}
	if !hasVisibleArrow {
		t.Error("the graph lost its visible arrow")
	}

	a.sessions.graphPointer = logGraphPointer{position: visible, canHover: true}
	canvas.Reset()
	canvas.SetInteraction(v.commits.RowID(0), gfx.ID{}, gfx.ID{}, false)
	page.Paint(&canvas, size)
	if v.graphHover.chain != chain {
		t.Fatalf("hover chain = %d, want %d", v.graphHover.chain, chain)
	}
	assertClipped("chain highlight", a.colors.Text)
	a.sessions.graphPointer.position = hidden
	canvas.Reset()
	canvas.SetInteraction(v.commits.RowID(0), gfx.ID{}, gfx.ID{}, false)
	page.Paint(&canvas, size)
	if v.graphHover.chain != 0 {
		t.Errorf("the author column still hits graph chain %d", v.graphHover.chain)
	}
}

func TestGraphArrowFocusRequiresVisibleStroke(t *testing.T) {
	const scale, lane = 1.25, 9
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	a := &App{theme: ui.LightTheme(), project: &project{log: newGitLogState()}}
	page := narrowLogGraphPage(a, lane, 7)
	log := &a.project.log
	row := &log.graph.Rows[0]
	m := newGraphMetrics(scale)
	metadata := a.logView.metadataWidth(&canvas)
	for _, test := range []struct {
		name    string
		cutoff  float32
		head    bool
		visible bool
	}{
		{name: "only click padding", cutoff: -1.6},
		{name: "visible wing", cutoff: 1, visible: true},
		{name: "HEAD clips the wing", cutoff: .25, head: true},
		{name: "visible wing next to HEAD", cutoff: 2, head: true, visible: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			arrow := row.PrintElements[2]
			if test.head {
				row.Lane = lane
				row.Labels = []core.GraphLabel{{Kind: "head"}}
				arrow.Direction = "up"
				row.PrintElements[2] = arrow
			}
			_, label := a.logGraphArrowTip(a.project, log.commits[2], arrow)
			tip, wings := graphArrowPoints(m, arrow)
			left := min(tip.X, wings[0].X, wings[1].X)
			canvas.Reset()
			page.Paint(&canvas, gfx.Size{Width: metadata + left + test.cutoff, Height: 65})
			var found, focusable bool
			for _, hit := range canvas.Hits() {
				if hit.Label == label {
					found, focusable = true, hit.Focusable
					break
				}
			}
			if found != test.visible || focusable != test.visible {
				t.Fatalf("arrow has a hit = %t and focus = %t, want both %t", found, focusable, test.visible)
			}
		})
	}
}

func TestGraphHoverRequiresVisibleStrokeInJointClip(t *testing.T) {
	const chain = 7
	m := newGraphMetrics(1.25)
	for _, test := range []struct {
		name         string
		edge         core.GraphElement
		width        float32
		point        gfx.Point
		visibleWidth float32
		visiblePoint gfx.Point
	}{
		{
			name:  "solid",
			edge:  core.GraphElement{Direction: "up", Position: 13, AdjacentPosition: 1, HoverChain: chain},
			width: 138.5, point: gfx.Point{X: 138.35, Y: .06},
			visibleWidth: 153, visiblePoint: gfx.Point{X: 151.4, Y: .6},
		},
		{
			name:  "dotted",
			edge:  core.GraphElement{Direction: "up", Position: 9, AdjacentPosition: 3, IsDotted: true, HoverChain: chain},
			width: 115.6, point: gfx.Point{X: 115.48, Y: .09},
			visibleWidth: 150, visiblePoint: gfx.Point{X: 140.5, Y: 4.2},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			row := core.GraphRow{PrintElements: []core.GraphElement{test.edge}}
			if got := graphChainAt(row, m, test.width, test.point); got != 0 {
				t.Errorf("the clipped line activated chain %d", got)
			}
			if got := graphChainAt(row, m, test.visibleWidth, test.visiblePoint); got != chain {
				t.Errorf("the visible line activated chain %d, want %d", got, chain)
			}
		})
	}
}

func TestGraphHoverMeasuresDistanceToVisibleViewportStroke(t *testing.T) {
	const scale, chain = 1.25, 7
	a := &App{theme: ui.LightTheme(), project: &project{log: newGitLogState()}, sessions: &windowSessions{}}
	p := a.project
	p.log.commits = []core.GitCommit{{Hash: "commit"}}
	p.log.byHash = indexCommits(p.log.commits)
	p.log.graph.Rows = []core.GraphRow{{
		CommitHash: "commit",
		PrintElements: []core.GraphElement{
			{Direction: "up", Position: 13, AdjacentPosition: 1, ColorID: 1, HoverChain: chain},
		},
	}}
	v := &a.logView
	page := ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
		v.graphHover.rows = v.graphHover.rows[:0]
		ui.List(c, &v.commits, 1, func(row ui.ListRow) {
			row.Element.Height(logRowHeight).FillWidth().Draw(v.rowPainter(a, 0))
		}).Fill()
	}})
	var canvas gfx.Canvas
	canvas.SetPixelScale(scale)
	page.Paint(&canvas, gfx.Size{Width: 600, Height: 65})
	if len(v.graphHover.rows) != 1 {
		t.Fatalf("paint produced %d graph rows, want 1", len(v.graphHover.rows))
	}
	painted := v.graphHover.rows[0].rect
	canvas.Reset()
	canvas.Clip(gfx.Rect{X: painted.X, Y: painted.Y + 5, Width: painted.Width, Height: painted.Height - 5})
	defer canvas.Unclip()
	canvas.SetInteraction(v.commits.RowID(0), gfx.ID{}, gfx.ID{}, false)
	a.sessions.graphPointer.canHover = true
	for _, test := range []struct {
		x    float32
		want int
	}{{180.91, 0}, {187.6, chain}} {
		a.sessions.graphPointer.position = gfx.Point{X: painted.X + test.x, Y: painted.Y + 5.05}
		a.paintLogGraphHover(&ui.DrawContext{Canvas: &canvas, Rect: painted})
		if got := v.graphHover.chain; got != test.want {
			t.Errorf("hover at X=%g activated chain %d, want %d", test.x, got, test.want)
		}
	}
}

func narrowLogGraphPage(a *App, hiddenLane, chain int) *ui.Page {
	p, v := a.project, &a.logView
	p.log.commits = []core.GitCommit{
		{Hash: "source", AuthorName: "Lithe Test Author", Date: "2020-01-02T12:34:00Z"},
		{Hash: "visible", Subject: "Visible arrow target"},
		{Hash: "hidden", Subject: "Clipped arrow target"},
	}
	p.log.byHash = indexCommits(p.log.commits)
	p.log.graph.Rows = []core.GraphRow{{
		CommitHash: "source",
		ColorID:    1,
		HoverChain: chain,
		PrintElements: []core.GraphElement{
			{Direction: "down", ColorID: 1, HoverChain: chain},
			{Direction: "up", Position: 1, AdjacentPosition: 1, ColorID: 1, HasArrow: true, TargetHash: "visible", IsTerminal: true},
			{Direction: "down", Position: hiddenLane, AdjacentPosition: hiddenLane, ColorID: 1, HoverChain: chain, HasArrow: true, TargetHash: "hidden", IsTerminal: true},
		},
	}}
	for lane := 2; lane < hiddenLane; lane++ {
		p.log.graph.Rows[0].PrintElements = append(p.log.graph.Rows[0].PrintElements,
			core.GraphElement{Direction: "up", Position: lane, AdjacentPosition: lane, ColorID: int32(lane)},
			core.GraphElement{Direction: "down", Position: lane, AdjacentPosition: lane, ColorID: int32(lane)})
	}
	return ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
		v.graphHover.rows = v.graphHover.rows[:0]
		ui.List(c, &v.commits, 1, func(row ui.ListRow) {
			row.Element.Height(logRowHeight).FillWidth().Draw(v.rowPainter(a, row.Index))
			a.drawLogGraphArrows(p, row, p.log.graph.Rows[0], func(*ui.MenuItems) {})
		}).Fill().DrawOver(a.paintLogGraphHover)
	}})
}
