//go:build vivahead && lithevisual

package workbench

import (
	"image"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
	"github.com/vivaui/viva/ui"
)

func TestVisualGitGraphHover(t *testing.T) {
	testVisualGitGraphHover(t, false, "git-log-path-hover-dark-1.25x.png")
}

func TestVisualGitGraphHoverFixture(t *testing.T) {
	testVisualGitGraphHover(t, true, "git-log-path-hover-fixture-dark-1.25x.png")
}

func TestVisualGitGraphNarrowMetadata(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	const scale, chain = 1.25, 7
	a := &App{
		theme:   ui.DarkTheme(),
		colors:  palette{Dark: true, Text: gfx.RGB(235, 240, 250)},
		project: &project{log: newGitLogState()},
	}
	var page *ui.Page
	m := newGraphMetrics(scale)
	session, err := headless.Open(app.Config{
		Width: logCommitsMin, Height: 52,
		ClearColor: app.Color{Red: 31.0 / 255, Green: 34.0 / 255, Blue: 39.0 / 255, Alpha: 1},
		Paint: func(c *gfx.Canvas, size gfx.Size) {
			if page == nil {
				graphRight := size.Width - a.logView.dateColumn(c) - logMetaGap
				hiddenLane := int((graphRight-m.laneCenter+2*logDatePad)/m.laneSpacing) + 1
				page = narrowLogGraphPage(a, hiddenLane, chain)
			}
			page.Paint(c, size)
		},
		OnPointer: func(event gfx.PointerEvent) gfx.EventResult {
			return gfx.EventResult{Repaint: a.trackLogGraphPointer(event)}
		},
	}, nil, headless.Options{Scale: scale})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	h := &a.logView.graphHover
	if len(h.rows) != 1 {
		t.Fatalf("painted %d graph rows, want 1", len(h.rows))
	}
	r := h.rows[0].rect
	if err := session.Driver().Move(r.X+m.laneCenter, r.Y+m.rowCenter+7); err != nil {
		t.Fatal(err)
	}
	if h.chain != chain {
		t.Fatalf("hover chain = %d, want %d", h.chain, chain)
	}
	if err := session.Screenshot(filepath.Join(out, "git-log-narrow-metadata-dark-1.25x.png")); err != nil {
		t.Fatal(err)
	}
}

func testVisualGitGraphHover(t *testing.T, useFixture bool, screenshot string) {
	t.Helper()
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	dir := newGraphHoverRepository(t)
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice("dark"), Language: "en", DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	const scale = 1.25
	var session *headless.Session
	h := newHarnessWithDriver(t, Options{Kernel: gitKernel{core.NewClient()}, Store: prefs, Languages: []string{"en"}}, func(config app.Config) (*app.Driver, func(), error) {
		config.Width, config.Height = 1200, 1050
		var err error
		session, err = headless.Open(config, nil, headless.Options{Scale: scale})
		if err != nil {
			return nil, nil, err
		}
		return session.Driver(), session.Close, nil
	})
	p := h.openLog(t, dir)
	h.settleChain()
	if useFixture {
		applyGraphHoverFixture(t, &p.log)
	}
	m := newGraphMetrics(scale)
	find := func(subject string) (core.GraphRow, gfx.Rect) {
		for _, row := range p.log.graph.Rows {
			if commit, ok := p.log.commit(row.CommitHash); ok && commit.Subject == subject {
				return row, h.pageHit(subject).Bounds
			}
		}
		t.Fatalf("Git Log is missing %q", subject)
		return core.GraphRow{}, gfx.Rect{}
	}
	node := func(subject string) gfx.Point {
		row, bounds := find(subject)
		return gfx.Point{X: bounds.X + m.laneCenter + float32(row.Lane)*m.laneSpacing, Y: bounds.Y + m.rowCenter}
	}
	nodeSide := func(subject string) gfx.Point {
		point := node(subject)
		point.X += m.nodeRadius
		return point
	}
	edge := func(subject string) gfx.Point {
		row, bounds := find(subject)
		for _, element := range row.PrintElements {
			if element.Position == row.Lane && element.Direction == "down" {
				if row.HoverChain == 0 || element.HoverChain != row.HoverChain {
					t.Fatalf("Git graph projection for %q returned hoverChain %d for the commit and %d for its outgoing edge; want the same nonzero chain", subject, row.HoverChain, element.HoverChain)
				}
				x0, y0, x1, y1 := m.line(element)
				return gfx.Point{X: bounds.X + x0 + (x1-x0)*.7, Y: bounds.Y + y0 + (y1-y0)*.7}
			}
		}
		t.Fatalf("Git Log is missing the outgoing edge of %q", subject)
		return gfx.Point{}
	}
	capture := func(at gfx.Point) *image.RGBA {
		if err := h.driver.Move(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
		h.settleChain()
		img, err := session.Image()
		if err != nil {
			t.Fatal(err)
		}
		return img
	}
	hoverAt := edge("left newest")
	_, hoveredRow := find("left newest")
	// Keep the same row hover background when moving between the graph and text.
	away := gfx.Point{X: hoveredRow.X + hoveredRow.Width/2, Y: hoverAt.Y}
	before, hovered := capture(away), capture(hoverAt)
	if err := session.Screenshot(filepath.Join(out, screenshot)); err != nil {
		t.Fatal(err)
	}

	changed := func(at gfx.Point, radius float32, first, second *image.RGBA) bool {
		band := image.Rect(
			int(math.Ceil(float64(at.X-radius)*scale)), int(math.Ceil(float64(at.Y-radius)*scale)),
			int(math.Floor(float64(at.X+radius)*scale)), int(math.Floor(float64(at.Y+radius)*scale)),
		)
		if band.Empty() || !band.In(first.Bounds()) || !band.In(second.Bounds()) {
			t.Fatalf("Git graph sample at %+v is outside the screenshot", at)
		}
		for y := band.Min.Y; y < band.Max.Y; y++ {
			for x := band.Min.X; x < band.Max.X; x++ {
				if first.RGBAAt(x, y) != second.RGBAAt(x, y) {
					return true
				}
			}
		}
		return false
	}
	for _, subject := range []string{"left newest", "left oldest"} {
		// Check the dot outline away from the vertical stroke through its center.
		if !changed(nodeSide(subject), 1.5, before, hovered) {
			t.Errorf("inner commit %q did not highlight", subject)
		}
	}
	if !changed(hoverAt, 2, before, hovered) {
		t.Error("the hovered edge did not highlight")
	}
	for _, subject := range []string{"merge branches", "fork"} {
		if changed(node(subject), m.nodeRadius-2, before, hovered) {
			t.Errorf("endpoint marker %q was drawn over by the highlight", subject)
		}
	}
	for _, subject := range []string{"right newest", "right oldest"} {
		if changed(node(subject), m.nodeRadius+1, before, hovered) {
			t.Errorf("neighboring commit %q changed on path hover", subject)
		}
	}
	if changed(edge("right newest"), 2, before, hovered) {
		t.Error("the neighboring path changed on hover")
	}
	after := capture(away)
	if changed(hoverAt, 2, before, after) || changed(nodeSide("left oldest"), 1.5, before, after) {
		t.Error("the path stayed highlighted after the pointer left the graph")
	}
}

// applyGraphHoverFixture labels the named routes in newGraphHoverRepository.
// The fixture keeps the presentation test independent of the linked Core's chain support.
func applyGraphHoverFixture(t *testing.T, log *gitLogState) {
	t.Helper()
	nodes := map[string]int{"left newest": 1, "left oldest": 1, "right newest": 2, "right oldest": 2}
	routes := map[[2]string]int{
		{"merge branches", "left newest"}:  1,
		{"left newest", "left oldest"}:     1,
		{"left oldest", "fork"}:            1,
		{"merge branches", "right newest"}: 2,
		{"right newest", "right oldest"}:   2,
		{"right oldest", "fork"}:           2,
	}
	chains := make(map[string]int, len(routes))
	for i := range log.graph.Rows {
		row := &log.graph.Rows[i]
		commit, _ := log.commit(row.CommitHash)
		row.HoverChain = nodes[commit.Subject]
		for _, edge := range row.ParentEdges {
			parent, _ := log.commit(edge.ParentHash)
			if chain := routes[[2]string{commit.Subject, parent.Subject}]; chain != 0 {
				chains[edge.ID] = chain
			}
		}
	}
	if len(chains) != len(routes) {
		t.Fatalf("hover fixture matched %d of %d routes", len(chains), len(routes))
	}
	for _, row := range log.graph.Rows {
		for i := range row.PrintElements {
			edge := &row.PrintElements[i]
			edge.HoverChain = chains[strings.TrimSuffix(edge.ID, ":"+edge.Direction)]
		}
	}
}

func newGraphHoverRepository(t *testing.T) string {
	t.Helper()
	t.Setenv("GIT_AUTHOR_DATE", "2020-03-04T12:34:00Z")
	t.Setenv("GIT_COMMITTER_DATE", "2020-03-04T12:34:00Z")
	dir := newTestRepository(t)
	commit := func(subject string, parents ...string) string {
		args := []string{"commit-tree", "HEAD^{tree}", "-m", subject}
		for _, parent := range parents {
			args = append(args, "-p", parent)
		}
		return gitRun(t, dir, args...)
	}
	fork := commit("fork", "HEAD")
	leftOld := commit("left oldest", fork)
	leftNew := commit("left newest", leftOld)
	rightOld := commit("right oldest", fork)
	rightNew := commit("right newest", rightOld)
	merge := commit("merge branches", leftNew, rightNew)
	gitRun(t, dir, "update-ref", "HEAD", commit("tip", merge))
	return dir
}
