package pluginstate

import (
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// choices reports the stored choices by plugin ID.
func choices(t *testing.T, state *Store) map[string]bool {
	t.Helper()
	entries, err := state.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	found := make(map[string]bool, len(entries))
	for _, entry := range entries {
		found[entry.PluginID] = entry.Enabled
	}
	return found
}

func TestNoChoiceIsStoredAtFirst(t *testing.T) {
	if found := choices(t, New(store.At(t.TempDir()))); len(found) != 0 {
		t.Fatalf("a new store holds %v", found)
	}
}

func TestSetEnabledRoundTrips(t *testing.T) {
	dir := t.TempDir()
	state := New(store.At(dir))
	if err := state.SetEnabled("example", true); err != nil {
		t.Fatalf("set enabled: %v", err)
	}
	if enabled, ok := choices(t, New(store.At(dir)))["example"]; !ok || !enabled {
		t.Fatalf("enabled = %v, recorded = %v", enabled, ok)
	}
	if err := state.SetEnabled("example", false); err != nil {
		t.Fatalf("set disabled: %v", err)
	}
	if enabled, ok := choices(t, state)["example"]; !ok || enabled {
		t.Fatalf("enabled = %v, recorded = %v", enabled, ok)
	}
}

func TestForgetDropsOnlyThatChoice(t *testing.T) {
	state := New(store.At(t.TempDir()))
	if err := state.SetEnabled("first", true); err != nil {
		t.Fatal(err)
	}
	if err := state.SetEnabled("second", true); err != nil {
		t.Fatal(err)
	}
	if err := state.Forget("first"); err != nil {
		t.Fatalf("forget: %v", err)
	}
	found := choices(t, state)
	if _, ok := found["first"]; ok || !found["second"] {
		t.Fatalf("choices after forgetting first = %v", found)
	}
	// Forgetting a plugin that was never recorded is not an error.
	if err := state.Forget("absent"); err != nil {
		t.Fatalf("forget absent: %v", err)
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
	if err := state.SetEnabled("", true); !errors.Is(err, ErrInvalidPlugin) {
		t.Fatalf("err = %v", err)
	}
	if err := state.Forget(""); !errors.Is(err, ErrInvalidPlugin) {
		t.Fatalf("err = %v", err)
	}
}
