//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualPluginWebProjectTabs captures the actual loading and engine-failure surfaces in
// the second project. It uses the contract fixture; headless has no native web engine.
func TestVisualPluginWebProjectTabs(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				var session *headless.Session
				h, _ := webPanelHarnessWithDriver(t, theme, language, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1100, 720
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				t.Cleanup(h.disposeTabs)
				h.app.settings.ProjectOpenDestination = settingswindow.ProjectOpenThisWindow
				h.app.openProject(t.TempDir())
				h.settleTabs()
				second := h.app.sessions.active
				second.reduceChrome(core.SetChromeOpen(webPanelWindow, true))
				second.invalidator.Invalidate()
				h.settleTabs()
				if !h.showsWrapped(i18n.Shared(second.language(), "desktop.pluginWeb.loading")) {
					t.Fatal("the second project's web window did not show the loading surface")
				}
				capture := func(scene string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, scene+"-"+theme+"-"+language+".png")); err != nil {
						t.Fatal(err)
					}
				}
				capture("project-web-loading")
				h.config.Web.OnReady()
				h.settleTabs()
				if page := second.pluginPages[webPanelWindow]; page == nil || page.failure == "" || h.showsWrapped(i18n.Shared(second.language(), "desktop.pluginWeb.loading")) {
					t.Fatal("the second project's web window stayed on the loading surface")
				}
				capture("project-web-unavailable")
			})
		}
	}
}
