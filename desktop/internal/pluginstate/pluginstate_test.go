package pluginstate

import (
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestEnabledDefaultsToDisabled(t *testing.T) {
	state := New(store.At(t.TempDir()))
	enabled, err := state.Enabled("example")
	if err != nil {
		t.Fatalf("enabled: %v", err)
	}
	if enabled {
		t.Fatal("a plugin with no record was enabled")
	}
}

func TestSetEnabledRoundTrips(t *testing.T) {
	state := New(store.At(t.TempDir()))
	if err := state.SetEnabled("example", true); err != nil {
		t.Fatalf("set enabled: %v", err)
	}
	enabled, err := state.Enabled("example")
	if err != nil || !enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
	if err := state.SetEnabled("example", false); err != nil {
		t.Fatalf("set disabled: %v", err)
	}
	enabled, err = state.Enabled("example")
	if err != nil || enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
}

func TestForgetReturnsToDisabled(t *testing.T) {
	state := New(store.At(t.TempDir()))
	if err := state.SetEnabled("example", true); err != nil {
		t.Fatal(err)
	}
	if err := state.Forget("example"); err != nil {
		t.Fatalf("forget: %v", err)
	}
	enabled, err := state.Enabled("example")
	if err != nil || enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
	// Forgetting a plugin that was never recorded is not an error.
	if err := state.Forget("absent"); err != nil {
		t.Fatalf("forget absent: %v", err)
	}
}

func TestForgetKeepsOtherPlugins(t *testing.T) {
	state := New(store.At(t.TempDir()))
	if err := state.SetEnabled("first", true); err != nil {
		t.Fatal(err)
	}
	if err := state.SetEnabled("second", true); err != nil {
		t.Fatal(err)
	}
	if err := state.Forget("first"); err != nil {
		t.Fatal(err)
	}
	enabled, err := state.Enabled("second")
	if err != nil || !enabled {
		t.Fatalf("enabled = %v, err = %v", enabled, err)
	}
}

func TestListIsSorted(t *testing.T) {
	state := New(store.At(t.TempDir()))
	for _, id := range []string{"zeta", "alpha", "beta"} {
		if err := state.SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := state.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	want := []string{"alpha", "beta", "zeta"}
	if len(entries) != len(want) {
		t.Fatalf("entries = %+v", entries)
	}
	for i, entry := range entries {
		if entry.PluginID != want[i] {
			t.Fatalf("entry %d = %q", i, entry.PluginID)
		}
		if !entry.Enabled {
			t.Fatalf("entry %d is disabled", i)
		}
	}
}

func TestRefusesEmptyID(t *testing.T) {
	state := New(store.At(t.TempDir()))
	if _, err := state.Enabled(""); !errors.Is(err, ErrInvalidPlugin) {
		t.Fatalf("err = %v", err)
	}
	if err := state.SetEnabled("", true); !errors.Is(err, ErrInvalidPlugin) {
		t.Fatalf("err = %v", err)
	}
	if err := state.Forget(""); !errors.Is(err, ErrInvalidPlugin) {
		t.Fatalf("err = %v", err)
	}
}

func TestEnableUnlessChosenRecordsOnlyAFirstChoice(t *testing.T) {
	state := New(store.At(t.TempDir()))
	if changed, err := state.EnableUnlessChosen("fresh"); err != nil || !changed {
		t.Fatalf("fresh: changed = %v, err = %v", changed, err)
	}
	if enabled, err := state.Enabled("fresh"); err != nil || !enabled {
		t.Fatalf("fresh: enabled = %v, err = %v", enabled, err)
	}
	if err := state.SetEnabled("chosen", false); err != nil {
		t.Fatal(err)
	}
	if changed, err := state.EnableUnlessChosen("chosen"); err != nil || changed {
		t.Fatalf("chosen: changed = %v, err = %v", changed, err)
	}
	if enabled, err := state.Enabled("chosen"); err != nil || enabled {
		t.Fatalf("an explicit disable was overridden: enabled = %v, err = %v", enabled, err)
	}
	if _, err := state.EnableUnlessChosen(""); !errors.Is(err, ErrInvalidPlugin) {
		t.Fatalf("empty ID: %v", err)
	}
}
