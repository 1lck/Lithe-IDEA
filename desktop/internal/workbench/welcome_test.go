package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

func TestWelcomeTitleAndVersionMatchWindowChrome(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.version = "0.6.7"
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	var titleFound, versionFound bool
	for _, label := range h.driver.Snapshot().Labels {
		switch label.Value {
		case "欢迎使用 Lithe":
			titleFound = true
			if runtime.GOOS == "darwin" && (label.Bounds.X < 80 || label.Bounds.X > 120) {
				t.Fatalf("welcome title overlaps the system controls or is centered: %v", label.Bounds)
			}
		case "0.6.7":
			versionFound = true
		case "版本 0.6.7":
			t.Fatal("welcome version includes an extra label absent from the native sidebar")
		}
	}
	if !titleFound || !versionFound {
		t.Fatalf("welcome title shown = %v, version shown = %v", titleFound, versionFound)
	}
}

func TestWelcomeSearchAndSettingsRemainReachableAtWindowSizes(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.app.recent = []core.RecentProject{{Path: "/projects/alpha"}, {Path: "/projects/beta"}}
	if !h.shows("Welcome to Lithe") {
		t.Fatal("the localized welcome window title is not shown")
	}
	for _, size := range [][2]int{{900, 600}, {1280, 800}} {
		if err := h.driver.Resize(size[0], size[1]); err != nil {
			t.Fatal(err)
		}
		if got := h.driver.PressAt(float32(size[0])/2, 20); got != app.PressMove {
			t.Fatalf("at %v the welcome title does not allow dragging: %v", size, got)
		}
		search := h.hit(welcomeSearch)
		settings := h.hit(welcomeNavSettings)
		open := h.hit(welcomeOpen)
		if search.Width > 220 || search.Width <= 0 || search.X+search.Width >= open.X {
			t.Fatalf("at %v search %v overlaps open %v", size, search, open)
		}
		if settings.Y < float32(size[1])-60 || settings.X+settings.Width > welcomeSidebarWidth {
			t.Fatalf("at %v settings %v is not in the sidebar footer", size, settings)
		}
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	settings := center(h.hit(welcomeNavSettings))
	if err := h.driver.Click(settings.X, settings.Y); err != nil {
		t.Fatal(err)
	}
	logger.mu.Lock()
	if len(logger.events) != 1 || logger.events[0].Event != "app.action.performed" || logger.events[0].Fields["action"] != "settings.open" {
		logger.mu.Unlock()
		t.Fatal("the welcome settings button did not invoke the settings action")
	}
	logger.mu.Unlock()
	search := h.hit(welcomeSearch)
	// The icon and the text share one search control; clicking the icon must focus input too.
	if err := h.driver.Click(search.X+12, search.Y+search.Height/2); err != nil {
		t.Fatal(err)
	}
	if got := h.driver.Snapshot().Focused; got != welcomeSearch {
		t.Fatalf("clicking the search icon focused %v, want %v", got, welcomeSearch)
	}
	if err := h.driver.Type("beta"); err != nil {
		t.Fatal(err)
	}
	if !h.shows("beta") || h.shows("alpha") {
		t.Fatal("the welcome search did not filter the project list")
	}
}

func TestWelcomeWindowTitleFollowsLanguage(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	if !h.shows("欢迎使用 Lithe") {
		t.Fatal("the welcome title did not use the selected language")
	}
	h.app.post(func(a *App) { a.setLanguage("en") })
	h.settle()
	if !h.shows("Welcome to Lithe") {
		t.Fatal("the welcome title did not update after the language changed")
	}
}

func TestWelcomeProjectMenuRevealsExistingAndKeepsMissingEntryRemovable(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	dir := t.TempDir()
	missing := filepath.Join(t.TempDir(), "missing")
	h.app.recent = []core.RecentProject{{Path: dir}, {Path: missing}}
	h.app.missing[missing] = true
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	openMenu := func(index int) {
		t.Helper()
		row := center(h.hit(welcomeRows.At(index)))
		if err := h.driver.ClickButton(row.X, row.Y, ui.PointerButtonSecondary); err != nil {
			t.Fatal(err)
		}
	}
	openMenu(0)
	reveal := center(h.hit(welcomeMenuReveal))
	if err := h.driver.Click(reveal.X, reveal.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if got, ok := h.driver.LastRevealedPath(); !ok || got != dir {
		t.Fatalf("revealed path = %q, recorded %v; want %q", got, ok, dir)
	}
	openMenu(1)
	if got := h.driver.Snapshot().Focused; got != welcomeMenuRemove {
		t.Fatalf("missing project menu focus = %v, want remove action", got)
	}
	if err := h.driver.Key(ui.KeyTab, 0); err != nil {
		t.Fatal(err)
	}
	if got := h.driver.Snapshot().Focused; got != welcomeMenuRemove {
		t.Fatalf("missing project menu let focus escape: %v", got)
	}
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == welcomeMenuOpen || hit.ID == welcomeMenuReveal {
			t.Fatal("a missing project offered an open or reveal action")
		}
	}
	remove := center(h.hit(welcomeMenuRemove))
	if err := h.driver.Click(remove.X, remove.Y); err != nil {
		t.Fatal(err)
	}
	if len(h.app.recent) != 1 || h.app.recent[0].Path != dir {
		t.Fatalf("remaining entries = %v", h.app.recent)
	}
}

func TestWelcomeRevealFailureIsReportedAndLoggedWithoutThePath(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	path := filepath.Join(t.TempDir(), "private-project")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	h.app.recent = []core.RecentProject{{Path: path}}
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	row := center(h.hit(welcomeRows.At(0)))
	if err := h.driver.ClickButton(row.X, row.Y, ui.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	reveal := center(h.hit(welcomeMenuReveal))
	if err := h.driver.Click(reveal.X, reveal.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if h.app.notice == "" {
		t.Fatal("failed reveal did not show an error")
	}
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var failure *core.LogEvent
	for i := range logger.events {
		if logger.events[i].Fields["operation"] == "workspace_reveal_recent" {
			failure = &logger.events[i]
		}
	}
	if failure == nil {
		t.Fatalf("failed reveal events = %#v", logger.events)
	}
	if message, ok := failure.Fields["error"].(string); !ok || strings.Contains(message, path) {
		t.Fatalf("failed reveal log leaked the path: %#v", failure.Fields)
	}
}

func TestWelcomeOpeningMissingProjectReportsAndLogsFailure(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	path := filepath.Join(t.TempDir(), "private-missing-project")
	h.app.recent = []core.RecentProject{{Path: path}}
	h.app.missing[path] = true
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	row := center(h.hit(welcomeRows.At(0)))
	if err := h.driver.Click(row.X, row.Y); err != nil {
		t.Fatal(err)
	}
	if h.app.notice == "" || h.app.project != nil {
		t.Fatal("opening a missing project did not show an error")
	}
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var failure *core.LogEvent
	for i := range logger.events {
		if logger.events[i].Fields["operation"] == "workspace_open" {
			failure = &logger.events[i]
		}
	}
	if failure == nil {
		t.Fatal("opening a missing project did not log the failure")
	}
	if message, ok := failure.Fields["error"].(string); !ok || strings.Contains(message, path) {
		t.Fatalf("workspace-open log leaked the path: %#v", failure.Fields)
	}
}

func TestWelcomeRemoveKeepsRecentEntryWhenSavingFails(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	path := t.TempDir()
	h.app.recent = []core.RecentProject{{Path: path}}
	// A directory at the target path makes the atomic rename fail on every platform.
	if err := os.Mkdir(filepath.Join(h.store.Dir(), recentFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	row := center(h.hit(welcomeRows.At(0)))
	if err := h.driver.ClickButton(row.X, row.Y, ui.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	remove := center(h.hit(welcomeMenuRemove))
	if err := h.driver.Click(remove.X, remove.Y); err != nil {
		t.Fatal(err)
	}
	if len(h.app.recent) != 1 || h.app.recent[0].Path != path || h.app.notice == "" {
		t.Fatalf("failed save changed the visible recent list: %#v, notice %q", h.app.recent, h.app.notice)
	}
	logger.mu.Lock()
	defer logger.mu.Unlock()
	for _, event := range logger.events {
		if event.Fields["operation"] == "workspace_recent_save" {
			if message, ok := event.Fields["error"].(string); !ok || strings.Contains(message, h.store.Dir()) {
				t.Fatalf("failed-save log leaked the store path: %#v", event.Fields)
			}
			return
		}
	}
	t.Fatal("failed recent-list save was not logged")
}

func TestWelcomeProjectMenuRemovesOnlyTheChosenRecentEntry(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	first, second := t.TempDir(), t.TempDir()
	h.app.recent = []core.RecentProject{{Path: first}, {Path: second}}
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	row := center(h.hit(welcomeRows.At(1)))
	if err := h.driver.ClickButton(row.X, row.Y, ui.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	if h.app.welcome.menuPath != second || h.app.project != nil {
		t.Fatalf("right-click opened project or the wrong menu: %q", h.app.welcome.menuPath)
	}
	if panel := h.hit(welcomeMenuPanel); panel.X != row.X || panel.Y != row.Y {
		t.Fatalf("context menu at %v; want it at click %v", panel, row)
	}
	if err := h.driver.Key(ui.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.welcome.menuPath != "" {
		t.Fatal("Escape did not close the project menu")
	}
	if err := h.driver.Move(row.X, row.Y); err != nil {
		t.Fatal(err)
	}
	button := center(h.hit(welcomeMenus.At(1)))
	if err := h.driver.Click(button.X, button.Y); err != nil {
		t.Fatal(err)
	}
	if h.app.welcome.menuPath != second || h.app.project != nil {
		t.Fatalf("menu button opened project or the wrong menu: %q", h.app.welcome.menuPath)
	}
	// The reducer can reorder the list while a menu is open. Its action must still
	// apply to the captured path, not to whatever now occupies the old index.
	h.app.recent[0], h.app.recent[1] = h.app.recent[1], h.app.recent[0]
	if err := h.driver.Resize(901, 600); err != nil {
		t.Fatal(err)
	}
	remove := center(h.hit(welcomeMenuRemove))
	if err := h.driver.Click(remove.X, remove.Y); err != nil {
		t.Fatal(err)
	}
	if len(h.app.recent) != 1 || h.app.recent[0].Path != first {
		t.Fatalf("remaining entries = %v", h.app.recent)
	}
	var saved []core.RecentProject
	if found, err := h.store.Load(recentFile, &saved); err != nil || !found || len(saved) != 1 || saved[0].Path != first {
		t.Fatalf("saved entries = %v, found %v, error %v", saved, found, err)
	}
	if _, err := os.Stat(second); err != nil {
		t.Fatalf("removing the recent entry changed its directory: %v", err)
	}
}

func TestWelcomeProjectMenuIsKeyboardReachable(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.app.recent = []core.RecentProject{{Path: t.TempDir()}}
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 12 && h.driver.Snapshot().Focused != welcomeRows.At(0); i++ {
		if err := h.driver.Key(ui.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
	}
	if h.driver.Snapshot().Focused != welcomeRows.At(0) {
		t.Fatal("keyboard focus did not reach the recent project")
	}
	if err := h.driver.Key(ui.KeyTab, 0); err != nil {
		t.Fatal(err)
	}
	if got := h.driver.Snapshot().Focused; got != welcomeMenus.At(0) {
		t.Fatalf("keyboard focus = %v, want the project menu button", got)
	}
	if err := h.driver.Key(ui.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.welcome.menuPath != h.app.recent[0].Path {
		t.Fatal("keyboard activation did not open the project menu")
	}
	if got := h.driver.Snapshot().Focused; got != welcomeMenuOpen {
		t.Fatalf("initial menu focus = %v, want %v", got, welcomeMenuOpen)
	}
	if err := h.driver.Key(ui.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if got := h.driver.Snapshot().Focused; got != welcomeMenus.At(0) {
		t.Fatalf("focus after closing menu = %v, want its button", got)
	}
	if err := h.driver.Key(ui.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	for index, want := range []ui.ID{welcomeMenuReveal, welcomeMenuRemove, welcomeMenuOpen, welcomeMenuReveal, welcomeMenuRemove} {
		if err := h.driver.Key(ui.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
		if got := h.driver.Snapshot().Focused; got != want {
			t.Fatalf("menu focus after tab %d = %v, want %v (open %v, reveal %v, remove %v)", index+1, got, want, welcomeMenuOpen, welcomeMenuReveal, welcomeMenuRemove)
		}
	}
	for _, want := range []ui.ID{welcomeMenuReveal, welcomeMenuOpen, welcomeMenuRemove} {
		if err := h.driver.Key(ui.KeyTab, ui.ModifierShift); err != nil {
			t.Fatal(err)
		}
		if got := h.driver.Snapshot().Focused; got != want {
			t.Fatalf("reverse menu focus = %v, want %v", got, want)
		}
	}
	if err := h.driver.Key(ui.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if len(h.app.recent) != 0 {
		t.Fatal("keyboard activation did not remove the recent entry")
	}
}
