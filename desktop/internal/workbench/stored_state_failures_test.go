package workbench

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
			h.app.excludeFromSearch(p, "src", true)
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
			wantNotice := i18n.Shared(h.app.language(), "indexing.configureFailed")
			if notices := noticeTexts(h.app); !slices.Contains(notices, wantNotice) {
				t.Fatalf("notices = %q, want %q after rejecting edits to unreadable directory rules", notices, wantNotice)
			}
			logger.mu.Lock()
			warnings := 0
			rejections := 0
			for _, event := range logger.events {
				if event.Event == "app.settings.decode_failed" && event.Fields["stage"] == "directory_rules" {
					warnings++
				}
				if event.Event == operationRejectedEvent &&
					event.Fields["operation"] == "workspace_exclude" &&
					event.Fields["reason"] == "unreadable_stored_rules" {
					rejections++
				}
			}
			logger.mu.Unlock()
			if warnings != 1 {
				t.Fatalf("directory rules read warnings = %d, want exactly one", warnings)
			}
			if rejections != 3 {
				t.Fatalf("directory rules rejection events = %d, want 3 (exclude, cancel, gitignore)", rejections)
			}

			// Repairing the file and reopening the project must load cleanly and allow edits again.
			if err := os.WriteFile(h.store.Path(name), []byte("{}"), 0o600); err != nil {
				t.Fatal(err)
			}
			h2 := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: h.store})
			logger2 := &treeRecordingLog{}
			h2.app.logSink = logger2
			t.Cleanup(func() { h2.app.logSink = nil })
			h2.open(root)
			p2 := h2.app.project
			if p2 == nil {
				t.Fatal("the fixture project did not reopen")
			}
			h2.await("reopened indexing policy", func() bool { return p2.indexing.loaded })
			if p2.indexing.unreadable {
				t.Fatalf("reopened project kept unreadable=true after file repair")
			}
			h2.app.excludeFromSearch(p2, "src", false)
			h2.settle()
			repaired, err := os.ReadFile(h.store.Path(name))
			if err != nil || !strings.Contains(string(repaired), `"src"`) {
				t.Fatalf("exclude after repair did not persist src rule: %q, %v", repaired, err)
			}
			logger2.mu.Lock()
			defer logger2.mu.Unlock()
			for _, event := range logger2.events {
				if event.Event == "app.settings.decode_failed" && event.Fields["stage"] == "directory_rules" {
					t.Fatalf("reopening repaired rules logged decode_failed: %+v", event)
				}
				if event.Event == operationRejectedEvent && event.Fields["operation"] == "workspace_exclude" {
					t.Fatalf("editing repaired rules was rejected: %+v", event)
				}
			}
		})
	}
}

func TestStartupBackgroundLogsUnreadableStoredColor(t *testing.T) {
	for _, test := range []struct {
		name, content string
		isDir         bool
	}{
		{name: "invalid-json", content: "{not JSON"},
		{name: "incompatible-known-field", content: `{"red":"future","green":0,"blue":0,"alpha":1}`},
		{name: "directory-at-path", isDir: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			target := prefs.Path(windowBackgroundFile)
			if test.isDir {
				if err := os.Mkdir(target, 0o700); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(target, []byte(test.content), 0o600); err != nil {
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
					if errMsg := fmt.Sprint(event.Fields["error"]); errMsg == "" || strings.Contains(errMsg, prefs.Dir()) {
						t.Fatalf("window background error = %q, want non-empty message without store path %q", errMsg, prefs.Dir())
					}
				}
			}
			if warnings != 1 {
				t.Fatalf("startup background read warnings = %d, want 1", warnings)
			}
			if test.isDir {
				info, err := os.Stat(target)
				if err != nil || !info.IsDir() {
					t.Fatalf("reading startup color replaced directory %s: info=%v err=%v", target, info, err)
				}
				return
			}
			if data, err := os.ReadFile(target); err != nil || string(data) != test.content {
				t.Fatalf("reading the startup color changed the source: %q, %v", data, err)
			}
		})
	}
}
