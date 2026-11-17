//go:build vivahead

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualServiceDebugWithoutAnAdapter captures the notice Debug shows on a service run whose
// declared debug type no enabled adapter answers to, as a toast and in the notification history
// (#2107).
func TestVisualServiceDebugWithoutAnAdapter(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, scene := range []struct{ theme, language string }{{"light", "zh-CN"}, {"dark", "en-US"}} {
		name := scene.theme + "-" + scene.language
		t.Run(name, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": scene.theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			// An empty plugin root: no plugin is installed, so no adapter answers the run's type.
			options := Options{
				Kernel: &testKernel{Client: core.NewClient()}, PluginKernel: &testKernel{Client: core.NewClient()},
				PluginRoot: t.TempDir(), Store: prefs, Languages: []string{scene.language},
			}
			h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 800
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(runConfigRoot(t))
			p := h.app.project
			h.app.post(func(a *App) {
				instance := runConfigInstance("app")
				instance.System.Runs = []pluginservice.BuildRunDeclaration{{
					ID: "service", Name: "Serve", Execution: "service", Tags: []string{"app"}, DebugConfigurationType: "fixture-attach",
				}}
				p.build.loaded = true
				p.build.instances = []buildInstance{instance}
				a.refreshRunConfigurations(p)
			})
			awaitStateWithin(t, h, 10*time.Second, "the run configurations", func() bool { return p.runConfigs.generation > 0 && !p.runConfigs.loading })
			language := h.app.language()
			want := i18n.SharedFormat(language, "desktop.build.noConnectionDebugAdapter", map[string]string{"type": "fixture-attach"})
			h.app.post(func(a *App) { a.titleDebug(p) })
			awaitStateWithin(t, h, 10*time.Second, "the refusal", func() bool { return lastNotice(h) == want })
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "service-debug-no-adapter-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			// The toast shows one line; the notification history holds the whole notice.
			h.click(center(h.button(itemNotifications)))
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "service-debug-no-adapter-history-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			if !h.shows(want) {
				t.Fatal("the notification history did not paint the whole notice")
			}
			if p.build.operation != nil || p.debug.activeSession() != nil {
				t.Fatal("a refused debug started something")
			}
		})
	}
}
