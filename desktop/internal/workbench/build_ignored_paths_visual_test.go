//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBuildIgnoredPaths captures the Build tool window's top Ignored Paths
// gear tooltip and the Ignored Paths dialog it opens in light/dark themes and
// English/Simplified Chinese (#2152).
func TestVisualBuildIgnoredPaths(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			name := theme + "-" + language
			t.Run(name, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				pluginRoot := t.TempDir()
				installed := filepath.Join(pluginRoot, "dev.lithe.test.ignored-paths", "1.0.0")
				if err := os.MkdirAll(installed, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(ignoredPathsManifest), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := pluginstate.New(prefs).SetEnabled("dev.lithe.test.ignored-paths", true); err != nil {
					t.Fatal(err)
				}
				root := t.TempDir()
				if err := os.WriteFile(filepath.Join(root, "fixture.build"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{
					Kernel:       &testKernel{Client: core.NewClient()},
					PluginKernel: &testKernel{Client: core.NewClient()},
					PluginRoot:   pluginRoot,
					Store:        prefs,
					Languages:    []string{language},
				}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1280, 800
					var err error
					session, err = headless.Open(config, nil, headless.Options{Scale: 1})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.open(root)
				p := h.app.project
				if p == nil {
					t.Fatal("the project did not open")
				}
				h.app.reduceChrome(core.ToggleChrome(itemBuild))
				h.awaitBuildDetection(p)

				triggerLabel := h.shared("desktop.build.ignoredPaths")
				trigger := h.pageHit(triggerLabel)
				at := center(trigger.Bounds)
				if err := h.driver.Move(at.X, at.Y); err != nil {
					t.Fatal(err)
				}
				h.settle()
				if tips := h.tooltips(); len(tips) != 1 || tips[0].Value != triggerLabel {
					t.Fatalf("hovering top Build gear shows tips %+v, want %q", tips, triggerLabel)
				}
				if err := session.Screenshot(filepath.Join(out, "build-ignored-paths-trigger-"+name+".png")); err != nil {
					t.Fatal(err)
				}

				h.clickNamed(triggerLabel)
				h.awaitIgnoredPathsLoaded(p)
				if !h.shows(triggerLabel) {
					t.Fatalf("the opened dialog does not show title %q", triggerLabel)
				}
				if err := session.Screenshot(filepath.Join(out, "build-ignored-paths-dialog-"+name+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
