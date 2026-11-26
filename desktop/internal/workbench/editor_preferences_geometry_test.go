package workbench

import (
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
)

func TestEditorPreferencesContendedSaveAcknowledgesOnlyPersistedGeometry(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	sessions := h.app.sessions
	initial := sessions.geometry.saved
	unlock, err := filelock.TryAcquire(filepath.Join(h.store.Dir(), ".settings.lock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if unlock != nil {
			if err := unlock(); err != nil {
				t.Error(err)
			}
		}
	})
	if err := h.driver.Resize(1500, 920); err != nil {
		t.Fatal(err)
	}
	h.app.saveSettings()
	if sessions.geometry.saved != initial {
		t.Fatal("a queued settings snapshot acknowledged unsaved geometry")
	}
	// A second frozen snapshot overtakes the first one under the same lock.
	if err := h.driver.Resize(1600, 980); err != nil {
		t.Fatal(err)
	}
	h.app.saveSettings()
	if err := unlock(); err != nil {
		t.Fatal(err)
	}
	unlock = nil
	h.settle()
	var saved settings
	if found, err := h.store.Load(settingsFile, &saved); !found || err != nil {
		t.Fatalf("load geometry: found=%v err=%v", found, err)
	}
	want := windowGeometry{width: 1600, height: 980}
	if saved.WindowWidth != want.width || saved.WindowHeight != want.height || sessions.geometry.saved != want {
		t.Fatalf("persisted %dx%d, acknowledged %+v; want %+v", saved.WindowWidth, saved.WindowHeight, sessions.geometry.saved, want)
	}
}
