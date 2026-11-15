package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const (
	webPanelPlugin = "dev.lithe.fixture.web-panel"
	webPanelWindow = pluginItemPrefix + webPanelPlugin + ".window"
	webPanelNotes  = pluginItemPrefix + webPanelPlugin + ".notes"
)

// webPanelHarness installs the shared web-panel fixture, which declares a web window
// on the right and a text window at the bottom, and opens a project.
func webPanelHarness(t *testing.T) (*harness, *store.Store) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, webPanelPlugin, "1.0.0")
	if err := os.MkdirAll(filepath.Join(installed, "ui"), 0o700); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/ui/web-panel.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{"plugin.json": manifest, "ui/index.html": []byte("<!doctype html><title>Panel</title>")} {
		if err := os.WriteFile(filepath.Join(installed, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := pluginstate.New(preferences).SetEnabled(webPanelPlugin, true); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"zh-Hans"},
	})
	h.open(t.TempDir())
	h.app.reloadPluginLanguages()
	h.settle()
	return h, preferences
}

func TestPluginToolWindowsDockAndShowTheirContent(t *testing.T) {
	h, _ := webPanelHarness(t)
	if got := h.zoneItems(zoneRightTop); !slices.Contains(got, webPanelWindow) {
		t.Fatalf("right zone = %v, want the web window", got)
	}
	if got := h.zoneItems(zoneBottomLeft); !slices.Contains(got, webPanelNotes) {
		t.Fatalf("bottom zone = %v, want the text window", got)
	}
	h.button(webPanelNotes)

	h.chromeAction(core.SetChromeOpen(webPanelNotes, true))
	if !h.shows("A plugin may mix text and web windows.") {
		t.Fatal("the text window does not show its text")
	}

	// Before the window's web host is ready the page waits; the headless driver has no
	// web engine, so once it is "ready" the page registers with Core and then reports
	// that it cannot be shown.
	h.chromeAction(core.SetChromeOpen(webPanelWindow, true))
	if !h.showsWrapped("正在打开…") {
		t.Fatal("the web window does not say it is opening")
	}
	h.app.webReady = true
	h.app.invalidator.Invalidate()
	h.settle()
	if page := h.app.pluginPages[webPanelWindow]; page == nil || page.failure == "" || page.page != nil {
		t.Fatalf("page = %+v, want a failure without an open page", page)
	}
	if !h.showsWrapped("无法显示此窗口") {
		t.Fatal("the web window does not say why it cannot be shown")
	}

	// Hiding the window ends its page.
	h.chromeAction(core.SetChromeOpen(webPanelWindow, false))
	if len(h.app.pluginPages) != 0 {
		t.Fatalf("pages = %v after the window was hidden", h.app.pluginPages)
	}
}

// A disabled plugin's windows leave the stripes, and come back where the user had moved
// them, even after the layout was saved while they were gone.
func TestPluginToolWindowsKeepTheirPlacesWhileDisabled(t *testing.T) {
	h, preferences := webPanelHarness(t)
	h.chromeAction(core.MoveChrome(webPanelNotes, zoneNames[zoneBottomRight], ""))
	if got := h.app.chrome.zoneOf(h.app.chrome.index[webPanelNotes]); got != zoneBottomRight {
		t.Fatalf("moved text window is in zone %d", got)
	}

	if err := pluginstate.New(preferences).SetEnabled(webPanelPlugin, false); err != nil {
		t.Fatal(err)
	}
	h.app.reloadPluginLanguages()
	h.settle()
	if _, known := h.app.chrome.index[webPanelNotes]; known {
		t.Fatal("a disabled plugin's window stayed in the catalog")
	}
	for z := range zoneCount {
		if slices.Contains(h.zoneItems(z), webPanelNotes) {
			t.Fatalf("zone %d still shows the disabled plugin's window", z)
		}
	}
	// A change saved while the plugin is disabled keeps its window's place.
	h.chromeAction(core.MoveChrome(itemCommit, zoneNames[zoneBottomLeft], ""))
	var saved core.ChromeLayout
	if found, err := h.store.Load(layoutFile, &saved); err != nil || !found {
		t.Fatalf("saved layout found = %v, err = %v", found, err)
	}
	kept := false
	for _, placement := range saved.Placements {
		kept = kept || placement.ID == webPanelNotes && placement.Zone == zoneNames[zoneBottomRight]
	}
	if !kept {
		t.Fatalf("the saved layout lost the disabled window's place: %+v", saved.Placements)
	}

	if err := pluginstate.New(preferences).SetEnabled(webPanelPlugin, true); err != nil {
		t.Fatal(err)
	}
	h.app.reloadPluginLanguages()
	h.settle()
	if got := h.app.chrome.zoneOf(h.app.chrome.index[webPanelNotes]); got != zoneBottomRight {
		t.Fatalf("the returning window is in zone %d, want where it was moved", got)
	}
	if got := h.app.chrome.zoneOf(catalogIndex[itemCommit]); got != zoneBottomLeft {
		t.Fatalf("the commit button moved back to zone %d", got)
	}
}

// chromeAction applies a layout action and paints its result.
func (h *harness) chromeAction(action core.ChromeAction) {
	h.t.Helper()
	h.app.reduceChrome(action)
	h.app.invalidator.Invalidate()
	h.settle()
}
