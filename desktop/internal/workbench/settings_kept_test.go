package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
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
