//go:build vivahead

package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualTitleRunWithoutConfigurations captures the run configuration menu of a project
// whose build plugin declares no run while two saved configurations are hidden, and the
// Run/Debug Configurations dialog Edit Configuration… opens there, counting them (#2028).
func TestVisualTitleRunWithoutConfigurations(t *testing.T) {
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
			root := runConfigRoot(t)
			local := map[string]any{"version": 2, "configurations": []any{
				map[string]any{"id": "java.main:app/server:Main", "name": "Main", "provider": "java.main", "command": "java"},
				map[string]any{"id": "user:boot", "name": "Boot", "provider": "spring-boot.maven", "command": "mvn"},
			}}
			data, err := json.Marshal(local)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(root, ".lithe", "run"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, ".lithe", "run", "local.json"), data, 0o600); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{scene.language}}, func(config app.Config) (*app.Driver, func(), error) {
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
			h.app.post(func(a *App) {
				instance := runConfigInstance("app")
				instance.System.Runs = nil
				p.build.loaded = true
				p.build.instances = []buildInstance{instance}
				a.refreshRunConfigurations(p)
			})
			awaitStateWithin(t, h, 10*time.Second, "the run configurations", func() bool { return p.runConfigs.generation > 0 && !p.runConfigs.loading })
			language := h.app.language()
			h.click(center(h.button(itemRunConfig)))
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "title-run-empty-menu-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			if !h.shows(hiddenRunConfigurations(language, 2)) {
				t.Fatal("the menu did not paint the hidden configurations")
			}
			h.clickNamed(i18n.Shared(language, "native.editConfiguration"))
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "title-run-empty-edit-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			if !p.runConfigs.dialog.open || !h.showsWrapped(hiddenRunConfigurations(language, 2)) {
				t.Fatal("Edit Configuration did not open the dialog counting the hidden configurations")
			}
			h.app.post(func(a *App) { a.closeRunConfigDialog(p) })
		})
	}
}
