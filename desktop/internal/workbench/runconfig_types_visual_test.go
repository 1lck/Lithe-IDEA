//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualPluginDeclaredRuns captures a kind a plugin declares in the Run/Debug
// Configurations dialog: the + menu that lists it after the built-in kinds, its editor with
// the plugin's fields and the multiple-instances switch, and the Run window with two
// instances of it running side by side. It needs only LITHE_VISUAL_OUTPUT_DIR; the dark
// captures read the plugin's Chinese translation and the light ones its English manifest.
func TestVisualPluginDeclaredRuns(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		t.Run(look.theme, func(t *testing.T) {
			options, root := runTypesOptions(t, look.theme, look.language, "hang", true)
			var session *headless.Session
			h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			// shot draws the window as it is; the hanging instances keep background work going,
			// so it pumps a few frames instead of waiting for every task.
			shot := func(scene string) {
				t.Helper()
				for range 4 {
					if err := h.driver.Pump(); err != nil {
						t.Fatal(err)
					}
				}
				if err := session.Screenshot(filepath.Join(out, "declared-run-"+scene+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
			h.openTree(t, root)
			p := awaitRunTypes(t, h, true)
			d := &p.runConfigs.dialog

			h.app.post(func(a *App) {
				a.openRunConfigDialog(p, "")
				d.newMenu = runConfigNewMenuToolbar
			})
			awaitStateWithin(t, h, 10*time.Second, "the kinds the dialog reads", func() bool { return !p.runConfigs.typesLoading })
			h.settleChain()
			shot("new-menu")
			h.app.post(func(*App) { d.newMenu = runConfigNewMenuClosed })

			f := newDeclaredRunDraft(t, h, p)
			fillDeclaredRun(t, h, p, f, "Fixture Alpha", true)
			h.settleChain()
			shot("form")

			applyDialog(t, h, p, runConfigDialogOK)
			id := p.runConfigs.list[0].ID
			running := func() int {
				count := 0
				for _, entry := range p.build.runs {
					if entry.running && entry.output.all() != "" {
						count++
					}
				}
				return count
			}
			defer func() {
				h.app.post(func(a *App) {
					for _, op := range append([]*buildOperation(nil), p.build.running...) {
						a.stopOperation(p, op)
					}
				})
				awaitStateWithin(t, h, 20*time.Second, "every instance to end", func() bool { return len(p.build.running) == 0 })
			}()
			h.app.post(func(a *App) { a.runConfiguration(p, id) })
			awaitStateWithin(t, h, 20*time.Second, "the first instance", func() bool { return running() == 1 })
			h.app.post(func(a *App) { a.runConfiguration(p, id) })
			awaitStateWithin(t, h, 20*time.Second, "the second instance", func() bool { return running() == 2 })
			shot("two-instances")
		})
	}
}
