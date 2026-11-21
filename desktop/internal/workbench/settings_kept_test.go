package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
)

// keptNotices is the notices that told about settings this version does not read.
func keptNotices(a *App) []string {
	var found []string
	for _, entry := range a.notifications.list {
		if strings.Contains(entry.text, "laterChannelOption") {
			found = append(found, entry.text)
		}
	}
	return found
}

func TestSettingsANewerVersionWroteAreToldAboutOnceAndKept(t *testing.T) {
	dir := t.TempDir()
	written := `{"theme":"dark","laterChannelOption":"nightly","workbenchBackground":{"name":"bg.png","strength":"strong"}}`
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(written), 0o600); err != nil {
		t.Fatal(err)
	}
	first := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"zh-Hans"}})
	if notices := keptNotices(first.app); len(notices) != 1 || !strings.Contains(notices[0], "1") {
		t.Fatalf("notices at the first launch = %q, want one naming the kept key", notices)
	}

	data, err := os.ReadFile(filepath.Join(dir, settingsFile))
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	if saved["laterChannelOption"] != "nightly" {
		t.Fatalf("saved %s, want the key this version does not read kept", data)
	}
	if background, _ := saved["workbenchBackground"].(map[string]any); background["name"] != "bg.png" {
		t.Fatalf("saved %s, want the background the notice's save left alone", data)
	}

	second := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"zh-Hans"}})
	if notices := keptNotices(second.app); len(notices) != 0 {
		t.Fatalf("notices at the next launch = %q, want none for the same keys", notices)
	}
}

// loggedStages is the stage of each app.settings.decode_failed event, and the operation of each
// app.background.operation_failed event, the log was given.
func loggedStages(log *faultLog) (stages, operations []string) {
	log.mu.Lock()
	defer log.mu.Unlock()
	for _, event := range log.events {
		switch event.event {
		case "app.settings.decode_failed":
			stage, _ := event.fields["stage"].(string)
			stages = append(stages, stage)
		case backgroundFailedEvent:
			operation, _ := event.fields["operation"].(string)
			operations = append(operations, operation)
		}
	}
	return stages, operations
}

func TestALayoutPartANewerVersionShapedDifferentlyIsLogged(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	log := &faultLog{}
	h.app.logSink = log
	// The placements are stored in a shape this version cannot read; the rest of the layout
	// loads, the placements run on their defaults, and the defaults are logged.
	if err := h.store.WriteFile(layoutFile, []byte(`{"placements":{"left":["project"]},"open":[],"hidden":["commit"]}`)); err != nil {
		t.Fatal(err)
	}
	h.app.loadChrome()

	if stages, _ := loggedStages(log); len(stages) != 1 || stages[0] != "chrome_layout" {
		t.Fatalf("decode_failed stages = %v, want one for the chrome layout", stages)
	}
	if hidden := h.app.chrome.saved.Hidden; len(hidden) != 1 || hidden[0] != itemCommit {
		t.Fatalf("hidden = %v, want the readable part of the layout loaded", hidden)
	}
}

func TestAnEditorSessionANewerVersionShapedDifferentlyIsLogged(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	log := &faultLog{}
	h.app.logSink = log
	if err := h.store.WriteFile(editorSessionFile, []byte(`{"/elsewhere":{"groups":"all"}}`)); err != nil {
		t.Fatal(err)
	}
	h.open(t.TempDir())

	if _, operations := loggedStages(log); len(operations) != 1 || operations[0] != "editor_session_load" {
		t.Fatalf("background failures = %v, want one for the editor session read", operations)
	}
}

func TestUnreadableSettingsWarnAtStartupAndIdentifyTheBackupOnSave(t *testing.T) {
	// Invalid settings follow system appearance before the workbench driver
	// exists. Open Viva's headless driver first to supply that setting.
	system, err := app.NewDriver(app.Config{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(system.Close)
	dir := t.TempDir()
	original := []byte(`{"theme":"dark","incomplete":`)
	path := filepath.Join(dir, settingsFile)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"en"},
	})
	notices := h.app.notifications.list
	if len(notices) != 1 || !strings.Contains(notices[0].text, "Could not read settings") || !strings.Contains(notices[0].detail, "default settings") {
		t.Fatalf("startup did not explain that default settings are in use: %+v", notices)
	}
	backups, err := filepath.Glob(path + ".unreadable-*")
	if err != nil || len(backups) != 0 {
		t.Fatalf("startup changed the backup files: %v, %v", backups, err)
	}
	if actual, err := os.ReadFile(path); err != nil || string(actual) != string(original) {
		t.Fatalf("startup changed the settings file: %q, %v", actual, err)
	}

	h.app.setTheme("dark")
	backups, err = filepath.Glob(path + ".unreadable-*")
	if err != nil || len(backups) != 1 {
		t.Fatalf("after saving, backups = %v, %v", backups, err)
	}
	if backup, err := os.ReadFile(backups[0]); err != nil || string(backup) != string(original) {
		t.Fatalf("backup = %q, %v, want original settings bytes", backup, err)
	}
	notices = h.app.notifications.list
	if len(notices) != 2 || !strings.Contains(notices[0].detail, backups[0]) {
		t.Fatalf("saving did not report the backup path: %+v", notices)
	}
	var restored settings
	if found, err := store.At(dir).Load(settingsFile, &restored); err != nil || !found || restored.Theme != "dark" {
		t.Fatalf("new settings theme = %q, found = %v, err = %v", restored.Theme, found, err)
	}
	h.app.saveSettings()
	if got := len(h.app.notifications.list); got != 2 {
		t.Fatalf("second save produced a notice, got %d notices", got)
	}
}
