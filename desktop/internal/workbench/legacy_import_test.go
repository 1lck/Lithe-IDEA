package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/legacyimport"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
)

func earlierLithe(recent string) legacyimport.Found {
	return legacyimport.Found{
		Source:             "app.lithe.desktop",
		Language:           new("en"),
		Theme:              new("light"),
		HideMinimap:        new(true),
		EditorTabRows:      new("multiple"),
		TerminalShell:      new("/bin/bash"),
		ProcessTermination: &legacyimport.ProcessTermination{TerminalOnQuit: "terminate"},
		EditorFont:         &legacyimport.Font{Family: "Menlo", Size: 15},
		Recent:             []legacyimport.Recent{{Path: recent, OpenedAt: 1000}},
	}
}

// The dialog lists what the earlier client stored; importing applies the chosen items,
// leaves the unchosen theme alone, adds the recent project with its own time and saves
// both files.
func TestLegacyImportAppliesTheChosenSettings(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	recent := filepath.Join(t.TempDir(), "earlier")
	h.app.legacyImport.read = func(context.Context) (legacyimport.Found, error) { return earlierLithe(recent), nil }
	s := &h.app.legacyImport
	h.app.post((*App).readLegacyImport)
	awaitStateWithin(t, h, 10*time.Second, "the import dialog", func() bool { return s.open })
	h.settle()
	language := h.app.language()
	if !h.shows(i18n.Shared(language, "desktop.legacyImport.title")) || !h.shows("Menlo · 15 pt") {
		t.Fatal("the dialog does not list the earlier settings")
	}
	if len(s.items) != 8 {
		t.Fatalf("items = %+v", s.items)
	}
	h.app.post(func(*App) {
		for index := range s.items {
			if s.items[index].item == legacyTheme {
				s.items[index].chosen = false
			}
		}
	})
	h.settle()
	confirm := h.hitLabeled(i18n.Shared(language, "desktop.legacyImport.confirm"))
	h.click(gfx.Point{X: confirm.X + confirm.Width/2, Y: confirm.Y + confirm.Height/2})
	if s.open {
		t.Fatal("the dialog stayed open")
	}
	got := h.app.settings
	if got.Language != "en" || got.Theme != themeDark || !got.HideMinimap || got.EditorTabRows != "multiple" || got.TerminalShell != "/bin/bash" {
		t.Fatalf("settings = %+v", got)
	}
	if p := got.ProcessTermination; p.TerminalOnQuit != "terminate" || p.RunServicesOnExit != "" || p.ConfirmTerminalTabClose == nil || *p.ConfirmTerminalTabClose {
		t.Fatalf("process termination = %+v", p)
	}
	if editor, terminal := fontprefs.For(got.Fonts, fontprefs.Editor), fontprefs.For(got.Fonts, fontprefs.Terminal); editor.Family != "Menlo" || editor.Size != 15 || terminal.Family != "" {
		t.Fatalf("fonts = %+v", got.Fonts)
	}
	var stored settings
	if _, err := h.store.Load(settingsFile, &stored); err != nil || stored.Language != "en" || stored.TerminalShell != "/bin/bash" {
		t.Fatalf("stored = %+v, %v", stored, err)
	}
	var entries []core.RecentProject
	if _, err := h.store.Load(recentFile, &entries); err != nil ||
		!slices.ContainsFunc(entries, func(e core.RecentProject) bool { return e.Path == recent && e.LastOpenedAt == 1000 }) {
		t.Fatalf("recent = %+v, %v", entries, err)
	}
	want := i18n.SharedFormat(i18n.English, "desktop.legacyImport.done", map[string]string{"recent": "1"})
	if h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
}

// Nothing found says so and opens no dialog.
func TestLegacyImportWithoutAnEarlierClient(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	h.app.legacyImport.read = func(context.Context) (legacyimport.Found, error) {
		return legacyimport.Found{}, legacyimport.ErrNotFound
	}
	h.app.post((*App).readLegacyImport)
	want := i18n.Shared(h.app.language(), "desktop.legacyImport.none")
	awaitStateWithin(t, h, 10*time.Second, "the notice", func() bool { return h.app.notice == want })
	if h.app.legacyImport.open || h.app.legacyImport.reading {
		t.Fatalf("state = %+v", h.app.legacyImport)
	}
}

func TestLegacyFontsTakeOnlyTheirScope(t *testing.T) {
	current := []fontprefs.Font{{Family: "Fira Code", Size: 12, LineSpacing: 1.4, Scopes: slices.Clone(fontprefs.Scopes)}}
	found := legacyimport.Found{TerminalFont: &legacyimport.Font{Family: "Menlo"}}
	fonts, ok := legacyFonts(current, found, true, true)
	if !ok {
		t.Fatal("no fonts")
	}
	fonts = fontprefs.Normalize(fonts)
	terminal, editor := fontprefs.For(fonts, fontprefs.Terminal), fontprefs.For(fonts, fontprefs.Editor)
	if terminal.Family != "Menlo" || terminal.Size != 12 || terminal.LineSpacing != 1.4 || editor.Family != "Fira Code" {
		t.Fatalf("terminal = %+v editor = %+v", terminal, editor)
	}
	if _, ok := legacyFonts(current, found, true, false); ok {
		t.Fatal("an unchosen font was taken")
	}
}

// Plugins alone open the dialog; it lists only those this client has not installed.
func TestLegacyImportListsMissingPlugins(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.settle()
	h.app.pluginState.Store(&map[string]settingswindow.PluginState{"dev.example.java": {Installed: true}})
	h.app.legacyImport.read = func(context.Context) (legacyimport.Found, error) {
		return legacyimport.Found{Source: "app.lithe.desktop", Plugins: []legacyimport.Plugin{
			{ID: "dev.example.java", Name: "Java Support"}, {ID: "dev.example.db", Name: "Database Tools"},
		}}, nil
	}
	s := &h.app.legacyImport
	h.app.post((*App).readLegacyImport)
	awaitStateWithin(t, h, 10*time.Second, "the import dialog", func() bool { return s.open })
	h.settle()
	if !h.shows("Database Tools") || h.shows("Java Support") || len(s.items) != 0 {
		t.Fatalf("plugins = %+v items = %+v", s.plugins, s.items)
	}
	if !h.shows(i18n.Shared(h.app.language(), "desktop.legacyImport.openMarketplace")) {
		t.Fatal("the marketplace button is not shown")
	}

	// Once every earlier plugin is installed, nothing is left to import.
	h.app.post(func(a *App) { a.legacyImport.open = false })
	h.app.pluginState.Store(&map[string]settingswindow.PluginState{"dev.example.java": {Installed: true}, "dev.example.db": {Installed: true}})
	h.app.post((*App).readLegacyImport)
	want := i18n.Shared(h.app.language(), "desktop.legacyImport.none")
	awaitStateWithin(t, h, 10*time.Second, "the notice", func() bool { return h.app.notice == want })
	if s.open {
		t.Fatal("the dialog opened with nothing to import")
	}
}
