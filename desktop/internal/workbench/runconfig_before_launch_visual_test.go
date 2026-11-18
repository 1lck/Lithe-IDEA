//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBeforeLaunchSteps captures the steps before launch: the Run/Debug Configurations
// window editing a run with two steps, the same list with a step selected and the list of
// configurations to run open, the question before the steps a project file names run, and
// the Run window after the steps and the run. It needs only LITHE_VISUAL_OUTPUT_DIR;
// the dark captures are in Chinese and the light ones in English.
func TestVisualBeforeLaunchSteps(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		theme, language := look.theme, look.language
		t.Run(theme, func(t *testing.T) {
			temporary := t.TempDir()
			for _, variable := range []string{"TMPDIR", "TMP", "TEMP"} {
				t.Setenv(variable, temporary)
			}
			root := filepath.Join(t.TempDir(), "ServiceDemo")
			server := map[string]any{
				"id": "user:server", "name": "Server", "provider": "process.executable", "confidence": "declared",
				"args":         []string{"server", "started"},
				"extensions":   map[string]any{"process": map[string]any{"program": "echo"}},
				"beforeLaunch": []map[string]string{{"configuration": "user:generate"}, {"configuration": "user:frontend"}},
			}
			writeBeforeLaunchDocument(t, root, "configurations.yaml",
				beforeLaunchEcho("user:generate", "generated-sources"),
				beforeLaunchEcho("user:frontend", "frontend-built"),
				beforeLaunchEcho("user:docs", "docs-built"),
				server,
			)
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 820
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			shot := func(scene string) {
				t.Helper()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "before-launch-"+scene+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
			p := h.openTree(t, root)
			h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
			awaitStateWithin(t, h, 10*time.Second, "the configurations", func() bool {
				s := &p.runConfigs
				return s.generation > 0 && !s.loading && s.configuration("user:server") != nil
			})

			d := &p.runConfigs.dialog
			h.app.post(func(a *App) { a.openRunConfigDialog(p, "user:server") })
			awaitStateWithin(t, h, 10*time.Second, "the editor", func() bool {
				draft := d.drafts["user:server"]
				return draft != nil && draft.form != nil && draft.form.open && !draft.form.loading && draft.form.beforeLaunch != nil
			})
			shot("editor")
			steps := d.drafts["user:server"].form.beforeLaunch
			h.app.post(func(*App) { steps.selected = 1 })
			h.settleChain()
			h.app.post(func(*App) { steps.choose = true })
			shot("choose")
			h.app.post(func(a *App) {
				steps.choose = false
				a.closeRunConfigDialog(p)
			})

			h.app.post(func(a *App) { a.runConfiguration(p, "user:server") })
			awaitStateWithin(t, h, 10*time.Second, "the confirmation", func() bool { return p.runConfigs.beforeLaunch != nil })
			shot("confirm")
			h.app.post(func(a *App) {
				ask := p.runConfigs.beforeLaunch
				p.runConfigs.beforeLaunch = nil
				ask.run()
			})
			awaitProcessRun(t, h, p, "Server", nil)
			shot("run-output")
		})
	}
}
