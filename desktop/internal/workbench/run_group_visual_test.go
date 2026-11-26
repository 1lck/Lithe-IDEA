//go:build vivahead && lithevisual

package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRunGroupedTree captures dark (zh-Hans) and light (en) Run window screenshots showing
// aggregated plugin sessions in one group tab, collapsible > / v detail rows in the execution
// tree, and a user-detached tab in the Run header.
func TestVisualRunGroupedTree(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		t.Run(look.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			kernel := &testKernel{Client: core.NewClient()}
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1440, 900
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(t.TempDir())
			p := h.app.project
			instance := &buildInstance{
				BuildInstance: core.BuildInstance{ID: "fixture-root", BuildSystemID: "fixture", DisplayName: "Fixture Build"},
				PluginID:      "dev.lithe.test.build",
				System:        pluginservice.BuildSystemDeclaration{DisplayName: "Fixture Build"},
			}
			h.app.post(func(a *App) {
				syncFeed := a.beginBuildSync(p, instance)
				syncFeed.decoder.deliver("[INFO] Resolving project model...\n", func(chunk outputChunk, _ error) {
					syncFeed.session.output.apply(chunk)
				})
				a.endBuildSync(syncFeed.session, nil)

				cleanOp := a.beginBuildOperation(p, "build", "Fixture Build: clean", "", func(*App, *project) {})
				setRunGroupFromInstance(p, cleanOp.session, instance)
				feedBuildOutput(a, p, cleanOp, strings.Join([]string{
					"[INFO] Scanning for projects...\n",
					"[INFO] Deleting target/\n",
					"[INFO] BUILD SUCCESS\n",
					"[INFO] Total time: 0.557 s\n",
				}, ""))
				a.finishBuildTask(p, cleanOp, json.RawMessage(`{"exitCode":0}`))
				// Expand the selected execution so the screenshot shows both collapsed (>) and expanded (v) states.
				p.toggleRunNodeExpanded(cleanOp.session)

				detachedOp := a.beginBuildOperation(p, "build", "Fixture Build: test", "", func(*App, *project) {})
				setRunGroupFromInstance(p, detachedOp.session, instance)
				feedBuildOutput(a, p, detachedOp, "[INFO] Tests run: 12, Failures: 0\n")
				a.finishBuildTask(p, detachedOp, json.RawMessage(`{"exitCode":0}`))
				detachedOp.session.detached = true

				p.selectRun(cleanOp.session.id)
				a.reduceChrome(core.SetChromeOpen(itemRun, true))
			})
			h.settleChain()
			h.app.invalidator.Invalidate()
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "run-grouped-tree-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
