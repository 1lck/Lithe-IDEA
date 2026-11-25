package shortcuts

import (
	"runtime"
	"testing"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
)

// Keycaps' glyph set comes from the build target of the viva keymap package, so each CI
// runner checks the expectation for its own platform.
func TestKeycapsOnThisPlatform(t *testing.T) {
	if runtime.GOOS == "darwin" {
		if got, want := Keycaps(chord(gfx.ModifierMeta|gfx.ModifierShift, "o")), "⇧⌘O"; got != want {
			t.Fatalf("macOS keycaps = %q, want %q", got, want)
		}
		return
	}
	if got, want := Keycaps(chord(gfx.ModifierControl|gfx.ModifierShift, "o")), "Ctrl+Shift+O"; got != want {
		t.Fatalf("other keycaps = %q, want %q", got, want)
	}
}

func TestDoubleShiftLabelPerPlatform(t *testing.T) {
	if got, want := doubleShiftFor(true), "⇧⇧"; got != want {
		t.Fatalf("macOS double shift = %q, want %q", got, want)
	}
	if got, want := doubleShiftFor(false), "Shift+Shift"; got != want {
		t.Fatalf("other double shift = %q, want %q", got, want)
	}
}

// The empty-editor hints read Label, so a user's change must show up there and defaults must
// match what the menus show.
func TestLabelFollowsUserOverride(t *testing.T) {
	var overrides Overrides
	action, ok := Find("search.files")
	if !ok {
		t.Fatal("search.files is not registered")
	}
	if got, want := overrides.Label("search.files"), Keycaps(action.Defaults[0]); got != want {
		t.Fatalf("default label = %q, want %q", got, want)
	}

	changed := chord(keymap.Primary|gfx.ModifierAlt, "x")
	overrides = overrides.With("search.files", []keymap.Chord{changed})
	if got, want := overrides.Label("search.files"), Keycaps(changed); got != want {
		t.Fatalf("overridden label = %q, want %q", got, want)
	}
}

// Regression test for #2406: Git sync commands are registered in the shortcut catalog
// and no two catalog actions share a default chord.
func TestGitSyncShortcutsRegisteredWithoutDefaultConflicts(t *testing.T) {
	for _, id := range []string{"git.pull", "git.push", "git.fetch", "git.updateBranch"} {
		action, ok := Find(id)
		if !ok {
			t.Fatalf("%s is not registered in shortcuts.Catalog", id)
		}
		if action.Group != GroupGit {
			t.Fatalf("%s group = %v, want GroupGit", id, action.Group)
		}
	}

	seen := map[keymap.Chord]string{}
	for _, action := range Catalog {
		for _, c := range action.Defaults {
			if other, dup := seen[c]; dup {
				t.Fatalf("default chord %v conflicts between %s and %s", c, other, action.ID)
			}
			seen[c] = action.ID
		}
	}
}
