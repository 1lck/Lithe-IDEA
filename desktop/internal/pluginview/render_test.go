package pluginview

import (
	"encoding/json"
	"errors"
	"strconv"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// viewDriver draws a session's view as a tool window body in a headless window and
// addresses its controls by their accessible names, as a user would.
type viewDriver struct {
	t           *testing.T
	b           *backend
	s           *Session
	driver      *app.Driver
	invalidator *app.Invalidator
}

// drawView opens a session whose plugin answers every event with view, takes the open
// answer and draws it.
func drawView(t *testing.T, view string) *viewDriver {
	t.Helper()
	b := newBackend(t)
	b.answer = func(map[string]any) (json.RawMessage, bool, error) { return json.RawMessage(view), true, nil }
	s := b.session()
	show(s)
	b.answered(s)
	if !s.Drawn() {
		t.Fatalf("the open answer was not drawn: %v", s.Err())
	}
	return paintView(t, b, s)
}

// paintView draws the session as a tool window body in a headless window 480 points wide.
func paintView(t *testing.T, b *backend, s *Session) *viewDriver {
	t.Helper()
	theme := ui.LightTheme()
	background := theme.Background
	invalidator := &app.Invalidator{}
	host := &Host{Palette: testPalette(false), Language: i18n.English, Icon: HostIcon}
	page := ui.NewPage(ui.PageConfig{
		View:        func(c ui.C) { Draw(c, s, host, true) },
		Theme:       &theme,
		Background:  &background,
		Invalidator: invalidator,
		// Every client window the view is drawn in turns these on.
		EllipsisTooltips: true,
	})
	driver, err := app.NewDriver(ui.Configure(page, app.Config{Width: 480, Height: 400, Invalidator: invalidator}), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(driver.Close)
	return &viewDriver{t: t, b: b, s: s, driver: driver, invalidator: invalidator}
}

// repaint paints the frame again after the session changed outside a paint, as the wake
// the window gets for an answer does.
func (d *viewDriver) repaint() {
	d.t.Helper()
	d.invalidator.Invalidate()
	if err := d.driver.Pump(); err != nil {
		d.t.Fatal(err)
	}
}

// click clicks the middle of the front-most control labeled label and paints again, so
// the work the click left for after the paint runs.
func (d *viewDriver) click(label string) {
	d.t.Helper()
	d.clickCount(label, 1)
}

func (d *viewDriver) clickCount(label string, clicks int) {
	d.t.Helper()
	hits := d.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		hit := hits[i]
		if hit.Label != label || hit.IsLabel || hit.Backdrop || hit.ID.IsZero() {
			continue
		}
		if err := d.driver.ClickCount(hit.Bounds.X+hit.Bounds.Width/2, hit.Bounds.Y+hit.Bounds.Height/2, clicks); err != nil {
			d.t.Fatal(err)
		}
		if err := d.driver.Pump(); err != nil {
			d.t.Fatal(err)
		}
		return
	}
	d.t.Fatalf("no control labeled %q", label)
}

// shows reports whether a label of the frame reads exactly text.
func (d *viewDriver) shows(text string) bool {
	for _, label := range d.driver.Snapshot().Labels {
		if label.Value == text {
			return true
		}
	}
	return false
}

// sent runs the one call the clicks queued and is the event it carried.
func (d *viewDriver) sent() map[string]any {
	d.t.Helper()
	if len(d.b.pending) != 1 {
		d.t.Fatalf("%d calls waiting, want one", len(d.b.pending))
	}
	d.b.answered(d.s)
	return d.b.last()
}

func TestDrawSendsClickForAButtonAndDrawsItsText(t *testing.T) {
	d := drawView(t, `[
		{"type": "label", "id": "count", "text": "3 modules"},
		{"type": "row", "children": [
			{"type": "button", "id": "sync", "text": "Sync", "tone": "primary", "icon": "refresh"},
			{"type": "button", "id": "later", "text": "Later", "enabled": false}
		]}
	]`)
	if !d.shows("3 modules") {
		t.Fatal("the label is not drawn")
	}
	d.click("Later")
	if len(d.b.pending) != 0 {
		t.Fatal("a disabled button sent an event")
	}
	d.click("Sync")
	if event := d.sent(); event["event"] != "click" || event["node"] != "sync" {
		t.Fatalf("event = %v, want click on sync", event)
	}
}

func TestDrawSendsChangeForAToggleWithItsValue(t *testing.T) {
	d := drawView(t, `[{"type": "toggle", "id": "watch", "label": "Watch files", "value": false}]`)
	d.click("Watch files")
	if event := d.sent(); event["event"] != "change" || event["node"] != "watch" || event["value"] != true {
		t.Fatalf("event = %v, want change of watch to true", event)
	}
}

func TestDrawSendsChangeForASegmentedChoice(t *testing.T) {
	d := drawView(t, `[{"type":"segmented","id":"mode","label":"Mode","value":"first","options":[
		{"value":"first","label":"First"},{"value":"second","label":"Second"}
	]}]`)
	d.click("Second")
	if event := d.sent(); event["event"] != "change" || event["node"] != "mode" || event["value"] != "second" {
		t.Fatalf("event = %v, want change of mode to second", event)
	}
}

func TestDrawSendsSelectOnceAndActivateForATreeItem(t *testing.T) {
	d := drawView(t, `[{"type": "tree", "id": "modules", "label": "Modules", "items": [
		{"id": "core", "label": "core", "detail": "3 files", "icon": "plugin"},
		{"id": "app", "label": "app"}
	]}]`)
	if !d.shows("3 files") {
		t.Fatal("the item's detail is not drawn")
	}
	d.click("core")
	if event := d.sent(); event["event"] != "select" || event["node"] != "modules" || event["item"] != "core" {
		t.Fatalf("event = %v, want select of core", event)
	}
	d.repaint()
	d.click("core")
	if len(d.b.pending) != 0 {
		t.Fatal("selecting the selected item sent select again")
	}
	d.repaint()
	d.clickCount("app", 2)
	if event := d.sent(); event["event"] != "select" || event["item"] != "app" {
		t.Fatalf("a double click first sent %v, want select of app", event)
	}
	if event := d.sent(); event["event"] != "activate" || event["node"] != "modules" || event["item"] != "app" {
		t.Fatalf("a double click then sent %v, want activate of app", event)
	}
}

// hitOf is the front-most control labeled label, ok false for none drawn.
func (d *viewDriver) hitOf(label string) (gfx.Rect, bool) {
	hits := d.driver.Snapshot().Hits
	for i := len(hits) - 1; i >= 0; i-- {
		if hit := hits[i]; hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			return hit.Bounds, true
		}
	}
	return gfx.Rect{}, false
}

// nestedTreeView is a section holding a tree of count items and a toggle under it.
func nestedTreeView(count int) string {
	items := make([]map[string]any, count)
	for i := range items {
		items[i] = map[string]any{"id": "m" + strconv.Itoa(i), "label": "module " + strconv.Itoa(i)}
	}
	view, _ := json.Marshal([]map[string]any{{"type": "section", "title": "Modules", "children": []map[string]any{
		{"type": "tree", "id": "modules", "label": "Modules", "items": items},
		{"type": "toggle", "id": "watch", "label": "Watch", "value": true},
	}}})
	return string(view)
}

// A tree in a section sits in the scrolling body: it takes the height of its rows, so every
// row shows and what follows it sits right under it, up to treeRows rows, past which it
// scrolls by itself.
func TestDrawGivesANestedTreeTheHeightOfItsRows(t *testing.T) {
	d := drawView(t, nestedTreeView(4))
	last, ok := d.hitOf("module 3")
	if !ok {
		t.Fatal("the last row of a short nested tree is not shown")
	}
	toggle, ok := d.hitOf("Watch")
	if !ok {
		t.Fatal("the toggle under the tree is not shown")
	}
	if gap := toggle.Y - (last.Y + last.Height); gap < 0 || gap > 20 {
		t.Fatalf("the toggle is %v under the last row, want right under it", gap)
	}

	d = drawView(t, nestedTreeView(treeRows+8))
	if _, ok := d.hitOf("module " + strconv.Itoa(treeRows-1)); !ok {
		t.Fatalf("a long nested tree does not show %d rows", treeRows)
	}
	if _, ok := d.hitOf("module " + strconv.Itoa(treeRows+1)); ok {
		t.Fatalf("a long nested tree shows more than %d rows instead of scrolling", treeRows)
	}
	if _, ok := d.hitOf("Watch"); !ok {
		t.Fatal("the toggle under a long tree is not shown")
	}
}

func TestDrawShowsTheFailureWithRetry(t *testing.T) {
	d := drawView(t, `[{"type": "button", "id": "sync", "text": "Sync"}]`)
	d.b.answer = func(map[string]any) (json.RawMessage, bool, error) {
		return nil, false, errPluginFailed
	}
	d.click("Sync")
	d.sent()
	d.repaint()
	if !d.shows(i18n.Shared(i18n.English, "desktop.pluginView.failed")) || !d.shows(errPluginFailed.Error()) {
		t.Fatal("the failure and the plugin's own message are not drawn")
	}
	if !d.shows("Sync") {
		t.Fatal("the drawn view went away under the failure")
	}
	d.b.answer = nil
	d.click(i18n.Shared(i18n.English, "desktop.everywhere.retry"))
	if event := d.sent(); event["event"] != "click" || event["node"] != "sync" {
		t.Fatalf("retry sent %v, want the failed click again", event)
	}
}

// errPluginFailed is a backend's own failure, shown untranslated under the host's words.
var errPluginFailed = errors.New("the index is locked")

func TestDrawSendsOpenAndResizeWithTheWidthItsNodesAreLaidOutIn(t *testing.T) {
	b := newBackend(t)
	b.answer = func(map[string]any) (json.RawMessage, bool, error) { return resizeView(), true, nil }
	s := b.session()
	s.Open()
	d := paintView(t, b, s)
	// The window is 480 points wide, and the body pads the nodes by 10 on each side.
	if open := d.sent(); open["event"] != "open" || open["width"] != 460.0 {
		t.Fatalf("event = %v, want open at the width the first paint measured", open)
	}
	d.repaint()
	if err := d.driver.Resize(400, 400); err != nil {
		t.Fatal(err)
	}
	if len(b.pending) != 0 {
		t.Fatal("resize went out before the width settled")
	}
	b.now = b.now.Add(settleDelay)
	d.repaint()
	if resize := d.sent(); resize["event"] != "resize" || resize["width"] != 380.0 {
		t.Fatalf("event = %v, want resize at the new width", resize)
	}
}
