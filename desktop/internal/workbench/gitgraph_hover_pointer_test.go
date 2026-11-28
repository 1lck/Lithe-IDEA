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
	if h.app.sessions.graphPointer.canHover {
		t.Error("releasing after leaving the window kept the graph pointer inside")
	}

	check(h.driver.TouchDown(1, at.X, at.Y))
	check(h.driver.Advance(150 * time.Millisecond))
	wantChain(0)
	check(h.driver.TouchUp(1, at.X, at.Y))
	wantChain(0)
}

func TestGraphHoverUsesCurrentPointerAfterSwitchingProjects(t *testing.T) {
	h, p, _ := logWithTwoCommits(t)
	t.Cleanup(h.disposeTabs)
	sessions := h.app.sessions
	sessions.openTab(t.TempDir())
	h.settleTabs()
	other := sessions.active
	if other == h.app {
		t.Fatal("opening the second project did not create another tab")
	}
	sessions.activate(h.app)
	h.settleTabs()

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
	row := hover.rows[0]
	metrics := newGraphMetrics(hover.scale)
	x, y := row.rect.X+metrics.laneCenter, row.rect.Y+metrics.rowCenter+8
	check(h.driver.Move(x, y))
	if hover.chain != chain {
		t.Fatalf("highlighted chain = %d before switching, want %d", hover.chain, chain)
	}

	// Move onto the same row's metadata while a different project is shown.
	// Switching back must use the window's current pointer even before another move.
	sessions.activate(other)
	check(h.driver.Paint())
	check(h.driver.Move(row.rect.X+row.width+4, y))
	sessions.activate(h.app)
	check(h.driver.Paint())
	if hover.chain != 0 {
		t.Errorf("highlighted chain = %d after switching back over row metadata, want none", hover.chain)
	}

	sessions.activate(other)
	check(h.driver.Paint())
	check(h.driver.Move(x, y))
	sessions.activate(h.app)
	check(h.driver.Paint())
	if hover.chain != chain {
		t.Errorf("highlighted chain = %d after switching back over a graph edge, want %d", hover.chain, chain)
	}
}
