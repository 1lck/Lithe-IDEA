package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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
		search := h.pageHit(h.app.text.Welcome.SearchLabel).Bounds
		settings := h.pageHit(h.app.text.Welcome.Settings).Bounds
		open := h.pageHit(h.app.text.Welcome.Open).Bounds
		if search.Width > 220 || search.Width <= 0 || search.X+search.Width >= open.X {
			t.Fatalf("at %v search %v overlaps open %v", size, search, open)
		}
		if settings.Y < float32(size[1])-60 || settings.X+settings.Width > welcomeSidebarWidth {
			t.Fatalf("at %v settings %v is not in the sidebar footer", size, settings)
		}
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	h.clickNamed(h.app.text.Welcome.Settings)
	logger.mu.Lock()
	if len(logger.events) != 1 || logger.events[0].Event != "app.action.performed" || logger.events[0].Fields["action"] != "settings.open" {
		logger.mu.Unlock()
		t.Fatal("the welcome settings button did not invoke the settings action")
	}
	logger.mu.Unlock()
	search := h.pageHit(h.app.text.Welcome.SearchLabel)
	// The icon and the text share one search control; clicking the icon must focus input too.
	if err := h.driver.Click(search.Bounds.X+12, search.Bounds.Y+search.Bounds.Height/2); err != nil {
		t.Fatal(err)
	}
	if got := h.driver.Snapshot().Focused; got != search.ID {
		t.Fatalf("clicking the search icon focused %v, want %v", got, search.ID)
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

// welcomeRowHit is the recent project's row in the list.
func (h *harness) welcomeRowHit(path string) gfx.Hit {
	h.t.Helper()
	return h.pageHit(h.app.welcome.row(path, len(h.app.recent)).name)
}

// rightClickRow opens the context menu of the recent project at path.
func (h *harness) rightClickRow(path string) gfx.Point {
	h.t.Helper()
	row := center(h.welcomeRowHit(path).Bounds)
	if err := h.driver.ClickButton(row.X, row.Y, gfx.PointerButtonSecondary); err != nil {
		h.t.Fatal(err)
	}
	return row
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
	h.rightClickRow(dir)
	h.clickNamed(h.app.welcomeRevealLabel())
	h.settle()
	if got, ok := h.driver.LastRevealedPath(); !ok || got != dir {
		t.Fatalf("revealed path = %q, recorded %v; want %q", got, ok, dir)
	}
	h.rightClickRow(missing)
	if err := h.driver.Key(gfx.KeyTab, 0); err != nil {
		t.Fatal(err)
	}
	if _, ok := h.findPageHit(h.app.text.Welcome.MenuRemove); !ok {
		t.Fatal("Tab closed the missing project's menu")
	}
	for _, name := range []string{h.app.welcomeRevealLabel()} {
		if _, ok := h.findPageHit(name); ok {
			t.Fatalf("a missing project offered the %q action", name)
		}
	}
	h.clickNamed(h.app.text.Welcome.MenuRemove)
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
	h.rightClickRow(path)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	h.clickNamed(h.app.welcomeRevealLabel())
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

// Opening a recent project whose folder is gone asks to take it off the list, as the old
// client did: Cancel keeps the entry, Remove from List drops it, and nothing opens.
func TestWelcomeOpeningMissingProjectOffersToRemoveIt(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	path := filepath.Join(t.TempDir(), "private-missing-project")
	h.app.recent = []core.RecentProject{{Path: path}}
	h.app.missing[path] = true
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	open := func() {
		row := center(h.welcomeRowHit(path).Bounds)
		if err := h.driver.Click(row.X, row.Y); err != nil {
			t.Fatal(err)
		}
		h.settle()
		if len(h.app.prompts.queue) != 1 || h.app.prompts.queue[0].title != h.shared("fileSystem.recentProjectUnavailableTitle") {
			t.Fatal("opening a missing project did not ask to remove it")
		}
		if h.app.project != nil {
			t.Fatal("a missing project was opened")
		}
	}

	open()
	h.clickNamed(h.shared("desktop.projectOpen.cancel"))
	h.settle()
	if len(h.app.recent) != 1 || !h.app.missing[path] {
		t.Fatal("Cancel dropped the missing project or its mark")
	}

	open()
	h.clickNamed(h.shared("fileSystem.removeFromList"))
	h.settle()
	if len(h.app.recent) != 0 {
		t.Fatal("Remove from List kept the missing project")
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
	h.rightClickRow(path)
	h.clickNamed(h.app.text.Welcome.MenuRemove)
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
	row := h.rightClickRow(second)
	if h.app.project != nil {
		t.Fatal("right-click opened a project")
	}
	menu := h.pageHit(h.app.text.Welcome.MenuRemove).Bounds
	if menu.X < row.X || menu.Y < row.Y || menu.X > row.X+220 || menu.Y > row.Y+120 {
		t.Fatalf("context menu item at %v; want it near the click %v", menu, row)
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if _, ok := h.findPageHit(h.app.text.Welcome.MenuRemove); ok {
		t.Fatal("Escape did not close the project menu")
	}
	if err := h.driver.Move(row.X, row.Y); err != nil {
		t.Fatal(err)
	}
	h.clickNamed(h.app.text.Welcome.MoreActions)
	if h.app.welcome.menuPath != second || !h.app.welcome.menuOpen || h.app.project != nil {
		t.Fatalf("menu button opened project or the wrong menu: %q", h.app.welcome.menuPath)
	}
	// The reducer can reorder the list while a menu is open. Its action must still
	// apply to the project the menu was opened for, not to whatever now occupies
	// the old index.
	h.app.recent[0], h.app.recent[1] = h.app.recent[1], h.app.recent[0]
	if err := h.driver.Resize(901, 600); err != nil {
		t.Fatal(err)
	}
	h.clickNamed(h.app.text.Welcome.MenuRemove)
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
	path := t.TempDir()
	h.app.recent = []core.RecentProject{{Path: path}}
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	name := h.app.welcome.row(path, 1).name
	more := h.app.text.Welcome.MoreActions
	for i := 0; i < 12 && h.focusedName() != name; i++ {
		if err := h.driver.Key(gfx.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
	}
	if h.focusedName() != name {
		t.Fatal("keyboard focus did not reach the recent project")
	}
	if err := h.driver.Key(gfx.KeyTab, 0); err != nil {
		t.Fatal(err)
	}
	if got := h.focusedName(); got != more {
		t.Fatalf("keyboard focus = %q, want the project menu button", got)
	}
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if h.app.welcome.menuPath != path || !h.app.welcome.menuOpen {
		t.Fatal("keyboard activation did not open the project menu")
	}
	open, reveal, pin, remove := h.app.text.Welcome.MenuOpen, h.app.welcomeRevealLabel(), h.app.text.Welcome.MenuPin, h.app.text.Welcome.MenuRemove
	if _, ok := h.findPageHit(open); !ok {
		t.Fatal("the menu did not show its open action")
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if got := h.focusedName(); got != more {
		t.Fatalf("focus after closing menu = %q, want its button", got)
	}
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{open, reveal, pin, remove} {
		if err := h.driver.Key(gfx.KeyDown, 0); err != nil {
			t.Fatal(err)
		}
		if got := h.focusedName(); got != want {
			t.Fatalf("menu focus = %q, want %q", got, want)
		}
	}
	if err := h.driver.Key(gfx.KeyEnter, 0); err != nil {
		t.Fatal(err)
	}
	if len(h.app.recent) != 0 {
		t.Fatal("keyboard activation did not remove the recent entry")
	}
}
