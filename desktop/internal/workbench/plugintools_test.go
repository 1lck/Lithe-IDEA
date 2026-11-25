package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
)

const (
	webPanelPlugin = "dev.lithe.fixture.web-panel"
	webPanelWindow = pluginItemPrefix + webPanelPlugin + ".window"
	webPanelNotes  = pluginItemPrefix + webPanelPlugin + ".notes"
)

func TestPluginToolWindowUsesPackageIconAcrossThemes(t *testing.T) {
	directory := t.TempDir()
	for name, color := range map[string]string{"light.svg": "#FF0000", "dark.svg": "#0000FF"} {
		data := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M1 1H15V15H1Z" fill="` + color + `"/></svg>`
		if err := os.WriteFile(filepath.Join(directory, name), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, mode := range []string{pluginicons.ModeOriginal, pluginicons.ModeTemplate} {
		t.Run(mode, func(t *testing.T) {
			tool := pluginservice.ToolWindow{
				PluginID: "dev.lithe.test.tool-icon", ID: "dev.lithe.test.tool-icon.window", Package: directory,
				Icon: pluginicons.Declaration{Path: "light.svg", DarkPath: "dark.svg", Mode: mode},
			}
			app := App{chrome: newChromeState()}
			app.chrome.setItems(pluginItems([]pluginservice.ToolWindow{tool}, nil))
			if err := app.pluginIcons.Read(tool.PluginID, directory, tool.Icon); err != nil {
				t.Fatal(err)
			}
			index := app.chrome.index[pluginItemPrefix+tool.ID]
			for _, dark := range []bool{false, true} {
				app.colors.Dark = dark
				icon := app.chromeItemIcon(index)
				if icon == nil {
					t.Fatal("declared package icon is missing")
				}
				if mode == pluginicons.ModeTemplate {
					if len(icon.Commands) == 0 || len(icon.Layers) != 0 || icon.Stroke != 0 {
						t.Fatalf("template icon does not use the control tint: %+v", icon)
					}
				} else if len(icon.Layers) != 1 || (!dark && icon.Layers[0].Fill.Red != 1) || (dark && icon.Layers[0].Fill.Blue != 1) {
					t.Fatalf("dark=%v: package theme variant = %+v", dark, icon)
				}
			}
		})
	}
}

// webPanelHarness installs the shared web-panel fixture, which declares a web window
// on the right and a text window at the bottom, and opens a project.
func webPanelHarness(t *testing.T) (*harness, *store.Store) {
	t.Helper()
	return webPanelHarnessWithDriver(t, "dark", "zh-Hans", nil)
}

// webPanelHarnessWithDriver lets visual tests use the same fixture and cleanup.
func webPanelHarnessWithDriver(t *testing.T, theme, language string, open func(app.Config) (*app.Driver, func(), error)) (*harness, *store.Store) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"`+theme+`"}`), 0o600); err != nil {
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
	options := Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{language},
	}
	var h *harness
	if open == nil {
		h = newHarnessWithOptions(t, options)
	} else {
		h = newHarnessWithDriver(t, options, open)
	}
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
	h.config.Web.OnReady()
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

// A window initializes its WebHost once; project tabs keep their own page objects and bridge
// state. The headless engine cannot open a WebView, so each page reports that failure itself.
func TestPluginToolWindowsKeepWebPagesPerProjectTab(t *testing.T) {
	const windowID = webPanelPlugin + ".window"
	for _, readyBeforeTab := range []bool{true, false} {
		name := "ready-after-tab"
		if readyBeforeTab {
			name = "ready-before-tab"
		}
		t.Run(name, func(t *testing.T) {
			h, _ := webPanelHarness(t)
			t.Cleanup(h.disposeTabs)
			h.app.settings.ProjectOpenDestination = settingswindow.ProjectOpenThisWindow
			if readyBeforeTab {
				h.config.Web.OnReady()
			}
			h.chromeAction(core.SetChromeOpen(webPanelWindow, true))
			firstPage := h.app.pluginPages[webPanelWindow]
			if readyBeforeTab && (firstPage == nil || firstPage.failure == "") {
				t.Fatal("the first project's page did not leave the loading state")
			}
			firstProject := h.app.project
			firstHost := &pluginPageHost{plugins: h.app.plugins, project: firstProject, stateLimit: 128}
			if err := firstHost.SetState(t.Context(), webPanelPlugin, windowID, []byte(`{"tab":"alpha"}`)); err != nil {
				t.Fatal(err)
			}

			h.app.openProject(t.TempDir())
			h.settleTabs()
			second := h.app.sessions.active
			if second == h.app {
				t.Fatal("the second project did not open in a new tab")
			}
			second.reduceChrome(core.SetChromeOpen(webPanelWindow, true))
			second.invalidator.Invalidate()
			h.settleTabs()
			if !readyBeforeTab {
				if !h.showsWrapped("正在打开…") || second.pluginPages[webPanelWindow] != nil {
					t.Fatal("the page did not wait for the window's web host")
				}
				h.config.Web.OnReady()
				h.settleTabs()
			}
			secondPage := second.pluginPages[webPanelWindow]
			if h.showsWrapped("正在打开…") || secondPage == nil || secondPage.failure == "" || secondPage.page != nil {
				t.Fatalf("second project's page = %+v, want the headless engine's unsupported failure", secondPage)
			}
			if (firstPage != nil && firstPage == secondPage) || secondPage.project != second.project || h.app.pluginPages[webPanelWindow] != firstPage {
				t.Fatal("the second project reused or reassigned the first project's page")
			}
			if !h.showsWrapped("无法显示此窗口") {
				t.Fatal("the web window did not report the headless engine's failure")
			}
			secondHost := &pluginPageHost{plugins: second.plugins, project: second.project, stateLimit: 128}
			if state, err := secondHost.State(t.Context(), webPanelPlugin, windowID); err != nil || len(state) != 0 {
				t.Fatalf("the second project inherited another project's page state: %s, %v", state, err)
			}
			if err := secondHost.SetState(t.Context(), webPanelPlugin, windowID, []byte(`{"tab":"beta"}`)); err != nil {
				t.Fatal(err)
			}
			for _, projectState := range []struct {
				host *pluginPageHost
				want string
			}{{firstHost, `{"tab":"alpha"}`}, {secondHost, `{"tab":"beta"}`}} {
				if state, err := projectState.host.State(t.Context(), webPanelPlugin, windowID); err != nil || string(state) != projectState.want {
					t.Fatalf("project page state = %s, %v; want %s", state, err, projectState.want)
				}
			}

			h.app.sessions.activate(h.app)
			h.settleTabs()
			if page := h.app.pluginPages[webPanelWindow]; page == nil || page == secondPage || page.project != firstProject || (firstPage != nil && page != firstPage) {
				t.Fatal("switching projects changed the first project's page")
			}
			second.reduceChrome(core.SetChromeOpen(webPanelWindow, false))
			h.app.sessions.activate(second)
			h.settleTabs()
			if len(second.pluginPages) != 0 || h.app.pluginPages[webPanelWindow] == nil {
				t.Fatal("hiding one project's web page changed another project's page")
			}
		})
	}
}
