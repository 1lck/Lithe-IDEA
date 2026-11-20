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

// TestVisualRunOnCurrentFile captures Run on Current File: the Run window after Main.java's
// main class ran, with the saved Main configuration chosen in the title bar, and the run
// configuration menu that lists it. It needs only LITHE_VISUAL_OUTPUT_DIR; the dark captures
// are in Chinese and the light ones in English.
func TestVisualRunOnCurrentFile(t *testing.T) {
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
			options := entrypointOptions(t, theme, language)
			root := entrypointWorkspace(t)
			var session *headless.Session
			h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
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
				if err := session.Screenshot(filepath.Join(out, "run-current-file-"+scene+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
			h.open(root)
			p := h.app.project
			h.app.post(func(a *App) { a.loadTitleRunConfigs(p) })
			awaitStateWithin(t, h, time.Minute, "the provider model", func() bool {
				return len(p.build.instances) == 1 && p.build.instances[0].modelLoaded && p.runConfigsSettled()
			})
			openSource(t, h, p, filepath.Join(root, "src", "Main.java"))
			h.app.post(func(a *App) {
				a.chooseTitleConfiguration(p, "")
				a.titleRun(p)
			})
			awaitProcessRun(t, h, p, "Main", nil)
			shot("run")
			h.app.post(func(a *App) { a.openRunConfigMenu() })
			shot("menu")
		})
	}
}

func TestVisualRunAttachShowsDebugWindow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		t.Run(look.theme, func(t *testing.T) {
			options := attachRunDebugOptions(t, look.theme)
			options.Languages = []string{look.language}
			var session *headless.Session
			h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 820
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			p := attachRunDebugFixture(t, h)
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "run-attach-debug-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
			h.app.stopDebug(p)
		})
	}
}
