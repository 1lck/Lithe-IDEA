package workbench

import (
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func TestGraphHoverResumesWhenMouseIsReleased(t *testing.T) {
	h, p, _ := logWithTwoCommits(t)
	h.settleChain()
	const chain = 7
	first := &p.log.graph.Rows[0]
	first.Lane = 0
	first.PrintElements = []core.GraphElement{{Direction: "down", HoverChain: chain}}
	check := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	check(h.driver.Paint())
	hover := &h.app.logView.graphHover
	if len(hover.rows) == 0 || hover.rows[0].index != 0 {
		t.Fatal("the first graph row is not laid out")
	}
	row := hover.rows[0].rect
	metrics := newGraphMetrics(hover.scale)
	at := gfx.Point{X: row.X + metrics.laneCenter, Y: row.Y + metrics.rowCenter + 8}
	wantChain := func(want int) {
		t.Helper()
		if hover.chain != want {
			t.Errorf("highlighted chain = %d, want %d", hover.chain, want)
		}
	}

	check(h.driver.Move(at.X, at.Y))
	wantChain(chain)
	check(h.driver.Press(at.X, at.Y, gfx.PointerButtonPrimary))
	check(h.driver.Move(at.X+12, at.Y))
	check(h.driver.Move(at.X, at.Y))
	wantChain(0)
	check(h.driver.Release(at.X, at.Y, gfx.PointerButtonPrimary))
	wantChain(chain)

	check(h.driver.Press(at.X, at.Y, gfx.PointerButtonPrimary))
	check(h.driver.Leave())
	check(h.driver.Release(-1, at.Y, gfx.PointerButtonPrimary))
	wantChain(0)
	if hover.inside {
		t.Error("releasing after leaving the window kept the graph pointer inside")
	}

	check(h.driver.TouchDown(1, at.X, at.Y))
	check(h.driver.Advance(150 * time.Millisecond))
	wantChain(0)
	check(h.driver.TouchUp(1, at.X, at.Y))
	wantChain(0)
}
