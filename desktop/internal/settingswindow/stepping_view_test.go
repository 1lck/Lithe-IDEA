package settingswindow

import (
	"context"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

type steppingChange struct {
	adapter string
	filters *core.DebugSteppingFilters
}

// TestDebuggersPageAppliesAndRestoresAnAdaptersFilters walks the Debuggers page: it starts
// from the plugin's declared defaults, the footer's Apply has Core check the draft and hands
// the result to the settings owner, and Use Plugin Defaults followed by Apply removes the
// user's policy.
func TestDebuggersPageAppliesAndRestoresAnAdaptersFilters(t *testing.T) {
	var changes []steppingChange
	normalized := 0
	w := newWindow(NewController(Options{
		SteppingAdapters: func(context.Context) ([]SteppingAdapter, error) {
			return []SteppingAdapter{{ID: "java", Name: "Java Debugger", Defaults: core.DebugSteppingFilters{ClassNameFilters: []string{"java.*"}, SkipSynthetics: true}}}, nil
		},
		NormalizeSteppingFilters: func(_ context.Context, adapter string, filters core.DebugSteppingFilters) (core.DebugSteppingFilters, error) {
			normalized++
			slices.Sort(filters.ClassNameFilters)
			return filters, nil
		},
		SetSteppingFilters: func(adapter string, filters *core.DebugSteppingFilters) {
			changes = append(changes, steppingChange{adapter, filters})
		},
	}), Values{})
	w.sess.page = pageDebuggers
	d := openWindow(t, w)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	d.until("the debuggers to load", func() bool { return w.stepping.loaded })
	d.pump()

	if !d.text("Java Debugger") || !d.text(text("desktop.settings.stepping.usingDefaults")) {
		t.Fatal("the page does not show the adapter and that it uses its plugin's defaults")
	}
	if hit := d.hit(text("desktop.settings.stepping.skipSynthetics")); !hit.Checked {
		t.Fatalf("the declared default skipSynthetics is not shown: %+v", hit)
	}
	apply := text("desktop.buildSettings.apply")
	if hit := d.hit(apply); !hit.Disabled {
		t.Fatal("Apply is enabled before anything changed")
	}
	for _, label := range []string{"java.*", text("desktop.settings.stepping.skipConstructors")} {
		var row gfx.Hit
		for _, hit := range d.driver.Snapshot().Hits {
			if hit.Label == label && hit.Role == gfx.RoleGroup {
				row = hit
				break
			}
		}
		if row.ID.IsZero() || row.Focusable {
			t.Fatalf("%q needs a hover target outside the keyboard focus order: %+v", label, row)
		}
		if err := d.driver.Move(row.Bounds.X+4, row.Bounds.Y+row.Bounds.Height/2); err != nil {
			t.Fatal(err)
		}
		highlighted := false
		x, y := row.Bounds.X+12, row.Bounds.Y+row.Bounds.Height/2
		for _, shape := range d.driver.Snapshot().Primitives {
			bounds := shape.Bounds
			if shape.Color == w.bp.hover && x >= bounds.X && x < bounds.X+bounds.Width && y >= bounds.Y && y < bounds.Y+bounds.Height {
				highlighted = true
				break
			}
		}
		if !highlighted {
			t.Fatalf("%q is not highlighted while hovered: bounds=%+v hovered=%v want=%v", label, row.Bounds, d.driver.Snapshot().Hovered, row.ID)
		}
	}

	d.click(text("desktop.settings.stepping.skipConstructors"))
	d.pump()
	if !d.wrapped(text("desktop.buildSettings.steppingPending")) {
		t.Fatal("the page does not say the change waits for Apply")
	}
	d.click(apply)
	d.until("the policy to be applied", func() bool { return len(changes) == 1 })
	got := changes[0]
	if normalized != 1 || got.adapter != "java" || got.filters == nil || !got.filters.SkipConstructors || !got.filters.SkipSynthetics ||
		!slices.Equal(got.filters.ClassNameFilters, []string{"java.*"}) {
		t.Fatalf("applied %+v (normalized %d times)", got, normalized)
	}
	d.pump()
	if !d.text(text("desktop.settings.stepping.customized")) {
		t.Fatal("the page does not say the policy is customized")
	}

	// Use Plugin Defaults only resets the draft; Apply removes the stored policy.
	d.click(text("desktop.settings.stepping.restoreDefaults"))
	d.pump()
	if len(changes) != 1 {
		t.Fatalf("Use Plugin Defaults wrote before Apply: %+v", changes)
	}
	if hit := d.hit(text("desktop.settings.stepping.skipConstructors")); hit.Checked {
		t.Fatal("the page kept the removed policy's switch")
	}
	d.click(apply)
	d.until("the policy to be removed", func() bool { return len(changes) == 2 })
	if changes[1].adapter != "java" || changes[1].filters != nil {
		t.Fatalf("Use Plugin Defaults = %+v", changes)
	}
	if normalized != 1 {
		t.Fatalf("removing the policy went to Core: normalized %d times", normalized)
	}
	d.click(text("desktop.buildSettings.removePattern"))
	if patterns := w.steppingDraftOf(w.stepping.adapters[0]).patterns; len(patterns) != 0 {
		t.Fatalf("the pattern row intercepted its remove button: %v", patterns)
	}
}

// Restore Defaults in the footer removes every adapter's stepping policy.
func TestRestoreDefaultsRemovesSteppingFilters(t *testing.T) {
	var changes []steppingChange
	w := newWindow(NewController(Options{
		SetSteppingFilters: func(adapter string, filters *core.DebugSteppingFilters) {
			changes = append(changes, steppingChange{adapter, filters})
		},
	}), Values{SteppingFilters: map[string]core.DebugSteppingFilters{"b": {}, "a": {SkipConstructors: true}}})
	d := openWindow(t, w)
	d.click("Restore Defaults")
	if len(changes) != 2 || changes[0].adapter != "a" || changes[1].adapter != "b" || changes[0].filters != nil || changes[1].filters != nil {
		t.Fatalf("restore = %+v", changes)
	}
	if len(w.sess.values.SteppingFilters) != 0 {
		t.Fatalf("the window kept %v", w.sess.values.SteppingFilters)
	}
}

// A draft's patterns are sent trimmed, without the blank ones.
func TestSteppingDraftDropsBlankPatterns(t *testing.T) {
	draft := steppingDraft{patterns: []string{"  java.*", "", " sun.* "}, hideFilteredFrames: true}
	filters := draft.filters()
	if !slices.Equal(filters.ClassNameFilters, []string{"java.*", "sun.*"}) || !filters.HideFilteredStackFrames {
		t.Fatalf("filters = %+v", filters)
	}
	if empty := (steppingDraft{}).filters(); empty.ClassNameFilters == nil {
		t.Fatal("an empty draft sends null patterns")
	}
}
