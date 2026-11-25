package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
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

// A context menu belongs to its target. Declaring a closed menu must not give
// the next spacer or control a name left over from the target's catalog key.
func TestWorkbenchContextMenusKeepButtonIdentityAcrossRepaints(t *testing.T) {
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		t.Run(look.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": look.theme}); err != nil {
				t.Fatal(err)
			}
			h := newHarnessWithOptions(t, Options{Kernel: core.NewClient(), Store: prefs, Languages: []string{look.language}})
			h.open(t.TempDir())
			h.settleChain()
			label := h.app.chrome.catalog[catalogIndex[itemProject]].label(h.app.text)
			before := h.pageHit(label).ID
			for _, width := range []int{1000, 1280} {
				if err := h.driver.Resize(width, 800); err != nil {
					t.Fatal(err)
				}
				h.rightClickAt(h.button(itemProject))
				if !h.hasPopupItem(h.shared("native.hideEntry")) {
					t.Fatal("the Project button's context menu did not open")
				}
				if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
					t.Fatal(err)
				}
				if got := h.pageHit(label).ID; got != before {
					t.Fatalf("Project identity changed after repaint: %v, want %v", got, before)
				}
			}
		})
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

// A hidden stripe button is listed under the "…" button, which starts as the last button of
// the left stripe's top group, as the earlier client and IDEA list it: a click on its row puts
// the button back where it was and opens its tool window. The "…" button is there only while
// a button is hidden.
func TestHiddenStripeButtonIsListedUnderTheEllipsisAndComesBack(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	more := h.shared("native.toolWindows")
	if _, shown := h.findPageHit(more); shown {
		t.Fatal("the stripe shows the hidden tool windows button with nothing hidden")
	}
	commit := catalogIndex[itemCommit]
	before := slices.Clone(h.app.chrome.items[zoneLeftTop])
	label := h.app.chrome.catalog[commit].label(h.app.text)

	h.rightClickAt(h.button(itemCommit))
	h.click(center(h.popupHit(h.shared("native.hideEntry"))))
	h.settle()
	if slices.Contains(h.app.chrome.items[zoneLeftTop], commit) || !h.app.chrome.isHidden(commit) {
		t.Fatalf("after Hide Entry the top left zone shows %v, want Commit hidden", h.app.chrome.items[zoneLeftTop])
	}
	if got := h.app.chrome.zoneOf(commit); got != zoneLeftTop {
		t.Fatalf("hidden Commit sits in zone %v, want it to keep the top left zone", got)
	}
	if r := h.app.chrome.rects[commit]; r.Width != 0 {
		t.Fatalf("hidden Commit is still laid out at %v", r)
	}
	var saved core.ChromeLayout
	if _, err := h.store.Load(layoutFile, &saved); err != nil || !slices.Equal(saved.Hidden, []string{itemCommit}) {
		t.Fatalf("saved hidden = %q, %v; want [commit]", saved.Hidden, err)
	}

	// The "…" button is laid out as the last button of the top group and, as they do, names
	// itself in a tip on the stripe's inner side.
	shown := h.app.chrome.items[zoneLeftTop]
	if h.app.chrome.catalog[shown[len(shown)-1]].id != itemToolWindows {
		t.Fatalf("the top left zone shows %v, want the hidden tool windows button last", h.zoneItems(zoneLeftTop))
	}
	last := h.button(h.app.chrome.catalog[shown[len(shown)-2]].id)
	ellipsis := h.pageHit(more).Bounds
	if ellipsis != h.button(itemToolWindows) {
		t.Fatalf("the hidden tool windows control is at %+v, want it over its stripe button at %+v", ellipsis, h.button(itemToolWindows))
	}
	if ellipsis.Width != 30 || ellipsis.Height != 30 || ellipsis.X != last.X || ellipsis.Y-last.Y != 40 {
		t.Fatalf("the hidden tool windows button is at %+v, want 30x30, 40 below the last top button at %+v", ellipsis, last)
	}
	at := center(ellipsis)
	if err := h.driver.Move(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if tips := h.tooltips(); len(tips) != 1 || tips[0].Value != more || tips[0].Bounds.X < ellipsis.Right() {
		t.Fatalf("resting on the hidden tool windows button shows the tips %+v, want only %q on its right", tips, more)
	}

	h.clickNamed(more)
	if !h.app.hiddenListOpen {
		t.Fatal("the hidden tool windows button did not open its list")
	}
	if tips := h.tooltips(); len(tips) != 0 {
		t.Fatalf("the open list of hidden tool windows is covered by the tips %+v", tips)
	}
	h.click(center(h.popupHit(label)))
	h.settle()
	if h.app.chrome.isHidden(commit) || !slices.Equal(h.app.chrome.items[zoneLeftTop], before) {
		t.Fatalf("after its row was clicked the zone shows %v, want %v", h.app.chrome.items[zoneLeftTop], before)
	}
	if !h.app.chrome.isOpen(commit) {
		t.Fatal("the row of a hidden button did not open its tool window")
	}
	if h.app.hiddenListOpen {
		t.Fatal("the list stayed open after a row was chosen")
	}
	if _, shown := h.findPageHit(more); shown {
		t.Fatal("the hidden tool windows button stayed with nothing hidden")
	}
}

// Hiding the button of an open tool window closes it. A shortcut still opens the window of a
// hidden button, and then the "…" button takes the open look; Unhide in the row's context
// menu only puts the button back.
func TestUnhidePutsTheButtonBackWithoutTouchingItsToolWindow(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	project := catalogIndex[itemProject]
	label := h.app.chrome.catalog[project].label(h.app.text)
	if !h.app.chrome.isOpen(project) {
		t.Fatal("the Project tool window is not open by default")
	}
	h.rightClickAt(h.button(itemProject))
	h.click(center(h.popupHit(h.shared("native.hideEntry"))))
	h.settle()
	if h.app.chrome.isOpen(project) || !h.app.chrome.isHidden(project) {
		t.Fatal("Hide Entry left the Project tool window open or its button shown")
	}

	more := h.shared("native.toolWindows")
	if h.pageHit(more).Selected {
		t.Fatal("the hidden tool windows button looks open with every hidden window closed")
	}
	h.app.post(func(a *App) { a.reduceChrome(core.SetChromeOpen(itemProject, true)) })
	h.settle()
	if !h.app.chrome.isOpen(project) || !h.app.chrome.isHidden(project) {
		t.Fatal("opening the tool window of a hidden button did not keep the button hidden")
	}
	if !h.pageHit(more).Selected {
		t.Fatal("the hidden tool windows button does not show that a hidden window is open")
	}

	h.clickNamed(more)
	h.rightClickAt(h.popupHit(label))
	h.click(center(h.popupHit(h.shared("mac.workbench.unhide"))))
	h.settle()
	if h.app.chrome.isHidden(project) || h.app.chrome.items[zoneLeftTop][0] != project {
		t.Fatalf("after Unhide the top left zone shows %v, want Project first", h.app.chrome.items[zoneLeftTop])
	}
	if !h.app.chrome.isOpen(project) {
		t.Fatal("Unhide closed the Project tool window")
	}
	if h.app.hiddenListOpen {
		t.Fatal("the list stayed open after its last button came back")
	}
}

// The arrangement keeps a hidden button's zone and leaves it out of the zone's shown buttons;
// the tool window of a hidden button still opens in its zone's slot.
func TestChromeStateKeepsTheZoneOfAHiddenButton(t *testing.T) {
	c := newChromeState()
	layout := defaultLayout()
	for i, placement := range layout.Placements {
		if placement.ID == itemTerminal {
			layout.Placements[i].Zone = core.ZoneRightBottom
		}
	}
	layout.Open = append(layout.Open, itemTerminal)
	layout.Hidden = []string{itemTerminal}
	c.apply(layout)
	terminal := c.index[itemTerminal]
	if !c.isHidden(terminal) || !slices.Equal(c.hidden, []int{terminal}) {
		t.Fatalf("hidden = %v, want [%d]", c.hidden, terminal)
	}
	if got := c.zoneOf(terminal); got != zoneRightBottom {
		t.Fatalf("zone of the hidden terminal = %v, want right bottom", got)
	}
	if len(c.items[zoneRightBottom]) != 0 {
		t.Fatalf("right bottom shows %v, want no buttons", c.items[zoneRightBottom])
	}
	if c.open[slotRightBottom] != terminal || !c.hiddenOpen() {
		t.Fatalf("open slots = %v, want the hidden terminal in the right bottom slot", c.open)
	}
}

// The "…" button moves like the other stripe buttons. Dragged to the end of the right stripe,
// it stays there, in the saved layout as well, and opens its list on that stripe's inner side,
// rising from it. With nothing hidden it is gone, and it comes back where the user left it.
func TestTheEllipsisButtonDragsToAnotherStripeZone(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	more := h.shared("native.toolWindows")
	commit := catalogIndex[itemCommit]
	label := h.app.chrome.catalog[commit].label(h.app.text)
	h.rightClickAt(h.button(itemCommit))
	h.click(center(h.popupHit(h.shared("native.hideEntry"))))
	h.settle()

	target := h.app.chrome.zoneRects[zoneBottomRight]
	h.drag(center(h.button(itemToolWindows)), gfx.Point{X: target.X + target.Width/2, Y: target.Y + target.Height - 2})
	h.settle()
	if got := h.zoneItems(zoneBottomRight); !slices.Equal(got, []string{itemBackground, itemToolWindows}) {
		t.Fatalf("bottom right zone = %v, want the hidden tool windows button after the background button", got)
	}
	if got := h.zoneItems(zoneLeftTop); slices.Contains(got, itemToolWindows) {
		t.Fatalf("top left zone = %v still holds the hidden tool windows button", got)
	}
	var saved core.ChromeLayout
	if _, err := h.store.Load(layoutFile, &saved); err != nil || !slices.Contains(saved.Placements, core.Placement{ID: itemToolWindows, Zone: core.ZoneBottomRight}) {
		t.Fatalf("saved placements = %v, %v; want the hidden tool windows button at the bottom right", saved.Placements, err)
	}

	ellipsis := h.pageHit(more).Bounds
	if ellipsis != h.button(itemToolWindows) {
		t.Fatalf("the hidden tool windows control is at %+v, want it over its stripe button at %+v", ellipsis, h.button(itemToolWindows))
	}
	h.clickNamed(more)
	if !h.app.hiddenListOpen {
		t.Fatal("the moved hidden tool windows button did not open its list")
	}
	row := h.popupHit(label)
	if row.Right() > ellipsis.X || row.Bottom() > ellipsis.Bottom() {
		t.Fatalf("the row of hidden Commit is at %+v, want it left of the button at %+v and not below it", row, ellipsis)
	}

	h.click(center(row))
	h.settle()
	if h.app.chrome.isHidden(commit) {
		t.Fatal("the row of hidden Commit did not bring its button back")
	}
	if _, shown := h.findPageHit(more); shown {
		t.Fatal("the hidden tool windows button stayed with nothing hidden")
	}
	if got := h.app.chrome.zoneOf(catalogIndex[itemToolWindows]); got != zoneBottomRight {
		t.Fatalf("with nothing hidden the hidden tool windows button belongs to zone %v, want the bottom right", got)
	}
	h.rightClickAt(h.button(itemCommit))
	h.click(center(h.popupHit(h.shared("native.hideEntry"))))
	h.settle()
	if got := h.zoneItems(zoneBottomRight); !slices.Equal(got, []string{itemBackground, itemToolWindows}) {
		t.Fatalf("bottom right zone = %v after another hide, want the hidden tool windows button back after the background button", got)
	}
}

// The menu of the "…" button moves it as the menu of a stripe button does, but offers no Hide
// Entry: the button is the way back to the hidden ones.
func TestTheEllipsisButtonMenuMovesItButCannotHideIt(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.rightClickAt(h.button(itemCommit))
	h.click(center(h.popupHit(h.shared("native.hideEntry"))))
	h.settle()

	h.rightClickAt(h.button(itemToolWindows))
	if h.hasPopupItem(h.shared("native.hideEntry")) {
		t.Fatal("the menu of the hidden tool windows button offers Hide Entry")
	}
	h.click(center(h.popupHit(h.shared("native.moveEarlier"))))
	h.settle()
	items := h.zoneItems(zoneLeftTop)
	if at := slices.Index(items, itemToolWindows); at != len(items)-2 {
		t.Fatalf("after Move Earlier the top left zone holds %v, want the hidden tool windows button before the last", items)
	}

	h.rightClickAt(h.button(itemToolWindows))
	h.clickNamed(h.shared("desktop.tools.moveTo"))
	h.clickNamed(stripeZoneMoveText(h.app.language(), zoneRightTop))
	h.settleChain()
	if got := h.zoneItems(zoneRightTop); !slices.Equal(got, []string{itemBuild, itemNotifications, itemToolWindows}) {
		t.Fatalf("after Move To the top right zone holds %v, want the hidden tool windows button last", got)
	}
	h.app.post(func(a *App) { a.hideEntry(catalogIndex[itemToolWindows]) })
	h.settle()
	if h.app.chrome.isHidden(catalogIndex[itemToolWindows]) {
		t.Fatal("the hidden tool windows button was hidden")
	}
}

// The "…" button is among the shown buttons of its zone only while another button is hidden,
// so a drag or Move Later never stops at it while it is not drawn, and a layout that hides it,
// edited by hand, still shows it.
func TestChromeStateShowsTheEllipsisOnlyWhileAButtonIsHidden(t *testing.T) {
	c := newChromeState()
	more := c.index[itemToolWindows]
	layout := defaultLayout()
	c.apply(layout)
	if slices.Contains(c.items[zoneLeftTop], more) {
		t.Fatalf("with nothing hidden the top left zone shows %v, want no hidden tool windows button", c.items[zoneLeftTop])
	}
	if got := c.zoneOf(more); got != zoneLeftTop {
		t.Fatalf("the hidden tool windows button belongs to zone %v, want the top left", got)
	}

	layout.Hidden = []string{itemToolWindows}
	c.apply(layout)
	if c.isHidden(more) || len(c.hidden) != 0 || slices.Contains(c.items[zoneLeftTop], more) {
		t.Fatalf("a layout hiding only the hidden tool windows button leaves hidden = %v and top left %v, want neither", c.hidden, c.items[zoneLeftTop])
	}

	layout.Hidden = []string{itemToolWindows, itemCommit}
	c.apply(layout)
	items := c.items[zoneLeftTop]
	if c.isHidden(more) || !slices.Equal(c.hidden, []int{c.index[itemCommit]}) || items[len(items)-1] != more {
		t.Fatalf("with Commit hidden, hidden = %v and top left = %v, want only Commit hidden and the button last", c.hidden, items)
	}
}

// A layout saved before the "…" button was in the catalog, still holding the Updates button
// that was taken out, loses that button and gets the "…" button at the end of the left
// stripe's top group, where it used to be drawn.
func TestALayoutSavedBeforeTheEllipsisMovedPutsItAfterTheTopGroup(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var old core.ChromeLayout
	for _, placement := range defaultLayout().Placements {
		if placement.ID == itemToolWindows {
			continue
		}
		old.Placements = append(old.Placements, placement)
		if placement.ID == itemBackground {
			old.Placements = append(old.Placements, core.Placement{ID: "updates", Zone: core.ZoneBottomRight})
		}
	}
	old.Open = []string{itemProject}
	old.Hidden = []string{itemCommit}
	if err := store.At(dir).Save(layoutFile, old); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"zh-Hans"}})
	h.open(t.TempDir())
	if got := h.zoneItems(zoneBottomRight); !slices.Equal(got, []string{itemBackground}) {
		t.Fatalf("bottom right zone = %v, want only the background button", got)
	}
	if got := h.zoneItems(zoneLeftTop); !slices.Equal(got, []string{itemProject, itemStructure, itemFind, itemToolWindows}) {
		t.Fatalf("top left zone = %v, want the hidden tool windows button after the top group", got)
	}
	h.pageHit(h.shared("native.toolWindows"))
}
