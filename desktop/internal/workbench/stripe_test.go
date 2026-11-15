package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// tooltips is the text of every tip the last frame painted, with where it stands.
func (h *harness) tooltips() []app.Label {
	var tips []app.Label
	for _, label := range h.driver.Snapshot().Labels {
		if label.Layer == ui.TooltipLayer {
			tips = append(tips, label)
		}
	}
	return tips
}

// buttonHit is the control laid out over the catalog button id in the last frame.
func (h *harness) buttonHit(id string) gfx.Hit {
	h.t.Helper()
	rect := h.button(id)
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Bounds == rect && !hit.IsLabel && !hit.ID.IsZero() {
			return hit
		}
	}
	h.t.Fatalf("no control covers the %s button", id)
	return gfx.Hit{}
}

// The stripes lay out their buttons as the tool window bars of IntelliJ's New UI do: a
// 30pt button in the middle of the 40pt stripe, one every 40pt down the stripe.
func TestToolStripeButtonsHaveTheToolWindowBarSizes(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	snapshot := h.driver.Snapshot()
	stripes := dragStripeRects(gfx.Rect{Width: float32(snapshot.Width), Height: float32(snapshot.Height)})
	for _, tc := range []struct {
		name string
		side stripeSide
		ids  []string
	}{
		{name: "left", side: stripeLeft, ids: []string{itemProject, itemCommit, itemStructure, itemFind}},
		{name: "right", side: stripeRight, ids: []string{itemBuild, itemNotifications}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stripe := stripes[tc.side]
			if stripe.Width != 40 {
				t.Fatalf("the %s stripe is %v wide, want 40", tc.name, stripe.Width)
			}
			var above gfx.Rect
			for i, id := range tc.ids {
				rect := h.button(id)
				if rect.Width != 30 || rect.Height != 30 {
					t.Errorf("the %s button is %vx%v, want 30x30", id, rect.Width, rect.Height)
				}
				if inset := rect.X - stripe.X; inset != 5 {
					t.Errorf("the %s button stands %v in from the %s stripe's edge, want 5", id, inset, tc.name)
				}
				if i > 0 && rect.Y-above.Y != 40 {
					t.Errorf("the %s button is %v below the one above it, want 40", id, rect.Y-above.Y)
				}
				above = rect
			}
		})
	}
}

// A button that is only an icon names itself in a tip while the pointer rests on it: a
// stripe button's tip opens on the side away from the window edge, a title bar button's below
// it, and the Search tip adds the keys of Search Everywhere, which the button opens. The drag
// hint goes to assistive technology as the description, and no tip covers a button's drag.
func TestIconButtonsNameThemselvesInATipBesideThem(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())

	keys := h.app.settings.Keymap.Label("search.everywhere")
	if keys == "" {
		t.Fatal("Search Everywhere has no default keys")
	}
	search := i18n.SharedFormat(h.app.language(), "desktop.tools.withShortcut", map[string]string{"name": h.app.text.Title.Search, "keys": keys})
	for _, tc := range []struct {
		id, tip string
		// beside reports whether the tip stands on the button's inner side.
		beside func(tip, button gfx.Rect) bool
	}{
		{id: itemProject, tip: h.app.text.Tools.Project, beside: func(tip, button gfx.Rect) bool { return tip.X >= button.Right() }},
		{id: itemBuild, tip: h.app.text.Tools.Build, beside: func(tip, button gfx.Rect) bool { return tip.Right() <= button.X }},
		{id: itemTitleSearch, tip: search, beside: func(tip, button gfx.Rect) bool { return tip.Y >= button.Bottom() }},
	} {
		t.Run(tc.id, func(t *testing.T) {
			if hit := h.buttonHit(tc.id); hit.Hint != tc.tip || hit.Description != h.app.text.Tools.DragHint {
				t.Fatalf("the %s button tells assistive technology %q, then %q; want %q, then the drag hint", tc.id, hit.Hint, hit.Description, tc.tip)
			}
			button := h.button(tc.id)
			at := center(button)
			if err := h.driver.Move(at.X, at.Y); err != nil {
				t.Fatal(err)
			}
			h.settle()
			tips := h.tooltips()
			if len(tips) != 1 || tips[0].Value != tc.tip {
				t.Fatalf("resting on the %s button shows the tips %+v, want only %q", tc.id, tips, tc.tip)
			}
			if !tc.beside(tips[0].Bounds, button) {
				t.Fatalf("the %s tip at %+v is not on the inner side of the button at %+v", tc.id, tips[0].Bounds, button)
			}
		})
	}

	from := center(h.button(itemCommit))
	if err := h.driver.Press(from.X, from.Y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Move(from.X+2*dragThreshold, from.Y+2*dragThreshold); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if tips := h.tooltips(); len(tips) != 0 {
		t.Errorf("dragging the commit button shows the tips %+v", tips)
	}
	if err := h.driver.Cancel(); err != nil {
		t.Fatal(err)
	}
	h.settle()
}
