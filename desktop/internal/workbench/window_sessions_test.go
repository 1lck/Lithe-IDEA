package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// newTabsHarness makes a window that opens projects in this window, over two project folders
// named alpha and beta. Its cleanup closes the projects of the tabs the test opened beside the
// first, before the harness disposes of the first.
func newTabsHarness(t *testing.T) (h *harness, alpha, beta string) {
	t.Helper()
	h = newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.settings.ProjectOpenDestination = settingswindow.ProjectOpenThisWindow
	root := t.TempDir()
	alpha, beta = filepath.Join(root, "alpha"), filepath.Join(root, "beta")
	for _, dir := range []string{alpha, beta} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { h.disposeTabs() })
	return h, alpha, beta
}

// settleTabs lets the background work of every tab finish and paints its results.
func (h *harness) settleTabs() {
	h.t.Helper()
	for _, a := range h.app.sessions.everyOne() {
		a.wait()
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatalf("Pump: %v", err)
	}
}

// disposeTabs closes the project of every tab but the first, within a bounded wait.
func (h *harness) disposeTabs() {
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	for _, a := range h.app.sessions.everyOne() {
		if a == h.app {
			continue
		}
		a.closeProject()
		for a.project != nil && a.closingProject {
			select {
			case <-h.driver.Wakes():
				if err := h.driver.Pump(); err != nil {
					h.t.Errorf("cleanup pump: %v", err)
				}
			case <-deadline.C:
				h.t.Error("tab cleanup did not finish before its deadline")
				return
			}
		}
		a.stopAllPluginServers()
		a.wait()
	}
}

// shownRoot is the project folder of the tab the window shows, or "".
func (h *harness) shownRoot() string {
	if p := h.app.sessions.active.project; p != nil {
		return p.root
	}
	return ""
}

// This Window opens a second project in a tab beside the first instead of replacing it. The
// strip of project tabs shows both, and clicking a tab shows its project.
func TestThisWindowOpensTheProjectInAProjectTab(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	if h.app.sessions.stripHeight() != 0 {
		t.Fatal("a window with one project shows the strip of project tabs")
	}
	h.app.openProject(beta)
	h.settleTabs()
	s := h.app.sessions
	if len(s.list) != 2 || s.active == h.app {
		t.Fatalf("tabs = %d, the first shown = %v; want beta in a second, shown tab", len(s.list), s.active == h.app)
	}
	if !sameProjectRoot(beta, h.shownRoot()) || !sameProjectRoot(alpha, h.app.project.root) {
		t.Fatalf("shown = %q, first = %q", h.shownRoot(), h.app.project.root)
	}
	h.settleTabs()
	if _, ok := h.findPageHit("alpha"); !ok {
		t.Fatal("the strip has no tab for alpha")
	}
	h.clickNamed("alpha")
	h.settleTabs()
	if s.active != h.app {
		t.Fatal("clicking alpha's tab did not show alpha")
	}
	if _, ok := h.findPageHit("beta"); !ok {
		t.Fatal("alpha's page has no tab for beta")
	}
}

// Opening a project that a tab already has shows that tab instead of opening it again.
func TestOpeningAnOpenProjectShowsItsTab(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	second := h.app.sessions.active
	h.app.sessions.activate(h.app)
	h.app.openProject(beta)
	h.settleTabs()
	if s := h.app.sessions; len(s.list) != 2 || s.active != second {
		t.Fatalf("tabs = %d, second shown = %v; want beta's tab shown again", len(s.list), s.active == second)
	}
}

// Closing a tab's project takes the tab out of the strip and shows the tab beside it. The strip
// goes once one project is left.
func TestClosingAProjectTabShowsTheNextTab(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	second := h.app.sessions.active
	second.closeProject()
	h.await("beta's tab to close", func() bool { return len(h.app.sessions.list) == 1 })
	s := h.app.sessions
	if s.active != h.app || h.app.project == nil || second.project != nil {
		t.Fatalf("first shown = %v, alpha open = %v, beta open = %v", s.active == h.app, h.app.project != nil, second.project != nil)
	}
	if len(s.retired) != 1 || s.retired[0] != second {
		t.Fatal("the closed tab's workbench is not kept until the window closes")
	}
	if s.stripHeight() != 0 {
		t.Fatal("the strip stays with one project left")
	}
}

// Closing the window closes the project of every tab, and the window closes only once all of
// them have.
func TestClosingTheWindowClosesEveryProjectTab(t *testing.T) {
	h, alpha, beta := newTabsHarness(t)
	h.open(alpha)
	h.app.openProject(beta)
	h.settleTabs()
	second := h.app.sessions.active
	allowed := false
	h.config.OnCloseRequest(func() { allowed = true })
	h.await("the window to be allowed to close", func() bool { return allowed })
	if h.app.project != nil || second.project != nil {
		t.Fatalf("alpha open = %v, beta open = %v", h.app.project != nil, second.project != nil)
	}
}
