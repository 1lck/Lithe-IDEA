package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// shiftClock makes the harness's clock advance only when tapShift says so, so the gap
// between two taps is exactly what a test chooses.
func (h *harness) shiftClock() *time.Time {
	clock := time.Date(2026, 11, 11, 9, 0, 0, 0, time.UTC)
	h.app.now = func() time.Time { return clock }
	return &clock
}

// tapShift presses and releases Shift on its own, after advancing clock by gap.
func (h *harness) tapShift(clock *time.Time, gap time.Duration) {
	h.t.Helper()
	*clock = clock.Add(gap)
	if err := h.driver.KeyDown(gfx.KeyShiftLeft, ""); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.KeyUp(gfx.KeyShiftLeft, ""); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
}

// doubleShiftOpens taps Shift twice gap apart and reports whether Search Everywhere
// opened, closing it again.
func (h *harness) doubleShiftOpens(clock *time.Time, gap time.Duration) bool {
	h.t.Helper()
	h.tapShift(clock, time.Second)
	h.tapShift(clock, gap)
	opened := h.app.everywhereView.open
	if opened {
		h.app.closeEverywhere(h.app.project)
		h.settle()
	}
	return opened
}

func TestDoubleShiftOpensSearchEverywhereWhereverTheFocusIs(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("a\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	clock := h.shiftClock()

	if !h.doubleShiftOpens(clock, 100*time.Millisecond) {
		t.Fatal("double Shift with nothing focused did not open Search Everywhere")
	}
	h.app.openFile(h.app.project, filepath.Join(root, "a.txt"))
	h.settle()
	if !h.doubleShiftOpens(clock, 100*time.Millisecond) {
		t.Fatal("double Shift in the editor did not open Search Everywhere")
	}
	if runtime.GOOS == "windows" {
		return
	}
	term := busyTerminal(t, h, "read line")
	if !h.app.chrome.isOpen(catalogIndex[itemTerminal]) {
		h.app.reduceChrome(core.SetChromeOpen(itemTerminal, true))
	}
	h.settle()
	h.click(center(h.topHit(term.hit)))
	if !h.doubleShiftOpens(clock, 100*time.Millisecond) {
		t.Fatal("double Shift in the terminal did not open Search Everywhere")
	}
	h.app.closeTerminal(h.app.project, term.id)
	h.await("the closed terminal", func() bool { return h.app.project.terms.find(term.id) == nil })
}

func TestShiftTapsTooFarApartOrJoinedToAKeyDoNotOpenSearchEverywhere(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	clock := h.shiftClock()

	// Core's limit is 0.35 s between the two releases.
	if h.doubleShiftOpens(clock, 400*time.Millisecond) {
		t.Fatal("two Shift taps 0.4 s apart opened Search Everywhere")
	}
	h.tapShift(clock, time.Second)
	*clock = clock.Add(50 * time.Millisecond)
	for _, step := range []func() error{
		func() error { return h.driver.KeyDown(gfx.KeyShiftLeft, "") },
		func() error { return h.driver.KeyDown(gfx.KeyLeft, "") },
		func() error { return h.driver.KeyUp(gfx.KeyLeft, "") },
		func() error { return h.driver.KeyUp(gfx.KeyShiftLeft, "") },
	} {
		if err := step(); err != nil {
			t.Fatal(err)
		}
	}
	h.settle()
	if h.app.everywhereView.open {
		t.Fatal("a Shift tap and Shift+Left opened Search Everywhere")
	}
}
