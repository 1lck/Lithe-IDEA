package workbench

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestUnreadableDirectoryRulesAreLoggedAndNeverReplacedByAnEdit(t *testing.T) {
	for _, test := range []struct {
		name, content string
	}{
		{"invalid-json", "{not JSON"},
		{"incompatible-known-field", `{"root":"fixture","rules":{},"gitIgnoreDisabled":"future"}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t, &testKernel{Client: core.NewClient()})
			logger := &treeRecordingLog{}
			h.app.logSink = logger
			t.Cleanup(func() { h.app.logSink = nil })
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, "src"), 0o700); err != nil {
				t.Fatal(err)
			}
			name := directoryRulesName(root)
			if err := os.WriteFile(h.store.Path(name), []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			h.open(root)
			p := h.app.project
			if p == nil {
				t.Fatal("the fixture project did not open")
			}
			h.await("indexing policy fallback", func() bool { return p.indexing.loaded })
			if !p.indexing.unreadable || !p.indexing.gitIgnore {
				t.Fatalf("indexing unreadable=%v gitIgnore=%v, want protected defaults", p.indexing.unreadable, p.indexing.gitIgnore)
			}
			h.app.excludeFromSearch(p, "src", false)
			h.app.setGitIgnoreIndexing(p, false)
			h.settle()
			after, err := os.ReadFile(h.store.Path(name))
			if err != nil || !bytes.Equal(after, []byte(test.content)) {
				t.Fatalf("an edit overwrote the unreadable directory rules: %q, %v", after, err)
			}
			entries, err := os.ReadDir(h.store.Dir())
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if filepath.Base(entry.Name()) != name && len(entry.Name()) > len(name) && entry.Name()[:len(name)] == name {
					t.Fatalf("editing an unreadable rule moved its original aside: %s", entry.Name())
				}
			}
			logger.mu.Lock()
			defer logger.mu.Unlock()
			warnings := 0
			for _, event := range logger.events {
				if event.Event == "app.settings.decode_failed" && event.Fields["stage"] == "directory_rules" {
					warnings++
				}
			}
			if warnings != 1 {
				t.Fatalf("directory rules read warnings = %d, want exactly one", warnings)
			}
		})
	}
}

func TestStartupBackgroundLogsUnreadableStoredColor(t *testing.T) {
	for _, test := range []struct {
		name, content string
	}{
		{"invalid-json", "{not JSON"},
		{"incompatible-known-field", `{"red":"future","green":0,"blue":0,"alpha":1}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := os.WriteFile(prefs.Path(windowBackgroundFile), []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			logger := &treeRecordingLog{}
			a := &App{store: prefs, logSink: logger}
			got := a.startupBackground()
			_, dark := look(themeDark)
			if want := appColor(dark.Editor); got != want {
				t.Fatalf("startup color = %+v, want the dark-theme fallback %+v", got, want)
			}
			logger.mu.Lock()
			defer logger.mu.Unlock()
			var warnings int
			for _, event := range logger.events {
				if event.Event == "app.settings.decode_failed" && event.Fields["stage"] == "window_background" {
					warnings++
				}
			}
			if warnings != 1 {
				t.Fatalf("startup background read warnings = %d, want 1", warnings)
			}
			if data, err := os.ReadFile(prefs.Path(windowBackgroundFile)); err != nil || string(data) != test.content {
				t.Fatalf("reading the startup color changed the source: %q, %v", data, err)
			}
		})
	}
}
