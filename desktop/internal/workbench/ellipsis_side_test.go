package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// cutLabel is the first label of the last frame, among those keep accepts, that shows the start
// of full followed by "…".
func (h *harness) cutLabel(full string, keep func(gfx.Rect) bool) gfx.Rect {
	h.t.Helper()
	for _, label := range h.driver.Snapshot().Labels {
		head, cut := strings.CutSuffix(label.Value, "…")
		if cut && head != "" && strings.HasPrefix(full, head) && keep(label.Bounds) {
			return label.Bounds
		}
	}
	h.t.Fatalf("no label shows %q cut short", full)
	return gfx.Rect{}
}

// restForTip rests the pointer on text long enough for the tooltip delay and returns the text of
// the tooltip's lines joined in order, with the rectangle the lines cover.
func (h *harness) restForTip(text gfx.Rect) (string, gfx.Rect) {
	h.t.Helper()
	at := center(text)
	if err := h.driver.Move(at.X, at.Y); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Advance(time.Second); err != nil {
		h.t.Fatal(err)
	}
	var tip strings.Builder
	var area gfx.Rect
	for i, line := range h.tooltips() {
		tip.WriteString(line.Value)
		if i == 0 {
			area = line.Bounds
			continue
		}
		left, top := min(area.X, line.Bounds.X), min(area.Y, line.Bounds.Y)
		area = gfx.Rect{X: left, Y: top,
			Width:  max(area.Right(), line.Bounds.Right()) - left,
			Height: max(area.Bottom(), line.Bounds.Bottom()) - top}
	}
	return tip.String(), area
}

// expectFullTipOn rests the pointer on text, a label cut short of full, and fails unless its
// tooltip shows full and lies wholly on side of the label.
func (h *harness) expectFullTipOn(side ui.TooltipSide, text gfx.Rect, full string) {
	h.t.Helper()
	got, tip := h.restForTip(text)
	if got != full {
		h.t.Fatalf("the tooltip of the label at %+v shows %q, want %q", text, got, full)
	}
	var beside bool
	switch side {
	case ui.TooltipRight:
		beside = tip.X >= text.Right()
	case ui.TooltipLeft:
		beside = tip.Right() <= text.X
	case ui.TooltipTop:
		beside = tip.Bottom() <= text.Y
	default:
		beside = tip.Y >= text.Bottom()
	}
	if !beside {
		h.t.Fatalf("the tooltip at %+v is not on side %v of the label at %+v", tip, side, text)
	}
}

// deepChangeRepository is a test repository with one more file, committed under dir and then
// modified, so the Commit tool window lists it with dir beside its name.
func deepChangeRepository(t *testing.T, dir string) string {
	t.Helper()
	repo := newTestRepository(t)
	file := filepath.Join(repo, filepath.FromSlash(dir), "Service.java")
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("first\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, repo, "add", ".")
	gitRun(t, repo, "commit", "-m", "service")
	if err := os.WriteFile(file, []byte("second\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return repo
}

// commitDocks are the slots the Commit tool window is docked in to show where each opens the full
// text of a path it cuts short, with the side it opens on. in says whether a point lies in the
// part of the default 1280×800 window the slot takes.
var commitDocks = []struct {
	name string
	zone zone
	side ui.TooltipSide
	in   func(gfx.Point) bool
}{
	{name: "left", zone: zoneLeftTop, side: ui.TooltipRight, in: func(at gfx.Point) bool { return at.X < 1280/3 }},
	{name: "right", zone: zoneRightTop, side: ui.TooltipLeft, in: func(at gfx.Point) bool { return at.X > 1280*2/3 }},
	{name: "bottom", zone: zoneBottomLeft, side: ui.TooltipTop, in: func(at gfx.Point) bool { return at.Y > 800/2 }},
}

// commitDockDir is a directory too long for a row of the Commit tool window in any slot.
var commitDockDir = strings.TrimSuffix(strings.Repeat("deeply-nested-module-directory/", 9), "/")

// openCommitIn opens repo, docks the Commit tool window in zone, opens it and returns the label
// its row shows commitDockDir in, cut short; in says where the slot lies.
func (h *harness) openCommitIn(repo string, zone zone, in func(gfx.Point) bool) gfx.Rect {
	h.t.Helper()
	h.open(repo)
	if zone != zoneLeftTop {
		h.moveChromeTo(itemCommit, zone)
	}
	h.click(center(h.button(itemCommit)))
	h.settle()
	return h.cutLabel(commitDockDir, func(r gfx.Rect) bool { return in(center(r)) })
}

// A tool window opens the full text of a value it cuts short toward the editor: a window docked
// along the left edge to its right, one along the right edge to its left, and one in the bottom
// area above the text, as the tooltips of the stripe buttons open on the inner side.
func TestToolWindowEllipsisTooltipsOpenTowardTheEditor(t *testing.T) {
	for _, dock := range commitDocks {
		t.Run(dock.name, func(t *testing.T) {
			repo := deepChangeRepository(t, commitDockDir)
			h := newHarness(t, gitKernel{core.NewClient()})
			text := h.openCommitIn(repo, dock.zone, dock.in)
			h.expectFullTipOn(dock.side, text, commitDockDir)
		})
	}
}

// The status bar runs along the window's bottom edge, so a crumb of the navigation path it cuts
// short shows its full name above the bar.
func TestStatusBarEllipsisTooltipOpensAbove(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	name := strings.Repeat("LongFileName", 20) + ".txt"
	file := filepath.Join(root, name)
	if err := os.WriteFile(file, []byte("text\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := h.openTree(t, root)
	h.openStatusPathFile(p, file)
	h.settleChain()
	bar := float32(h.driver.Snapshot().Height) - 2*chromeStatusItem
	text := h.cutLabel(name, func(r gfx.Rect) bool { return r.Y > bar })
	h.expectFullTipOn(ui.TooltipTop, text, name)
}
