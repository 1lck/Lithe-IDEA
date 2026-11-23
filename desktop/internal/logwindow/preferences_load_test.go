package logwindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// Opening the log window should report saved-state corruption without replacing
// the original file. A newer version's incompatible field shape is also an
// unreadable state, even though Store.Load returns no error for that case.
func TestLogPreferencesReadFailuresAreReported(t *testing.T) {
	for _, test := range []struct {
		name, content string
	}{
		{"invalid-json", "{not JSON"},
		{"incompatible-field-shape", `{"query":{"session":{"future":1}}}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			prefs := store.At(dir)
			if err := os.WriteFile(filepath.Join(dir, prefsFile), []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			source := &exportSource{dir: dir}
			model := NewModel(Options{Source: source, Store: prefs})
			defer model.stopAll()
			if model.prefs.Query.Session != sessionCurrent {
				t.Fatalf("session = %q, want the default after malformed preferences", model.prefs.Query.Session)
			}
			events := source.emittedEvents()
			if len(events) != 1 || events[0].level != core.LevelWarn ||
				events[0].event != "app.background.operation_failed" ||
				events[0].fields["operation"] != opPreferencesLoad {
				t.Fatalf("preferences read events = %+v, want one warning with operation %q", events, opPreferencesLoad)
			}
			data, err := os.ReadFile(filepath.Join(dir, prefsFile))
			if err != nil || string(data) != test.content {
				t.Fatalf("opening log window modified unreadable preferences: %q, %v", data, err)
			}
		})
	}
}
