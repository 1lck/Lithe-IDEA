//go:build vivahead

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBuildToolbarToggleAndOptionPaths captures the Build window with a toolbar toggle on
// and the build system's own options dialog, whose directory option has a browse button
// (#2202, #2152).
func TestVisualBuildToolbarToggleAndOptionPaths(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := strings.Replace(treeOptionsToolbarManifest, `"options": [{"id": "offline"`,
		`"options": [{"id": "home", "displayName": "Home", "kind": "directory", "environment": {"FIXTURE_HOME": "${value}"}}, {"id": "offline"`, 1)
	for _, scene := range []struct{ theme, language string }{{"light", "zh-CN"}, {"dark", "en-US"}} {
		name := scene.theme + "-" + scene.language
		t.Run(name, func(t *testing.T) {
			preferences, pluginRoot, root := treeOptionsWorkspace(t, manifest, scene.theme)
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()}, PluginKernel: &testKernel{Client: core.NewClient()},
				PluginRoot: pluginRoot, Store: preferences, Languages: []string{scene.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 800
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			p := showTreeOptionsProject(t, h, root)
			instance := p.selectedBuildInstance()
			awaitStateWithin(t, h, 10*time.Second, "the toggle's icon", func() bool {
				_, ok := h.app.pluginIcons.Lookup(instance.PluginID, pluginicons.Declaration{Path: "icons/offline.svg"})
				return ok
			})
			h.app.post(func(a *App) { a.toggleBuildToolbarOption(p, instance.ID, "offline") })
			awaitStateWithin(t, h, 10*time.Second, "the toggle to be on", func() bool {
				instance := p.selectedBuildInstance()
				return !p.build.optionSaving && !p.build.loading && instance != nil && instance.optionOn("offline")
			})
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "build-toolbar-toggle-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			h.clickNamed(h.instanceOptions(p))
			h.settleUntil("the options dialog", func() bool {
				e := &p.build.options
				return e.open && !e.loading && len(e.fields) == 3
			})
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "build-instance-options-"+name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
