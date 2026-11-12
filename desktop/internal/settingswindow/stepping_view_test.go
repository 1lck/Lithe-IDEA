package settingswindow

import (
	"context"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

type steppingChange struct {
	adapter string
	filters *core.DebugSteppingFilters
}

// TestSteppingCardAppliesAndRestoresAnAdaptersFilters walks the Build page's stepping card:
// it starts from the plugin's declared defaults, Apply has Core check the draft and hands
// the result to the settings owner, and Use Plugin Defaults removes the user's policy.
func TestSteppingCardAppliesAndRestoresAnAdaptersFilters(t *testing.T) {
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
	w.sess.page = pageBuild
	d := openWindow(t, w)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	d.until("the debuggers to load", func() bool { return w.stepping.loaded })
	d.pump()

	if !d.text("Java Debugger") || !d.text(text("desktop.settings.stepping.usingDefaults")) {
		t.Fatal("the card does not show the adapter and that it uses its plugin's defaults")
	}
	if hit := d.hit(text("desktop.settings.stepping.skipSynthetics")); !hit.Checked {
		t.Fatalf("the declared default skipSynthetics is not shown: %+v", hit)
	}
	if hit := d.hit(text("desktop.settings.stepping.apply")); !hit.Disabled {
		t.Fatal("Apply is enabled before anything changed")
	}

	d.click(text("desktop.settings.stepping.skipConstructors"))
	d.click(text("desktop.settings.stepping.apply"))
	d.until("the policy to be applied", func() bool { return len(changes) == 1 })
	got := changes[0]
	if normalized != 1 || got.adapter != "java" || got.filters == nil || !got.filters.SkipConstructors || !got.filters.SkipSynthetics ||
		!slices.Equal(got.filters.ClassNameFilters, []string{"java.*"}) {
		t.Fatalf("applied %+v (normalized %d times)", got, normalized)
	}
	d.pump()
	if !d.text(text("desktop.settings.stepping.customized")) {
		t.Fatal("the card does not say the policy is customized")
	}

	d.click(text("desktop.settings.stepping.restoreDefaults"))
	if len(changes) != 2 || changes[1].adapter != "java" || changes[1].filters != nil {
		t.Fatalf("Use Plugin Defaults = %+v", changes)
	}
	d.pump()
	if hit := d.hit(text("desktop.settings.stepping.skipConstructors")); hit.Checked {
		t.Fatal("the card kept the removed policy's switch")
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

func TestSteppingDraftReadsOnePatternPerLine(t *testing.T) {
	draft := steppingDraft{patterns: "  java.*\n\n sun.* \r\n", hideFilteredFrames: true}
	filters := draft.filters()
	if !slices.Equal(filters.ClassNameFilters, []string{"java.*", "sun.*"}) || !filters.HideFilteredStackFrames {
		t.Fatalf("filters = %+v", filters)
	}
	if empty := (steppingDraft{}).filters(); empty.ClassNameFilters == nil {
		t.Fatal("an empty draft sends null patterns")
	}
}
