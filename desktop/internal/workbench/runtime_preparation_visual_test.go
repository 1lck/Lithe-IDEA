//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRuntimePreparationStatus captures the real status menu while a
// synthetic language service prepares a runtime, including its cancel action.
func TestVisualRuntimePreparationStatus(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en"} {
			t.Run(theme+"/"+language, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				root := t.TempDir()
				file := filepath.Join(root, "example.fixture")
				if err := os.WriteFile(file, []byte("let answer = 42;\n"), 0o600); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.open(root)
				p := h.app.project
				h.app.openFile(p, file)
				h.settleChain()
				d := p.docs.byPath(file)
				if d == nil {
					t.Fatal("fixture document did not open")
				}
				d.languageID = "fixture"
				_, cancel := context.WithCancel(p.ctx)
				t.Cleanup(cancel)
				preparation := &pluginServerPreparation{project: p, cancel: cancel}
				preparation.progress.Store(&pluginruntime.Progress{ID: "engine", Phase: "downloading", Received: 48 << 20, Total: 192 << 20})
				h.app.pluginServerPreparations = map[string]*pluginServerPreparation{"fixture": preparation}
				h.app.invalidator.Invalidate()
				h.settleChain()
				h.click(center(h.button(itemLSP)))
				h.settleChain()
				h.clickNamed("fixture")
				h.settleChain()
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				if err := session.Screenshot(filepath.Join(out, "runtime-startup-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
