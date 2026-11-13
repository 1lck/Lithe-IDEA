//go:build vivahead && lithevisual

package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// visualBuildSystems is a workspace with several build systems a plugin could detect, each at
// its own root, with the projects, targets and tasks their models list.
func visualBuildSystems() []buildInstance {
	system := func(id, name, root string, runs []pluginservice.BuildRunDeclaration, tasks []pluginservice.BuildTaskDeclaration, model core.BuildModel) buildInstance {
		return buildInstance{
			BuildInstance: core.BuildInstance{ID: id + "@" + root, PluginID: "dev.example." + id, BuildSystemID: id, Root: root},
			PluginID:      "dev.example." + id,
			System:        pluginservice.BuildSystemDeclaration{DisplayName: name, Runs: runs, Tasks: tasks},
			Model:         model,
			modelLoaded:   true,
		}
	}
	task := func(id, name string, category ...string) pluginservice.BuildTaskDeclaration {
		return pluginservice.BuildTaskDeclaration{ID: id, DisplayName: name, Source: "provider", Category: category}
	}
	run := []pluginservice.BuildRunDeclaration{{ID: "application", Name: "Run", Tags: []string{"app"}}}
	return []buildInstance{
		system("maven", "Maven", ".", run, []pluginservice.BuildTaskDeclaration{
			task("clean", "clean", "Lifecycle"), task("compile", "compile", "Lifecycle"),
			task("test", "test", "Lifecycle"), task("package", "package", "Lifecycle"), task("install", "install", "Lifecycle"),
		}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "shop", Path: ".", Name: "shop"}, {ID: "core", Path: "core", Name: "shop-core"}, {ID: "web", Path: "web", Name: "shop-web"}},
			Targets:  []core.BuildTarget{{ID: "web-app", ProjectID: "web", Name: "ShopApplication", Path: "web", Tags: []string{"app"}}},
		}),
		system("gradle", "Gradle", "android", run, []pluginservice.BuildTaskDeclaration{
			task("assemble", "assemble", "Build"), task("build", "build", "Build"), task("check", "check", "Verification"),
		}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "app", Path: "app", Name: "app"}},
			Targets:  []core.BuildTarget{{ID: "debug", ProjectID: "app", Name: "debug", Tags: []string{"app"}}, {ID: "release", ProjectID: "app", Name: "release", Tags: []string{"app"}}},
		}),
		system("cargo", "Cargo", "tools/cli", run, []pluginservice.BuildTaskDeclaration{task("build", "build"), task("test", "test")}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "cli", Path: ".", Name: "shop-cli"}},
			Targets:  []core.BuildTarget{{ID: "bin", ProjectID: "cli", Name: "shop-cli", Tags: []string{"app"}}, {ID: "lib", ProjectID: "cli", Name: "parser", Tags: []string{"library"}}},
		}),
		system("go", "Go Modules", "services/api", run, []pluginservice.BuildTaskDeclaration{task("build", "go build"), task("test", "go test")}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "api", Path: ".", Name: "api"}},
			Targets:  []core.BuildTarget{{ID: "server", ProjectID: "api", Name: "cmd/server", Tags: []string{"app"}}},
		}),
		system("npm", "npm", "web/frontend", nil, []pluginservice.BuildTaskDeclaration{task("dev", "dev"), task("build", "build"), task("lint", "lint")}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "frontend", Path: ".", Name: "frontend"}},
		}),
	}
}

// TestVisualBuildPanels captures the Build window on the right, with the run configurations
// above the aggregated build tree, beside the Run window at the bottom showing only the build
// console, and the Build window filtered.
func TestVisualBuildPanels(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"build-and-run", "build-filter"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				root := filepath.Join(t.TempDir(), "Shop")
				// Core lists a run configuration only when its working directory exists.
				for _, instance := range visualBuildSystems() {
					if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(instance.Root)), 0700); err != nil {
						t.Fatal(err)
					}
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
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
				h.app.post(func(a *App) {
					p.build.instances, p.build.loaded, p.build.selected = visualBuildSystems(), true, 0
					p.build.taskID = "package"
					p.setBuildOpen(buildOpenKey(p.build.instances[1].ID, ""), true)
					a.reduceChrome(core.SetChromeOpen(itemBuild, true))
					a.refreshRunConfigurations(p)
				})
				h.settleChain()
				switch scene {
				case "build-and-run":
					h.app.post(func(a *App) {
						op := a.beginBuildOperation(p, "build", "package", "")
						for _, line := range []string{
							"[INFO] Scanning for projects...\n",
							"[INFO] Reactor Build Order:\n",
							"[INFO]   shop        [pom]\n",
							"[INFO]   shop-core   [jar]\n",
							"[INFO]   shop-web    [jar]\n",
							"[INFO] --- compiler:3.13.0:compile (default-compile) @ shop-core ---\n",
							"[INFO] Compiling 42 source files to core/target/classes\n",
							"[INFO] --- surefire:3.2.5:test (default-test) @ shop-core ---\n",
							"[INFO] Tests run: 128, Failures: 0, Errors: 0, Skipped: 2\n",
							"[INFO] --- jar:3.4.1:jar (default-jar) @ shop-web ---\n",
							"[INFO] Building jar: web/target/shop-web-1.4.0.jar\n",
							"[INFO] BUILD SUCCESS\n",
							"[INFO] Total time:  8.214 s\n",
						} {
							a.appendBuildOutput(p, op, line)
						}
						a.finishBuildTask(p, op, json.RawMessage(`{"exitCode":0}`))
						a.showBuildConsole(p)
					})
				case "build-filter":
					h.app.post(func(*App) { p.panels.buildFilter = "app" })
				}
				h.settleChain()
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, scene+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
