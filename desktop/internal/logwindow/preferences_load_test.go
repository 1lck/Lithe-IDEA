package logwindow

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// Opening the log window should report saved-state corruption or OS read errors
// without replacing or leaking the original file path. A newer version's
// incompatible field shape is also an unreadable state, even though Store.Load
// returns no error for that case.
func TestLogPreferencesReadFailuresAreReported(t *testing.T) {
	for _, test := range []struct {
		name, content string
		isDir         bool
	}{
		{name: "invalid-json", content: "{not JSON"},
		{name: "incompatible-field-shape", content: `{"query":{"session":{"future":1}}}`},
		{name: "directory-at-path", isDir: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			prefs := store.At(dir)
			target := filepath.Join(dir, prefsFile)
			if test.isDir {
				if err := os.Mkdir(target, 0o700); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(target, []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			source := &exportSource{dir: dir}
			model := NewModel(Options{Source: source, Store: prefs})
			defer model.close()
			if model.prefs.Query.Session != sessionCurrent {
				t.Fatalf("session = %q, want the default after malformed preferences", model.prefs.Query.Session)
			}
			events := source.emittedEvents()
			if len(events) != 1 || events[0].level != core.LevelWarn ||
				events[0].event != "app.background.operation_failed" ||
				events[0].fields["operation"] != opPreferencesLoad {
				t.Fatalf("preferences read events = %+v, want one warning with operation %q", events, opPreferencesLoad)
			}
			if errMsg := fmt.Sprint(events[0].fields["error"]); errMsg == "" || strings.Contains(errMsg, dir) {
				t.Fatalf("preferences error = %q, want non-empty message without store path %q", errMsg, dir)
			}
			if test.isDir {
				info, err := os.Stat(target)
				if err != nil || !info.IsDir() {
					t.Fatalf("opening log window replaced directory %s: info=%v err=%v", target, info, err)
				}
				return
			}
			data, err := os.ReadFile(target)
			if err != nil || string(data) != test.content {
				t.Fatalf("opening log window modified unreadable preferences: %q, %v", data, err)
			}
		})
	}
}
