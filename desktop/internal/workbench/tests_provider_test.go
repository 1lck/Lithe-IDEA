package workbench

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// providerTestsManifest is a build system whose tests and model are answered by
// its own provider process. Core still plans the test request and decodes the
// canonical report; the host only starts the provider and routes frames.
const providerTestsManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.provider-tests",
  "displayName": "Provider Tests Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildProviders": 0, "buildSystems": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["languageServer.launch", "process.build"],
  "activationEvents": ["onBuildSystem:fixture-provider-tests"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-provider-tests",
    "displayName": "Provider Tests",
    "detection": {"markers": ["fixture.marker"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-tool"}]},
    "provider": {
      "launch": {"kind": "packaged", "path": "provider"},
      "arguments": ["-test.run=^TestProviderTestRunner$"],
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "model": {"source": "provider"},
    "test": {
      "source": "provider",
      "scopes": ["workspace"],
      "arguments": [],
      "results": {"decoder": "provider"}
    }
  }]
}`

// TestProviderTestRunner is the fixture provider process. It is the copied test
// binary started by the host with the manifest's -test.run argument; the marker
// in its working directory is what tells it apart from an ordinary suite run.
func TestProviderTestRunner(t *testing.T) {
	if _, err := os.Stat("fixture.marker"); err != nil {
		t.Skip("not the provider fixture workspace")
	}
	blocked := false
	if _, err := os.Stat("block.marker"); err == nil {
		blocked = true
	}
	// discovery.marker selects the build window fixture: two projects, a test target and
	// discovered tests (build_tests_test.go).
	_, statErr := os.Stat("discovery.marker")
	discovery := statErr == nil
	// entrypoints.marker selects the entrypoint fixture (title_run_entrypoints_test.go): the
	// provider negotiates litheBuild 1 and finds an entrypoint in src/Main.java only.
	_, statErr = os.Stat("entrypoints.marker")
	entrypoints := statErr == nil
	reader := bufio.NewReader(os.Stdin)
	write := func(value any) {
		body, err := json.Marshal(value)
		if err != nil {
			os.Exit(2)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(3)
		}
	}
	reply := func(id json.RawMessage, result any) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	fail := func(id json.RawMessage, code int, message string) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
	}
	notify := func(method string, params any) {
		write(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
	}
	var pending json.RawMessage
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				os.Exit(0)
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					os.Exit(4)
				}
			}
		}
		if length < 0 || length > 1<<20 {
			os.Exit(5)
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			os.Exit(6)
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			os.Exit(7)
		}
		if len(request.ID) == 0 {
			if request.Method == "$/cancelRequest" && len(pending) != 0 {
				fail(pending, -32800, "Request cancelled")
				pending = nil
			}
			continue
		}
		switch request.Method {
		case "initialize":
			// initialize.marker selects the settings fixture (build_provider_restart_test.go): each
			// start records the initializationOptions it got, one line per process.
			if _, err := os.Stat("initialize.marker"); err == nil {
				var params struct {
					Options json.RawMessage `json:"initializationOptions"`
				}
				if err := json.Unmarshal(request.Params, &params); err != nil {
					os.Exit(12)
				}
				record, err := os.OpenFile("initialize.log", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
				if err != nil {
					os.Exit(13)
				}
				_, writeErr := record.Write(append(params.Options, '\n'))
				if closeErr := record.Close(); writeErr != nil || closeErr != nil {
					os.Exit(14)
				}
			}
			experimental := map[string]any{"litheBuild": map[string]any{"version": 0}}
			if entrypoints {
				experimental["litheBuild"] = map[string]any{"version": 1}
			}
			if _, err := os.Stat("settings-action.marker"); err == nil {
				experimental["litheFunctions"] = map[string]any{"version": 0, "functions": []any{map[string]any{"id": "snapshot.refresh"}}}
			}
			reply(request.ID, map[string]any{"capabilities": map[string]any{"experimental": experimental}})
		case "lithe/function/invoke":
			if err := os.WriteFile("action-invoked.marker", []byte("called"), 0o600); err != nil {
				os.Exit(8)
			}
			if _, err := os.Stat("block-action.marker"); err == nil {
				pending = request.ID
				continue
			}
			reply(request.ID, map[string]any{"value": "fixture action completed"})
		case "lithe/build/model":
			if discovery {
				reply(request.ID, map[string]any{
					"format":  "litheBuildModel",
					"version": 0,
					"projects": []any{
						map[string]any{"path": ".", "name": "fixture"},
						map[string]any{"path": "lib", "name": "library"},
					},
					"targets": []any{
						map[string]any{"project": "lib", "path": "lib", "name": "libtests", "tags": []string{"test"}},
						map[string]any{"project": "lib", "path": "lib", "name": "libapp", "tags": []string{"app"}},
					},
				})
				continue
			}
			reply(request.ID, map[string]any{
				"format":   "litheBuildModel",
				"version":  0,
				"projects": []any{map[string]any{"path": ".", "name": "fixture"}},
			})
		case "lithe/build/discoverTests":
			reply(request.ID, map[string]any{
				"format":  "litheTestDiscovery",
				"version": 0,
				"tests": []any{
					map[string]any{"suite": "LibSuite", "case": "libPasses", "project": map[string]any{"name": "library", "path": "lib"}},
					map[string]any{"suite": "RootSuite", "case": "rootPasses", "project": map[string]any{"name": "fixture", "path": "."}},
				},
			})
		case "lithe/build/test":
			if discovery {
				// The parent test reads which selection the host sent; every run passes.
				if err := os.WriteFile("test-request.json", request.Params, 0o600); err != nil {
					os.Exit(9)
				}
				reply(request.ID, map[string]any{
					"exitCode": 0,
					"output":   "",
					"testResults": map[string]any{
						"format":  "litheTestResults",
						"version": 0,
						"tests":   []any{map[string]any{"suite": "LibSuite", "case": "libPasses", "status": "passed"}},
					},
				})
				continue
			}
			if blocked {
				// The host's cancel notification ends this request; the parent
				// test waits on the published run state, not on a timer.
				pending = request.ID
				continue
			}
			notify("lithe/build/progress", map[string]any{
				"operationID": request.ID,
				"message":     "running provider tests",
				"output":      "provider output\n",
			})
			reply(request.ID, map[string]any{
				"exitCode": 1,
				"output":   "provider output\n",
				"testResults": map[string]any{
					"format":  "litheTestResults",
					"version": 0,
					"tests": []any{
						map[string]any{"suite": "ProviderSuite", "case": "providerPasses", "status": "passed"},
						map[string]any{
							"suite": "ProviderSuite", "case": "providerFails", "status": "failed",
							"message": "provider failure", "path": "tests/provider_test.go", "line": 5,
						},
					},
				},
			})
		case "lithe/build/runEntrypoints":
			var params struct {
				File string `json:"file"`
			}
			if err := json.Unmarshal(request.Params, &params); err != nil {
				os.Exit(11)
			}
			found := []any{}
			if params.File == "src/Main.java" {
				found = append(found, map[string]any{"run": "main", "name": "Main", "entrypoint": "example.Main", "project": map[string]any{"name": "fixture", "path": "."}})
			}
			reply(request.ID, map[string]any{"format": "litheRunEntrypoints", "version": 0, "entrypoints": found})
		case "lithe/build/prepareRun":
			if entrypoints {
				if err := os.WriteFile("prepare-run.json", request.Params, 0o600); err != nil {
					os.Exit(9)
				}
				reply(request.ID, map[string]any{
					"executable":       map[string]any{"kind": "command", "value": "fixture-service"},
					"arguments":        []string{"-test.run=^TestFixtureEntrypointRunner$"},
					"workingDirectory": ".",
					"environment":      map[string]string{fixtureEntrypointVariable: "1"},
				})
				continue
			}
			// service.marker selects the service fixture (build_connection_debug_test.go): the
			// provider records what the host asked for and answers with a process that listens
			// on the debug port the host chose, as a runtime suspended for a debugger does.
			if _, err := os.Stat("service.marker"); err == nil {
				if err := os.WriteFile("prepare-run.json", request.Params, 0o600); err != nil {
					os.Exit(9)
				}
				var params struct {
					LaunchOptions struct {
						Debug *struct {
							Target struct {
								Port int `json:"port"`
							} `json:"target"`
						} `json:"debug"`
					} `json:"launchOptions"`
				}
				if err := json.Unmarshal(request.Params, &params); err != nil {
					os.Exit(10)
				}
				port := 0
				if params.LaunchOptions.Debug != nil {
					port = params.LaunchOptions.Debug.Target.Port
				}
				reply(request.ID, map[string]any{
					"executable":       map[string]any{"kind": "command", "value": "fixture-service"},
					"arguments":        []string{"-test.run=^TestFixtureServiceRunner$"},
					"workingDirectory": "lib",
					"environment":      map[string]string{fixtureServicePortVariable: strconv.Itoa(port)},
				})
				continue
			}
			// A provider builds before it answers: it streams the build's output, here the
			// compile error that makes the preparation fail.
			notify("lithe/build/progress", map[string]any{
				"operationID": request.ID,
				"message":     "compiling libapp",
				"output":      "[ERROR] lib/App.java:[3,1] class, interface, enum, or record expected\n",
			})
			fail(request.ID, -32603, "The build failed.")
		case "shutdown":
			reply(request.ID, nil)
		case "exit":
			os.Exit(0)
		default:
			reply(request.ID, nil)
		}
	}
}

// providerTestsHarness installs the provider plugin package with the running
// test binary as its packaged provider executable.
func providerTestsHarness(t *testing.T, supplied ...pluginservice.Kernel) *harness {
	t.Helper()
	return providerTestsHarnessWith(t, providerTestsManifest, supplied...)
}

// providerTestsHarnessWith is providerTestsHarness with another declaration of the same
// provider.
func providerTestsHarnessWith(t *testing.T, manifest string, supplied ...pluginservice.Kernel) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.provider-tests", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(filepath.Join(installed, "provider"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	_, copyErr := io.Copy(target, source)
	closeTargetErr := target.Close()
	closeSourceErr := source.Close()
	if copyErr != nil || closeTargetErr != nil || closeSourceErr != nil {
		t.Fatalf("copy provider: %v, close: %v, %v", copyErr, closeTargetErr, closeSourceErr)
	}
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.provider-tests", true); err != nil {
		t.Fatal(err)
	}
	var backendKernel pluginservice.Kernel = &testKernel{Client: core.NewClient()}
	if len(supplied) > 0 {
		backendKernel = supplied[0]
	}
	return newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: backendKernel,
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"zh-Hans"},
		// The fixture is a copy of this large instrumented test binary: under
		// load its start can exceed Core's 10s default, which would read as a
		// provider failure. The bound stays finite, never an unbounded wait.
		PluginInitializeTimeout: 60 * time.Second,
	})
}

func TestTestsPanelProviderRunPublishesDecodedResults(t *testing.T) {
	h := providerTestsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.marker"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tests", "provider_test.go"), []byte("package tests\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openTestsPanel(t, h, root)
	if p.testInstance() == nil || p.testInstance().System.Provider == false {
		t.Fatalf("the provider instance was not detected: %+v", p.build.instances)
	}

	clickRun(t, h)
	awaitTestRun(t, h, p)
	if p.tests.failed != "" {
		t.Fatalf("the provider run failed: %s", p.tests.failed)
	}
	if !p.tests.hasResults || p.tests.verdict.Outcome != "testsFailed" {
		t.Fatalf("verdict = %+v, results = %+v, want testsFailed from provider results", p.tests.verdict, p.tests.results)
	}
	summary := p.tests.results.Summary
	if summary.Total != 2 || summary.Passed != 1 || summary.Failed != 1 {
		t.Fatalf("summary = %+v, want provider's 2 total, 1 passed, 1 failed", summary)
	}
	if !h.shows("ProviderSuite") || !h.shows("providerFails") || !h.shows("provider failure") {
		t.Fatal("the result tree does not show the provider's decoded suite, case and message")
	}
	row := -1
	for index, spec := range p.tests.rows {
		if !spec.header && p.tests.results.Tests[spec.index].Case == "providerFails" {
			row = index
		}
	}
	if row < 0 {
		t.Fatal("the provider's failing case has no row")
	}
	h.clickNamed(p.tests.results.Tests[p.tests.rows[row].index].Case)
	opened := filepath.Join(root, "tests", "provider_test.go")
	if p.docs.byPath(opened) == nil {
		t.Fatalf("the provider failure did not open %s", opened)
	}
}

func TestTestsPanelProviderStopCancels(t *testing.T) {
	h := providerTestsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.marker"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "block.marker"), []byte("block\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openTestsPanel(t, h, root)
	clickRun(t, h)
	awaitStateWithin(t, h, 20*time.Second, "the provider test to start", func() bool {
		return p.tests.running && p.tests.operation != nil
	})
	stop := center(h.pageHit(h.app.text.Tests.Stop).Bounds)
	if err := h.driver.Click(stop.X, stop.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the cancelled provider run to publish", func() bool {
		return !p.tests.running
	})
	if p.tests.verdict.Outcome != "cancelled" {
		t.Fatalf("verdict = %+v, want cancelled", p.tests.verdict)
	}
	if p.tests.hasResults {
		t.Fatal("a cancelled provider run claimed test results")
	}
}

func TestTestsPanelProviderCloseProjectStops(t *testing.T) {
	h := providerTestsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.marker"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "block.marker"), []byte("block\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openTestsPanel(t, h, root)
	clickRun(t, h)
	awaitStateWithin(t, h, 20*time.Second, "the provider test to start", func() bool {
		return p.tests.running && p.tests.operation != nil
	})
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool {
		return h.app.project == nil
	})
	h.settle()
	if p.tests.running {
		t.Fatal("closing the project left the provider run marked running")
	}
}

// providerRunManifest is the provider fixture with an application run of the targets tagged app.
var providerRunManifest = strings.Replace(providerTestsManifest, `"model": {"source": "provider"},`,
	`"model": {"source": "provider"},
    "run": [{"id": "application", "source": "provider", "fromTargets": {"tags": ["app"]}, "execution": "application"}],`, 1)

// What a provider prints while it prepares a run, such as the compile error that ends the
// preparation, is the run's console output: the user reads it there when the run fails. The
// host used to wait for the answer without reading the progress, so the console stayed empty.
func TestProviderRunPreparationShowsItsBuildOutput(t *testing.T) {
	h := providerTestsHarnessWith(t, providerRunManifest)
	root := t.TempDir()
	for _, marker := range []string{"fixture.marker", "discovery.marker"} {
		if err := os.WriteFile(filepath.Join(root, marker), []byte("fixture\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "lib"), 0o700); err != nil {
		t.Fatal(err)
	}
	// The host resolves the provider's build tool before it starts the provider; the fixture
	// provider never runs it.
	bin := t.TempDir()
	tool := filepath.Join(bin, "fixture-tool")
	if runtime.GOOS == "windows" {
		tool += ".exe"
		t.Setenv("PATHEXT", ".EXE")
	}
	if err := writeFakeExecutable(tool); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.loadBuildSystems(p) })
	awaitStateWithin(t, h, time.Minute, "the provider model", func() bool {
		return len(p.build.instances) == 1 && (p.build.instances[0].modelLoaded || p.build.instances[0].modelError != "")
	})
	instance := &p.build.instances[0]
	if instance.modelError != "" {
		t.Fatalf("the provider model failed: %s", instance.modelError)
	}
	targetID := ""
	for _, target := range instance.Model.Targets {
		if target.Name == "libapp" {
			targetID = target.ID
		}
	}
	if targetID == "" {
		t.Fatalf("no libapp target in %+v", instance.Model.Targets)
	}
	var op *buildOperation
	h.app.post(func(a *App) {
		a.runBuildTarget(p, targetID, "application")
		op = p.build.latest()
	})
	awaitStateWithin(t, h, time.Minute, "the run operation", func() bool { return op != nil })
	awaitStateWithin(t, h, time.Minute, "the failed preparation", func() bool { return !p.build.active() })
	if console := op.session.output.all(); !strings.Contains(console, "class, interface, enum, or record expected") {
		t.Fatalf("the run console = %q, want the provider's build output", console)
	}
	if op.session.outcome != runFailed {
		t.Fatalf("a failed preparation ended as %d, want failed", op.session.outcome)
	}
	// The provider's own message is what the run says: Core keeps a provider's JSON-RPC error
	// under its generic serverError message and passes the provider's text apart (#2143).
	if op.session.summary != "The build failed." {
		t.Fatalf("the run summary = %q, want the provider's message", op.session.summary)
	}
}
