package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// The menu of a stripe button moves the button before its neighbour or after it in its own
// zone, as the earlier client's tool window buttons did.
func TestStripeButtonMenuMovesTheButtonWithinItsZone(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.settle()
	items := h.app.chrome.items[zoneLeftTop]
	if len(items) < 3 {
		t.Fatalf("the top left zone holds %d buttons, want at least three", len(items))
	}
	first, second := items[0], items[1]
	label := h.app.chrome.catalog[second].label(h.app.text)

	h.rightClickNamed(label)
	h.click(center(h.popupHit(h.shared("native.moveEarlier"))))
	h.settle()
	if got := h.app.chrome.items[zoneLeftTop]; got[0] != second || got[1] != first {
		t.Fatalf("after Move Earlier the zone holds %v, want %d before %d", got, second, first)
	}

	h.rightClickNamed(label)
	h.click(center(h.popupHit(h.shared("native.moveLater"))))
	h.settle()
	if got := h.app.chrome.items[zoneLeftTop]; got[0] != first || got[1] != second {
		t.Fatalf("after Move Later the zone holds %v, want %d before %d", got, first, second)
	}
}

// The header of a tool window hides it from its context menu, as the earlier client's
// Problems tool window header did.
func TestToolWindowHeaderMenuHidesTheToolWindow(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.app.post(func(a *App) { a.reduceChrome(core.SetChromeOpen(itemProblems, true)) })
	h.settle()
	index := catalogIndex[itemProblems]
	if !h.app.chrome.isOpen(index) {
		t.Fatal("the Problems tool window did not open")
	}
	// Each open tool window has a header; the one of Problems names it as its value.
	label := h.app.chrome.catalog[index].label(h.app.text)
	var header gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == h.shared("desktop.panel.header") && hit.Value == label {
			header = hit.Bounds
		}
	}
	if header.Width == 0 {
		t.Fatal("the Problems tool window has no header")
	}
	// The header's empty middle, clear of its title and its buttons.
	h.rightClickAt(gfx.Rect{X: header.X + header.Width/2, Y: header.Y, Width: 1, Height: header.Height})
	h.click(center(h.popupHit(i18n.SharedFormat(h.app.language(), "native.hideToolWindow", map[string]string{"arg1": label}))))
	h.settle()
	if h.app.chrome.isOpen(index) {
		t.Fatal("Hide Tool Window left the Problems tool window open")
	}
}

func TestToolWindowMoveSubmenuUsesCoreLayout(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.rightClickAt(h.button(itemProject))
	h.clickNamed(h.shared("desktop.tools.moveTo"))
	h.clickNamed(stripeZoneMoveText(h.app.language(), zoneRightTop))
	h.settleChain()
	if got := h.app.chrome.zoneOf(catalogIndex[itemProject]); got != zoneRightTop {
		t.Fatalf("move submenu left Project in zone %v", got)
	}
}
