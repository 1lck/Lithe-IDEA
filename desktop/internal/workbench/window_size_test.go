package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// TestWorkbenchWindowOpensAtSavedSizeAndMaximizedState covers where a new workbench window
// takes its initial size and maximized state: the values kept from the previous session,
// the default 1280×800 when none is kept or the kept size is unusable, and never below
// minWindowWidth × minWindowHeight.
func TestWorkbenchWindowOpensAtSavedSizeAndMaximizedState(t *testing.T) {
	for _, test := range []struct {
		name          string
		saved         settings
		wantWidth     int
		wantHeight    int
		wantMaximized bool
	}{
		{
			name:       "none kept",
			saved:      settings{Theme: themeDark},
			wantWidth:  defaultWindowWidth,
			wantHeight: defaultWindowHeight,
		},
		{
			name:       "kept floating size",
			saved:      settings{Theme: themeDark, WindowWidth: 1600, WindowHeight: 980},
			wantWidth:  1600,
			wantHeight: 980,
		},
		{
			name:          "kept maximized with floating size",
			saved:         settings{Theme: themeDark, WindowWidth: 1500, WindowHeight: 920, WindowMaximized: true},
			wantWidth:     1500,
			wantHeight:    920,
			wantMaximized: true,
		},
		{
			name:          "kept maximized without floating size",
			saved:         settings{Theme: themeDark, WindowMaximized: true},
			wantWidth:     defaultWindowWidth,
			wantHeight:    defaultWindowHeight,
			wantMaximized: true,
		},
		{
			name:       "one side missing",
			saved:      settings{Theme: themeDark, WindowWidth: 1600, WindowHeight: 0},
			wantWidth:  defaultWindowWidth,
			wantHeight: defaultWindowHeight,
		},
		{
			name:       "negative dimension",
			saved:      settings{Theme: themeDark, WindowWidth: -1, WindowHeight: 900},
			wantWidth:  defaultWindowWidth,
			wantHeight: defaultWindowHeight,
		},
		{
			name:       "under minimum",
			saved:      settings{Theme: themeDark, WindowWidth: 640, WindowHeight: 480},
			wantWidth:  minWindowWidth,
			wantHeight: minWindowHeight,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			st := store.At(t.TempDir())
			if err := st.Save(settingsFile, test.saved); err != nil {
				t.Fatal(err)
			}
			h := newHarnessWithOptions(t, Options{
				Kernel:    &testKernel{Client: core.NewClient()},
				Store:     st,
				Languages: []string{"zh-Hans"},
			})
			shot := h.driver.Snapshot()
			if shot.Width != test.wantWidth || shot.Height != test.wantHeight {
				t.Fatalf("window opened at %dx%d, want %dx%d", shot.Width, shot.Height, test.wantWidth, test.wantHeight)
			}
			if h.config.Maximized != test.wantMaximized || h.driver.Maximized() != test.wantMaximized {
				t.Fatalf("window opened maximized config=%v driver=%v, want %v", h.config.Maximized, h.driver.Maximized(), test.wantMaximized)
			}
		})
	}
}

// TestWorkbenchWindowClosingPersistsResizedAndMaximizedGeometry covers saving the workbench
// window's final size and maximized state on close without writing per resize frame, skipping
// writes when nothing changed, and restoring the saved geometry on the next launch.
func TestWorkbenchWindowClosingPersistsResizedAndMaximizedGeometry(t *testing.T) {
	openStore := func(t *testing.T, initial settings) (*store.Store, *harness) {
		t.Helper()
		st := store.At(t.TempDir())
		if err := st.Save(settingsFile, initial); err != nil {
			t.Fatal(err)
		}
		h := newHarnessWithOptions(t, Options{
			Kernel:    &testKernel{Client: core.NewClient()},
			Store:     st,
			Languages: []string{"zh-Hans"},
		})
		return st, h
	}

	t.Run("resized writes once on close and reopens at that size", func(t *testing.T) {
		st, h := openStore(t, settings{Theme: themeDark})
		settingsPath := filepath.Join(st.Dir(), settingsFile)
		if err := os.Remove(settingsPath); err != nil {
			t.Fatal(err)
		}
		for _, size := range [][2]int{{1360, 840}, {1480, 900}, {1600, 980}} {
			if err := h.driver.Resize(size[0], size[1]); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := os.Stat(settingsPath); !os.IsNotExist(err) {
			t.Fatalf("live resize wrote settings before close: %v", err)
		}
		h.driver.Close()
		var saved settings
		found, err := st.Load(settingsFile, &saved)
		if err != nil || !found {
			t.Fatalf("load saved settings after close: found=%v err=%v", found, err)
		}
		if saved.WindowWidth != 1600 || saved.WindowHeight != 980 || saved.WindowMaximized || saved.Theme != themeDark {
			t.Fatalf("saved settings = %+v, want 1600x980 non-maximized dark", saved)
		}
		reopened := newHarnessWithOptions(t, Options{
			Kernel:    &testKernel{Client: core.NewClient()},
			Store:     st,
			Languages: []string{"zh-Hans"},
		})
		shot := reopened.driver.Snapshot()
		if shot.Width != 1600 || shot.Height != 980 || reopened.driver.Maximized() {
			t.Fatalf("reopened window = %dx%d maximized=%v, want 1600x980 maximized=false", shot.Width, shot.Height, reopened.driver.Maximized())
		}
	})

	t.Run("moved only does not write settings on close", func(t *testing.T) {
		st, h := openStore(t, settings{Theme: themeDark, WindowWidth: 1440, WindowHeight: 900})
		settingsPath := filepath.Join(st.Dir(), settingsFile)
		if err := os.Remove(settingsPath); err != nil {
			t.Fatal(err)
		}
		if err := h.driver.MoveWindow(80, 60); err != nil {
			t.Fatal(err)
		}
		h.driver.Close()
		if _, err := os.Stat(settingsPath); !os.IsNotExist(err) {
			t.Fatalf("move-only close wrote settings: %v", err)
		}
	})

	t.Run("resized back to opening size does not write settings on close", func(t *testing.T) {
		st, h := openStore(t, settings{Theme: themeDark, WindowWidth: 1440, WindowHeight: 900})
		settingsPath := filepath.Join(st.Dir(), settingsFile)
		if err := os.Remove(settingsPath); err != nil {
			t.Fatal(err)
		}
		if err := h.driver.Resize(1600, 960); err != nil {
			t.Fatal(err)
		}
		if err := h.driver.Resize(1440, 900); err != nil {
			t.Fatal(err)
		}
		h.driver.Close()
		if _, err := os.Stat(settingsPath); !os.IsNotExist(err) {
			t.Fatalf("close at opening size wrote settings: %v", err)
		}
	})

	t.Run("maximized preserves floating size and restores on next launch", func(t *testing.T) {
		st, h := openStore(t, settings{Theme: themeDark})
		if err := h.driver.Resize(1520, 920); err != nil {
			t.Fatal(err)
		}
		if err := h.driver.SetMaximized(true); err != nil {
			t.Fatal(err)
		}
		h.driver.Close()

		var saved settings
		found, err := st.Load(settingsFile, &saved)
		if err != nil || !found {
			t.Fatalf("load saved settings: found=%v err=%v", found, err)
		}
		if saved.WindowWidth != 1520 || saved.WindowHeight != 920 || !saved.WindowMaximized {
			t.Fatalf("saved maximized settings = %dx%d maximized=%v, want 1520x920 maximized=true", saved.WindowWidth, saved.WindowHeight, saved.WindowMaximized)
		}

		// Reopening maximized and closing unchanged does not write again.
		reopened := newHarnessWithOptions(t, Options{
			Kernel:    &testKernel{Client: core.NewClient()},
			Store:     st,
			Languages: []string{"zh-Hans"},
		})
		if !reopened.driver.Maximized() || reopened.config.Width != 1520 || reopened.config.Height != 920 {
			t.Fatalf("reopened maximized = %dx%d maximized=%v, want 1520x920 maximized=true", reopened.config.Width, reopened.config.Height, reopened.driver.Maximized())
		}
		settingsPath := filepath.Join(st.Dir(), settingsFile)
		if err := os.Remove(settingsPath); err != nil {
			t.Fatal(err)
		}
		reopened.driver.Close()
		if _, err := os.Stat(settingsPath); !os.IsNotExist(err) {
			t.Fatalf("unchanged maximized close wrote settings: %v", err)
		}

		// Restoring from maximized and closing persists WindowMaximized=false while keeping floating size.
		if err := st.Save(settingsFile, saved); err != nil {
			t.Fatal(err)
		}
		restored := newHarnessWithOptions(t, Options{
			Kernel:    &testKernel{Client: core.NewClient()},
			Store:     st,
			Languages: []string{"zh-Hans"},
		})
		if err := restored.driver.SetMaximized(false); err != nil {
			t.Fatal(err)
		}
		restored.driver.Close()
		var afterRestore settings
		found, err = st.Load(settingsFile, &afterRestore)
		if err != nil || !found {
			t.Fatalf("load settings after restore: found=%v err=%v", found, err)
		}
		if afterRestore.WindowWidth != 1520 || afterRestore.WindowHeight != 920 || afterRestore.WindowMaximized {
			t.Fatalf("after restore = %dx%d maximized=%v, want 1520x920 maximized=false", afterRestore.WindowWidth, afterRestore.WindowHeight, afterRestore.WindowMaximized)
		}
	})

	t.Run("resize saved alongside another setting still updates if resized back before close", func(t *testing.T) {
		st, h := openStore(t, settings{Theme: themeDark})
		if err := h.driver.Resize(1600, 980); err != nil {
			t.Fatal(err)
		}
		h.app.setLanguage("en")
		if err := h.driver.Resize(defaultWindowWidth, defaultWindowHeight); err != nil {
			t.Fatal(err)
		}
		h.driver.Close()

		var saved settings
		found, err := st.Load(settingsFile, &saved)
		if err != nil || !found {
			t.Fatalf("load saved settings: found=%v err=%v", found, err)
		}
		if saved.WindowWidth != defaultWindowWidth || saved.WindowHeight != defaultWindowHeight || saved.Language != "en" {
			t.Fatalf("saved settings = %dx%d lang=%q, want %dx%d lang=en", saved.WindowWidth, saved.WindowHeight, saved.Language, defaultWindowWidth, defaultWindowHeight)
		}
	})
}

// TestWorkbenchWindowSizeSurvivesOtherProjectTabSave covers a window with multiple project
// tabs: resizing the window and saving a setting from another tab preserves the new window
// size across every tab without writing an older size back.
func TestWorkbenchWindowSizeSurvivesOtherProjectTabSave(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	second := h.app.sessions.active
	if second == h.app {
		t.Fatal("beta did not open in a second tab")
	}
	if err := h.driver.Resize(1560, 940); err != nil {
		t.Fatal(err)
	}
	second.setLanguage("en")
	var saved settings
	if found, err := h.store.Load(settingsFile, &saved); err != nil || !found {
		t.Fatalf("load saved settings: found=%v err=%v", found, err)
	}
	if saved.WindowWidth != 1560 || saved.WindowHeight != 940 || saved.Language != "en" {
		t.Fatalf("saved settings = %dx%d lang=%q, want 1560x940 lang=en", saved.WindowWidth, saved.WindowHeight, saved.Language)
	}
	if h.app.settings.WindowWidth != 1560 || h.app.settings.WindowHeight != 940 {
		t.Fatalf("first tab kept stale window size %dx%d, want 1560x940", h.app.settings.WindowWidth, h.app.settings.WindowHeight)
	}
}
