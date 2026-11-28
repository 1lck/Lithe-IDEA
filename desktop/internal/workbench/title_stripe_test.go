package workbench

import (
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// moveChromeTo moves catalog item id to the end of zone z through the kernel, as a drop or the
// Move to submenu does, and paints the result.
func (h *harness) moveChromeTo(id string, z zone) {
	h.t.Helper()
	h.app.post(func(a *App) { a.reduceChrome(core.MoveChrome(id, zoneNames[z], "")) })
	h.settle()
	if got := h.app.chrome.zoneOf(catalogIndex[id]); got != z {
		h.t.Fatalf("%s sits in zone %v, want %v", id, got, z)
	}
}

// The Debug, Search and Settings buttons of the title bar drag onto the left and right tool
// stripes, where they are laid out as stripe buttons, and drag back into the title bar. The
// layout file keeps where they are.
func TestTitleButtonsDragOntoTheStripesAndBack(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	right := h.app.chrome.zoneRects[zoneRightTop]
	h.drag(center(h.button(itemTitleSettings)), gfx.Point{X: right.X + right.Width/2, Y: right.Y + right.Height - 2})
	h.settle()
	if got := h.zoneItems(zoneRightTop); !slices.Equal(got, []string{itemBuild, itemAgents, itemNotifications, itemTitleSettings}) {
		t.Fatalf("top right zone = %v, want the settings button after the notifications button", got)
	}
	if got := h.zoneItems(zoneTitle); slices.Contains(got, itemTitleSettings) {
		t.Fatalf("title bar = %v still holds the settings button", got)
	}
	settings := h.button(itemTitleSettings)
	notifications := h.button(itemNotifications)
	if settings.Width != 30 || settings.Height != 30 || settings.X != notifications.X || settings.Y-notifications.Y != 40 {
		t.Fatalf("the settings button is at %+v, want 30x30, 40 below the notifications button at %+v", settings, notifications)
	}

	// The empty split group of the left stripe opens up while a title button is dragged, as it
	// does for a stripe button, so the button can be dropped there.
	from := center(h.button(itemTitleSearch))
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("drag: %v", err)
		}
	}
	must(h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary))
	must(h.driver.Move(from.X, from.Y+2*dragThreshold))
	left := h.app.chrome.zoneRects[zoneLeftBottom]
	if left.Height < chromeToolButton {
		t.Fatalf("the empty left bottom zone is %v high while the search button is dragged, want at least a button", left.Height)
	}
	to := center(left)
	must(h.driver.Move(to.X/2+from.X/2, to.Y/2+from.Y/2))
	must(h.driver.Move(to.X, to.Y))
	must(h.driver.Release(to.X, to.Y, gfx.PointerButtonPrimary))
	h.settle()
	if got := h.zoneItems(zoneLeftBottom); !slices.Equal(got, []string{itemTitleSearch}) {
		t.Fatalf("bottom left stripe zone = %v, want the search button", got)
	}
	var saved core.ChromeLayout
	if _, err := h.store.Load(layoutFile, &saved); err != nil ||
		!slices.Contains(saved.Placements, core.Placement{ID: itemTitleSettings, Zone: core.ZoneRightTop}) ||
		!slices.Contains(saved.Placements, core.Placement{ID: itemTitleSearch, Zone: core.ZoneLeftBottom}) {
		t.Fatalf("saved placements = %v, %v; want settings at the top right and search at the bottom left", saved.Placements, err)
	}

	first := h.button(itemRunConfig)
	h.drag(center(h.button(itemTitleSettings)), gfx.Point{X: first.X + 2, Y: first.Y + first.Height/2})
	h.settle()
	if got := h.zoneItems(zoneTitle); len(got) == 0 || got[0] != itemTitleSettings {
		t.Fatalf("title bar = %v, want the settings button back first", got)
	}
	if got := h.zoneItems(zoneRightTop); !slices.Equal(got, []string{itemBuild, itemAgents, itemNotifications}) {
		t.Fatalf("top right zone = %v, want the settings button gone", got)
	}
	if settings := h.button(itemTitleSettings); settings.Y >= titleBarHeight {
		t.Fatalf("the settings button is at %+v, want it back in the title bar", settings)
	}
}

// Run stays a title bar button: it does not drag onto a stripe and has no Move to menu.
func TestTitleRunStaysInTheTitleBar(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	h.drag(center(h.button(itemTitleRun)), center(h.app.chrome.zoneRects[zoneLeftTop]))
	h.settle()
	if got := h.app.chrome.zoneOf(catalogIndex[itemTitleRun]); got != zoneTitle {
		t.Fatalf("the run button moved to zone %v, want it to stay in the title bar", got)
	}
	h.rightClickAt(h.button(itemTitleRun))
	if h.hasPopupItem(h.shared("desktop.tools.moveTo")) {
		t.Fatal("the run button offers Move to")
	}
}

// The menu of a title bar button that may sit on a stripe moves it onto one. On the stripe its
// menu moves it on or back to the title bar, but offers no Hide Entry: the button cannot be
// hidden there either.
func TestTitleButtonMenuMovesItOntoAStripeAndBack(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	h.rightClickAt(h.button(itemTitleDebug))
	if h.hasPopupItem(h.shared("desktop.tools.moveToTitleBar")) {
		t.Fatal("the menu of the debug button in the title bar offers Move to Title Bar")
	}
	h.clickNamed(h.shared("desktop.tools.moveTo"))
	h.clickNamed(stripeZoneMoveText(h.app.language(), zoneBottomRight))
	h.settleChain()
	if got := h.zoneItems(zoneBottomRight); !slices.Equal(got, []string{itemBackground, itemTitleDebug}) {
		t.Fatalf("bottom right zone = %v, want the debug button after the background button", got)
	}

	h.rightClickAt(h.button(itemTitleDebug))
	if h.hasPopupItem(h.shared("native.hideEntry")) {
		t.Fatal("the menu of the debug button on a stripe offers Hide Entry")
	}
	if !h.hasPopupItem(h.shared("desktop.tools.moveTo")) {
		t.Fatal("the menu of the debug button on a stripe offers no Move to")
	}
	h.click(center(h.popupHit(h.shared("desktop.tools.moveToTitleBar"))))
	h.settleChain()
	if got := h.zoneItems(zoneTitle); len(got) == 0 || got[len(got)-1] != itemTitleDebug {
		t.Fatalf("title bar = %v, want the debug button back at the end", got)
	}
	if got := h.zoneItems(zoneBottomRight); !slices.Equal(got, []string{itemBackground}) {
		t.Fatalf("bottom right zone = %v, want the debug button gone", got)
	}
}

// The settings button on a stripe opens the settings menu beside it, on the inner side, and
// takes the open look of a stripe button while the menu is open; a second press closes it.
func TestSettingsOnAStripeOpensItsMenuBesideIt(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.moveChromeTo(itemTitleSettings, zoneRightBottom)

	gear := h.button(itemTitleSettings)
	h.click(center(gear))
	h.settle()
	if !h.app.title.gearOpen {
		t.Fatal("the settings button on a stripe did not open its menu")
	}
	for _, label := range []string{h.app.text.Title.Preferences, h.app.text.Title.Plugins, h.app.text.Title.LogsAndDiagnostics, h.app.text.Title.ThemeMenu, h.app.text.Title.Keymap} {
		if !h.shows(label) {
			t.Fatalf("the settings menu does not show %q", label)
		}
	}
	row := h.hitLabeled(h.app.text.Title.Preferences)
	if row.Right() > gear.X {
		t.Fatalf("the Settings… row is at %+v, want it left of the button at %+v", row, gear)
	}

	h.click(center(gear))
	h.settle()
	if h.app.title.gearOpen {
		t.Fatal("a second press on the settings button left its menu open")
	}
}

// Search and Debug do on a stripe what they do in the title bar, name themselves in the tip
// of a stripe button and log the press as one on a button rather than the toolbar.
func TestSearchAndDebugOnAStripeDoTheirWork(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	h.open(t.TempDir())
	h.moveChromeTo(itemTitleSearch, zoneLeftTop)
	h.moveChromeTo(itemTitleDebug, zoneLeftTop)

	keys := h.app.settings.Keymap.Label("search.everywhere")
	tip := i18n.SharedFormat(h.app.language(), "desktop.tools.withShortcut", map[string]string{"name": h.app.text.Title.Search, "keys": keys})
	search := h.button(itemTitleSearch)
	at := center(search)
	if err := h.driver.Move(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	tips := h.tooltips()
	if len(tips) != 1 || tips[0].Value != tip || tips[0].Bounds.X < search.Right() {
		t.Fatalf("resting on the search button on the left stripe shows the tips %+v, want only %q right of %+v", tips, tip, search)
	}

	h.click(at)
	h.settle()
	if !h.app.everywhereView.open || h.driver.Snapshot().Focused != everywhereQueryID {
		t.Fatal("the search button on a stripe did not open Search Everywhere with its query focused")
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()

	h.click(center(h.button(itemTitleDebug)))
	h.settleChain()
	if !h.app.chrome.isOpen(catalogIndex[itemDebug]) {
		t.Fatal("the debug button on a stripe did not open the Debug tool window")
	}
	for _, action := range []string{"workspace.searchEverywhere.open", "title.debug"} {
		if got := performedSurfaces(logger, action); !slices.Equal(got, []string{string(surfaceButton)}) {
			t.Errorf("%s was logged from %v, want once from a button", action, got)
		}
	}
}

// performedSurfaces is the surface of every logged performance of action, in order.
func performedSurfaces(log *treeRecordingLog, action string) []string {
	log.mu.Lock()
	defer log.mu.Unlock()
	var surfaces []string
	for _, event := range log.events {
		if event.Event == "app.action.performed" && event.Fields["action"] == action {
			surface, _ := event.Fields["surface"].(string)
			surfaces = append(surfaces, surface)
		}
	}
	return surfaces
}
