//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualBuildCommandDiscovery(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	installBuildTool(t)
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"zh-Hans", "en"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				root := t.TempDir()
				writeBuildCommandMarker(t, root, "discover-tests")
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				client := &testKernel{Client: core.NewClient()}
				h := newHarnessWithDriver(t, Options{Kernel: client, PluginKernel: client, PluginRoot: t.TempDir(), Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1440, 900
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.open(root)
				p := h.app.project
				instance := commandDiscoveryTestInstance(t, contractfixture.Path("fixtures/build-systems/build-command-test-discovery.json"))
				instance.System.DisplayName = "Sample Build"
				instance.modelLoaded = true
				h.app.post(func(a *App) {
					p.build.instances, p.build.loaded, p.build.selected = []buildInstance{instance}, true, 0
					p.setBuildGroupOpen(0, true)
					a.reduceChrome(core.SetChromeOpen(itemBuild, true))
				})
				h.settleChain()
				setBuildNodeOpen(t, p, laidOutBuildRows(t, h, p), true, i18n.Shared(h.app.language(), "native.discoveredTests"))
				h.app.invalidator.Invalidate()
				h.settle()
				h.clickNamed(i18n.Shared(h.app.language(), "native.discoverTests"))
				awaitStateWithin(t, h, 20*time.Second, "the command discovery result", func() bool {
					tests := p.build.discovered[instance.ID]
					return tests != nil && !tests.loading
				})
				if tests := p.build.discovered[instance.ID]; tests.failed != "" || len(tests.tests) != 2 {
					t.Fatalf("discovery = %+v", tests)
				}
				h.app.invalidator.Invalidate()
				h.settleChain()
				rows := laidOutBuildRows(t, h, p)
				if !slices.ContainsFunc(rows, func(row buildRow) bool {
					return row.label == "ExampleSuite · checks spaces # [exact]"
				}) {
					t.Fatalf("the command's discovered test has no row: %+v", rows)
				}
				if err := session.Screenshot(filepath.Join(out, "build-command-discovery-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
