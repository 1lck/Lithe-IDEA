//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// visualBuildSystems is a workspace with several build systems a plugin could detect, each at
// its own root, with the projects, targets and tasks their models list. Maven's is a reactor,
// as IntelliJ's Maven window shows one: the root project shop holds shop-core and shop-web, and
// each project lists the lifecycle phases, the plugin goals its model reports by plugin, and
// its dependencies.
func visualBuildSystems() []buildInstance {
	system := func(id, name, root string, runs []pluginservice.BuildRunDeclaration, tasks []pluginservice.BuildTaskDeclaration, model core.BuildModel) buildInstance {
		instance := buildInstance{
			BuildInstance: core.BuildInstance{ID: id + "@" + root, PluginID: "dev.example." + id, BuildSystemID: id, Root: root, ModelSource: "provider"},
			PluginID:      "dev.example." + id,
			System: pluginservice.BuildSystemDeclaration{
				DisplayName: name, Runs: runs, Tasks: tasks,
				Dependencies: &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"project"}},
			},
			Model:       model,
			modelLoaded: true,
		}
		instance.Manifest = buildTestManifest(&instance)
		return instance
	}
	// task runs on the whole build or on one of its projects.
	task := func(id, name, group string, category ...string) pluginservice.BuildTaskDeclaration {
		return pluginservice.BuildTaskDeclaration{
			ID: id, DisplayName: name, Group: group, Category: category, Scopes: []string{"workspace", "project"}, Source: "provider",
		}
	}
	goal := func(project, plugin, name string) core.BuildTask {
		return core.BuildTask{
			ID: project + ":" + plugin + ":" + name, ProjectID: project, Name: plugin + ":" + name, Template: "goal",
			Group: "build", Category: []string{"Plugins", plugin}, Execution: "task",
		}
	}
	run := []pluginservice.BuildRunDeclaration{{ID: "application", Name: "Run", Tags: []string{"app"}}}
	lifecycle := []pluginservice.BuildTaskDeclaration{}
	for _, phase := range []string{"clean", "validate", "compile", "test", "package", "verify", "install", "deploy"} {
		lifecycle = append(lifecycle, task(phase, phase, "lifecycle", "Lifecycle"))
	}
	lifecycle = append(lifecycle, pluginservice.BuildTaskDeclaration{ID: "goal", DisplayName: "Plugin goal", Group: "build", FromModel: true, Source: "provider"})
	maven := system("maven", "Maven", ".", run, lifecycle, core.BuildModel{
		Projects: []core.BuildProject{
			{ID: "shop", Path: ".", Name: "shop"},
			{ID: "core", Path: "core", Name: "shop-core", ParentID: "shop"},
			{ID: "web", Path: "web", Name: "shop-web", ParentID: "shop"},
		},
		Targets: []core.BuildTarget{{ID: "web-app", ProjectID: "web", Name: "ShopApplication", Path: "web", Tags: []string{"app"}}},
		Tasks: []core.BuildTask{
			goal("shop", "clean", "clean"), goal("shop", "install", "install"),
			goal("core", "compiler", "compile"), goal("core", "compiler", "testCompile"), goal("core", "surefire", "test"), goal("core", "jar", "jar"),
			goal("web", "compiler", "compile"), goal("web", "spring-boot", "run"), goal("web", "spring-boot", "repackage"),
		},
		OptionValues:          map[string][]string{"profiles": {"ci", "dev", "prod"}},
		OptionDefaults:        map[string][]string{"profiles": {"dev"}},
		OptionExcludePrefixes: map[string]string{"profiles": "-"},
	})
	maven.Options = map[string]json.RawMessage{"profiles": json.RawMessage(`["dev","prod"]`)}
	maven.OptionFingerprint = "visual-profiles-dev-prod"
	var mavenManifest map[string]any
	if err := json.Unmarshal(maven.Manifest, &mavenManifest); err != nil {
		panic(err)
	}
	mavenManifest["buildSystems"].([]any)[0].(map[string]any)["options"] = []any{map[string]any{
		"id": "profiles", "displayName": "Profiles", "kind": "multiSelect",
		"choicesFromModel": true, "allowCustom": true, "presentation": "tree",
		"arguments": []string{"-P", "${value}"},
	}}
	var err error
	if maven.Manifest, err = json.Marshal(mavenManifest); err != nil {
		panic(err)
	}
	return []buildInstance{
		maven,
		system("gradle", "Gradle", "android", run, []pluginservice.BuildTaskDeclaration{
			task("assemble", "assemble", "build", "Build"), task("build", "build", "build", "Build"), task("check", "check", "verification", "Verification"),
		}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "app", Path: "app", Name: "app"}},
			Targets:  []core.BuildTarget{{ID: "debug", ProjectID: "app", Name: "debug", Tags: []string{"app"}}, {ID: "release", ProjectID: "app", Name: "release", Tags: []string{"app"}}},
		}),
		system("cargo", "Cargo", "tools/cli", run, []pluginservice.BuildTaskDeclaration{task("build", "build", "build"), task("test", "test", "test")}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "cli", Path: ".", Name: "shop-cli"}},
			Targets:  []core.BuildTarget{{ID: "bin", ProjectID: "cli", Name: "shop-cli", Tags: []string{"app"}}, {ID: "lib", ProjectID: "cli", Name: "parser", Tags: []string{"library"}}},
		}),
		system("go", "Go Modules", "services/api", run, []pluginservice.BuildTaskDeclaration{task("build", "go build", "build"), task("test", "go test", "test")}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "api", Path: ".", Name: "api"}},
			Targets:  []core.BuildTarget{{ID: "server", ProjectID: "api", Name: "cmd/server", Tags: []string{"app"}}},
		}),
		system("npm", "npm", "web/frontend", nil, []pluginservice.BuildTaskDeclaration{task("dev", "dev", "run"), task("build", "build", "build"), task("lint", "lint", "verification")}, core.BuildModel{
			Projects: []core.BuildProject{{ID: "frontend", Path: ".", Name: "frontend"}},
		}),
	}
}

// visualGoModule is one Go module whose targets are named by their whole import path, under
// the folder each is in, which their rows show alone. Two of its packages are commands, which
// run; the others are packages with tests.
func visualGoModule() buildInstance {
	const module = "github.com/example/shop/desktop"
	pkg := func(dir, tag string) core.BuildTarget {
		return core.BuildTarget{ID: dir, ProjectID: "desktop", Name: module + "/" + dir, Path: dir, Tags: []string{tag}}
	}
	instance := buildInstance{
		BuildInstance: core.BuildInstance{ID: "go@desktop", PluginID: "dev.example.go", BuildSystemID: "go", Root: "desktop", ModelSource: "command"},
		PluginID:      "dev.example.go",
		System: pluginservice.BuildSystemDeclaration{
			DisplayName: "Go Modules",
			Runs:        []pluginservice.BuildRunDeclaration{{ID: "main", Name: "Run", Tags: []string{"application"}}},
			Tasks: []pluginservice.BuildTaskDeclaration{
				{ID: "build", DisplayName: "Build", Group: "build", Scopes: []string{"project"}, Source: "provider"},
				{ID: "vet", DisplayName: "Vet", Group: "verification", Scopes: []string{"project"}, Source: "provider"},
			},
			Dependencies: &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"project"}},
		},
		Model: core.BuildModel{
			Projects: []core.BuildProject{{ID: "desktop", Path: ".", Name: module}},
			Targets: []core.BuildTarget{
				pkg("cmd/shop", "application"), pkg("cmd/shop-perf", "application"),
				pkg("internal/checkout", "test"), pkg("internal/catalog", "test"), pkg("internal/catalog/search", "test"),
				pkg("internal/payments", "test"), pkg("internal/storage", "test"), pkg("internal/i18n", "test"),
			},
		},
		modelLoaded: true,
	}
	instance.Manifest = buildTestManifest(&instance)
	return instance
}

// TestVisualBuildPanels captures the Build window on the right, with the run configurations
// above the aggregated build tree, beside the Run window at the bottom showing only the build
// console; a Go module whose model loads, its sync session in the Run window showing what go
// downloads; the Build window filtered; a Go module with runnable rows; and the Build options
// dialog while it is resolving its fields and after the result arrives.
func TestVisualBuildPanels(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"build-and-run", "concurrent-runs", "build-sync", "build-filter", "build-go-targets", "build-options"} {
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
				var kernel Kernel = &testKernel{Client: core.NewClient()}
				var resolution *buildOptionResolutionGate
				var finishResolution context.CancelFunc
				if scene == "build-options" {
					var release context.Context
					release, finishResolution = context.WithCancel(t.Context())
					defer finishResolution()
					resolution = &buildOptionResolutionGate{Kernel: kernel, started: make(chan struct{}, 1), release: release}
					kernel = resolution
				}
				h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
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
					p.build.projectID, p.build.taskID = "web", "package"
					p.setBuildGroupOpen(1, true)
					a.reduceChrome(core.SetChromeOpen(itemBuild, true))
					a.refreshRunConfigurations(p)
				})
				h.settleChain()
				// The folders a user opens to inspect active profiles, shop-core's compiler goals and
				// shop-web's lifecycle; the rest stay closed, as they start.
				for _, path := range [][]string{{"Profiles"}, {"shop-core", "Plugins"}, {"shop-core", "Plugins", "compiler"}, {"shop-web", "Lifecycle"}} {
					setBuildNodeOpen(t, p, laidOutBuildRows(t, h, p), true, path...)
				}
				switch scene {
				case "build-and-run":
					h.app.post(func(a *App) {
						// A restart, so the tab offers to run it again as a real task's does.
						op := a.beginBuildOperation(p, "build", "package", "", func(*App, *project) {})
						// Maven's output with -Dstyle.color=always, so the console shows its colors.
						const info = "[\x1b[1;34mINFO\x1b[m] "
						goal := func(plugin, execution, module string) string {
							return info + "\x1b[1m--- \x1b[0;32m" + plugin + "\x1b[m \x1b[1m(" + execution + ")\x1b[m @ \x1b[36m" + module + "\x1b[0;1m ---\x1b[m\n"
						}
						feedBuildOutput(a, p, op, strings.Join([]string{
							info + "Scanning for projects...\n",
							info + "\x1b[1mReactor Build Order:\x1b[m\n",
							info + "  shop        [pom]\n",
							info + "  shop-core   [jar]\n",
							info + "  shop-web    [jar]\n",
							goal("compiler:3.13.0:compile", "default-compile", "shop-core"),
							info + "Compiling 42 source files to core/target/classes\n",
							goal("surefire:3.2.5:test", "default-test", "shop-core"),
							"[\x1b[1;33mWARNING\x1b[m] \x1b[1;33mTests run: 128, Failures: 0, Errors: 0, Skipped: 2\x1b[m\n",
							goal("jar:3.4.1:jar", "default-jar", "shop-web"),
							info + "Building jar: web/target/shop-web-1.4.0.jar\n",
							info + "\x1b[1m------------------------------------------------------------------------\x1b[m\n",
							info + "\x1b[1;32mBUILD SUCCESS\x1b[m\n",
							info + "Total time:  8.214 s\n",
						}, ""))
						a.finishBuildTask(p, op, json.RawMessage(`{"exitCode":0}`))
						a.showBuildConsole(p)
					})
				case "concurrent-runs":
					h.app.post(func(a *App) {
						// Two services at once (#2071): one still prepared, with a spinner, and one
						// whose process runs, with the static run mark and its address linked.
						a.beginRunOperation(p, "ShopWorker", "worker", configurationRunKey("worker"), func(*App, *project) {})
						op := a.beginRunOperation(p, "ShopApplication", "web", configurationRunKey("web"), func(*App, *project) {})
						op.session.processRunning = true
						a.setOperationStatus(p, op, a.text.Build.Running)
						feedBuildOutput(a, p, op, strings.Join([]string{
							"  .   ____          _            __ _ _\n",
							" :: Spring Boot ::                (v3.3.4)\n",
							"INFO  o.s.b.w.e.tomcat.TomcatWebServer : Tomcat started on port 8080 (http) with context path '/'\n",
							"INFO  demo.web.ShopApplication         : Started ShopApplication in 1.912 seconds\n",
							"INFO  demo.web.ShopApplication         : Open http://localhost:8080/swagger-ui/index.html.\n",
						}, ""))
						a.showBuildConsole(p)
					})
				case "build-sync":
					h.app.post(func(a *App) {
						// The Go module's model still loads, as go downloads the modules it needs.
						instance := visualGoModule()
						instance.Model, instance.modelLoaded, instance.modelLoading = core.BuildModel{}, false, true
						p.build.instances, p.build.selected = []buildInstance{instance}, 0
						p.build.projectID, p.build.targetID, p.build.taskID = "", "", ""
						p.setBuildGroupOpen(0, true)
						a.refreshRunConfigurations(p)
						feed := a.beginBuildSync(p, &p.build.instances[0])
						var log strings.Builder
						for _, module := range []string{
							"golang.org/x/sync v0.10.0", "golang.org/x/sys v0.28.0", "golang.org/x/text v0.21.0",
							"github.com/google/uuid v1.6.0", "google.golang.org/protobuf v1.36.1", "google.golang.org/grpc v1.69.2",
						} {
							log.WriteString("go: downloading " + module + "\n")
						}
						feed.decoder.deliver(log.String(), func(chunk outputChunk, failure error) {
							a.reportOutputStyleFailure(failure)
							a.applyBuildSyncOutput(p, feed.session, chunk)
						})
						a.showBuildSync(p, feed.session.id)
					})
				case "build-filter":
					h.app.post(func(*App) { p.panels.buildFilter = "app" })
				case "build-go-targets":
					h.app.post(func(a *App) {
						p.build.instances, p.build.selected = []buildInstance{visualGoModule()}, 0
						p.build.projectID, p.build.targetID, p.build.taskID = "desktop", "internal/catalog", ""
						a.refreshRunConfigurations(p)
					})
					h.settleChain()
					setBuildNodeOpen(t, p, laidOutBuildRows(t, h, p), true, h.app.text.Build.Targets)
				case "build-options":
					h.app.post(func(a *App) { a.openBuildOptions(p, &p.build.instances[0]) })
					awaitValueWithin(t, h, 5*time.Second, resolution.started, "Build options resolution to start")
					if err := session.Screenshot(filepath.Join(out, "build-options-loading-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
					finishResolution()
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
