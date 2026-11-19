package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const buildCommandPluginID = "dev.lithe.test.build-command"

// buildCommandManifest declares one build system whose model and dependencies are commands of
// the fixture-build tool, which is the copied test binary running TestBuildCommandRunner.
const buildCommandManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.build-command",
  "displayName": "Build Command Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build"],
  "activationEvents": ["onBuildSystem:fixture"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture",
    "displayName": "Fixture",
    "detection": {"markers": ["build.fixture"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-build"}]},
    "model": {
      "source": "command",
      "arguments": ["-test.run=^TestBuildCommandRunner$"],
      "decoder": "litheBuildModel",
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "dependencies": {
      "source": "command",
      "scopes": ["workspace"],
      "arguments": ["-test.run=^TestBuildCommandRunner$"],
      "decoder": "litheDependencies",
      "executesProjectCode": false,
      "mayUseNetwork": false
    }
  }]
}`

// buildCommandProviderManifest is a build system that declares a provider process and still
// reads its model and its dependency tree with commands: its provider only prepares runs. The dependency command writes its tree to the file the host allocates.
const buildCommandProviderManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.build-command",
  "displayName": "Build Command Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0, "buildProviders": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["languageServer.launch", "process.build"],
  "activationEvents": ["onBuildSystem:fixture"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture",
    "displayName": "Fixture",
    "detection": {"markers": ["build.fixture"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-build"}]},
    "provider": {
      "launch": {"kind": "packaged", "path": "provider"},
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "model": {
      "source": "command",
      "arguments": ["-test.run=^TestBuildCommandRunner$"],
      "decoder": "litheBuildModel",
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "dependencies": {
      "source": "command",
      "scopes": ["workspace"],
      "arguments": ["-test.run=^TestBuildCommandRunner$", "--", "${outputFile}"],
      "output": "outputFile",
      "decoder": "litheDependencies",
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "run": [{"id": "application", "source": "provider", "fromTargets": {"tags": ["app"]}, "execution": "application"}]
  }]
}`

// buildCommandMarker names the file in the command's working directory that tells the runner
// what to do: print a model or a tree, exit with a failure, print what is no document, log a
// download before the model or before it hangs, or hang.
const buildCommandMarker = "build-command.marker"

// buildCommandDownloadLine is what the runner logs on stderr in the download modes.
const buildCommandDownloadLine = "go: downloading example.com/fixture v1.0.0"

// TestBuildCommandRunner is the fixture build tool. It prints nothing of the testing package
// and exits by itself, since the host reads its whole output.
func TestBuildCommandRunner(t *testing.T) {
	mode, err := os.ReadFile(buildCommandMarker)
	if err != nil {
		t.Skip("not the build command fixture workspace")
	}
	switch string(mode) {
	case "model":
		fmt.Print(`{"format":"litheBuildModel","version":0,"projects":[{"name":"fixture"}]}`)
	case "dependencies":
		fmt.Print(`{"format":"litheDependencies","version":0,"dependencies":[{"name":"fixture-dependency","children":[]}]}`)
	case "dependencies-file":
		// The tree goes to the output file named after "--", and stdout stays free for the log.
		arguments := flag.Args()
		if len(arguments) == 0 {
			os.Exit(4)
		}
		fmt.Print("[INFO] writing the dependency tree\n")
		tree := `{"format":"litheDependencies","version":0,"dependencies":[{"name":"fixture-dependency","children":[]}]}`
		if err := os.WriteFile(arguments[len(arguments)-1], []byte(tree), 0o600); err != nil {
			os.Exit(5)
		}
	case "discover-blocked":
		arguments := flag.Args()
		if len(arguments) != 2 {
			os.Exit(4)
		}
		if err := os.WriteFile(arguments[0], []byte("running"), 0o600); err != nil {
			os.Exit(5)
		}
		// The deadline is a watchdog for a failed cancellation, not a readiness signal.
		timer := time.NewTimer(pluginOperationWait)
		<-timer.C
		os.Exit(7)
	case "discover-tests":
		arguments := flag.Args()
		if len(arguments) != 2 {
			os.Exit(4)
		}
		result, err := os.ReadFile(arguments[0])
		if err != nil {
			os.Exit(5)
		}
		if err := os.WriteFile(arguments[1], result, 0o600); err != nil {
			os.Exit(6)
		}
	case "fail":
		os.Exit(3)
	case "explain":
		// A tool that says why it failed, in color, as Maven does with -Dstyle.color=always.
		fmt.Print("\x1b[1mScanning\x1b[m\r\n\r\n")
		fmt.Fprint(os.Stderr, "\x1b[1;31m[ERROR]\x1b[m The JAVA_HOME environment variable is not defined correctly\r\n")
		os.Exit(1)
	case "download":
		// A tool that logs what it downloads on stderr while stdout carries the model, as `go
		// list` does with a cold module cache.
		fmt.Fprint(os.Stderr, buildCommandDownloadLine+"\n")
		fmt.Print(`{"format":"litheBuildModel","version":0,"projects":[{"name":"fixture"}]}`)
	case "download-hang":
		// A download that never ends, which only the user's stop or the deadline ends.
		fmt.Fprint(os.Stderr, buildCommandDownloadLine+"\n")
		time.Sleep(pluginOperationWait)
	case "hang":
		// The host kills the tool when the load's deadline passes; this only outlives it.
		time.Sleep(pluginOperationWait)
	default:
		fmt.Print("not a document")
	}
	os.Exit(0)
}

// buildCommandHarness opens an empty project in a window whose plugin kernel hands the test
// every recorded result, with a private plugin root for the build state.
func buildCommandHarness(t *testing.T) (*harness, *recordingPluginKernel, *project) {
	t.Helper()
	return buildCommandHarnessAt(t, t.TempDir())
}

// buildCommandHarnessAt also lets native path tests control the project's parent directories.
func buildCommandHarnessAt(t *testing.T, workspace string) (*harness, *recordingPluginKernel, *project) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	plugins := newRecordingPluginKernel()
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: plugins,
		PluginRoot:   t.TempDir(),
		Store:        store.At(dir),
		Languages:    []string{"zh-Hans"},
	})
	h.open(workspace)
	return h, plugins, h.app.project
}

// installBuildTool puts the fixture build tool first on PATH and returns the PATH without it.
func installBuildTool(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	name := "fixture-build"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	copyTestBinary(t, filepath.Join(bin, name))
	without := os.Getenv("PATH")
	t.Setenv("PATH", bin+string(os.PathListSeparator)+without)
	return without
}

func writeBuildCommandMarker(t *testing.T, root, mode string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, buildCommandMarker), []byte(mode), 0o600); err != nil {
		t.Fatal(err)
	}
}

// buildCommandInstance is the fixture's instance at root; provider makes it a system that
// declares a provider, whose plan may still answer with a command.
func buildCommandInstance(root string, provider bool) buildInstance {
	return buildInstance{
		BuildInstance: core.BuildInstance{ID: "fixture@" + root, PluginID: buildCommandPluginID, BuildSystemID: "fixture", Root: root, ModelSource: "command"},
		PluginID:      buildCommandPluginID,
		Version:       "1.0.0",
		Manifest:      json.RawMessage(buildCommandManifest),
		System: pluginservice.BuildSystemDeclaration{
			Provider:     provider,
			Dependencies: &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"workspace"}, Source: "command"},
		},
	}
}

// buildLoadContext is the context of a load the action op runs, bounded by timeout.
func buildLoadContext(t *testing.T, op string, timeout time.Duration) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(core.WithOrigin(context.Background(), core.Origin{Operation: op}), timeout)
	t.Cleanup(cancel)
	return ctx
}

func failedBuildCommand(operation core.PluginOperationName, op string, stage core.PluginStage) core.PluginOperation {
	return core.PluginOperation{PluginID: buildCommandPluginID, Operation: operation, Outcome: "failed", Stage: stage, OperationID: op}
}

func commandDiscoveryTestInstance(t *testing.T, reportSource string) buildInstance {
	t.Helper()
	raw, err := os.ReadFile(contractfixture.Path("fixtures/build-systems/build-command-test-discovery.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	system := manifest["buildSystems"].([]any)[0].(map[string]any)
	system["invocation"] = map[string]any{"executables": []map[string]string{{"kind": "command", "command": "fixture-build"}}}
	test := system["test"].(map[string]any)
	discovery := test["discoveryCommand"].(map[string]any)
	discovery["arguments"] = []string{"-test.run=^TestBuildCommandRunner$", "--", reportSource, "${outputFile}"}
	contents, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	instance := buildCommandInstance(".", false)
	instance.BuildSystemID, instance.Manifest = "sample", contents
	instance.System.Test = &pluginservice.BuildTestDeclaration{Discovery: true, DiscoveryCommand: true}
	return instance
}

func TestBuildCommandDiscoversExactTestsAndRecordsItsResult(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	kernel := h.app.kernel.(buildTestDiscoveryKernel)
	fixture := contractfixture.Path("fixtures/build-systems/build-command-test-discovery.json")
	for _, tc := range []struct {
		mode  string
		file  string
		stage core.PluginStage
	}{
		{mode: "discover-tests", file: fixture},
		{mode: "fail", file: fixture, stage: core.StageExit},
		{mode: "garbage", file: fixture, stage: core.StageDecode},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			writeBuildCommandMarker(t, p.root, tc.mode)
			instance := commandDiscoveryTestInstance(t, tc.file)
			ctx := buildLoadContext(t, "action-discovery", pluginOperationWait)
			result, err := h.app.buildTestDiscovery(ctx, p, instance, kernel, false)
			if tc.stage != "" {
				if err == nil || len(result.Tests) != 0 {
					t.Fatalf("discovery = %+v, error = %v", result, err)
				}
				wantPluginOperation(t, plugins.next(t, tc.mode), failedBuildCommand(core.OperationBuildTestDiscovery, "action-discovery", tc.stage))
			} else {
				if err != nil || len(result.Tests) != 2 || result.Tests[0].ID == result.Tests[1].ID {
					t.Fatalf("discovery = %+v, error = %v", result, err)
				}
				for _, test := range result.Tests {
					plan, err := core.NewClient().PlanBuildTest(ctx, instance.Manifest, instance.BuildSystemID, core.BuildTestRequest{
						Root: instance.Root, WorkspaceRoot: p.root, Project: test.Project, Target: test.Target, Suite: test.Suite, Case: test.Case,
					})
					if err != nil || !slices.Contains(plan.Arguments, "--case=checks spaces # [exact]") {
						t.Fatalf("exact test plan = %+v, error = %v", plan, err)
					}
				}
				wantPluginOperation(t, plugins.next(t, tc.mode), core.PluginOperation{PluginID: buildCommandPluginID, Operation: core.OperationBuildTestDiscovery, Outcome: "finished", OperationID: "action-discovery"})
			}
			plugins.none(t)
			entries, err := os.ReadDir(buildStateDirectory(h.app.plugins.Root, p.root, instance))
			if err != nil || len(entries) != 0 {
				t.Fatalf("discovery left state entries %v (%v)", entries, err)
			}
		})
	}
}

func TestBuildCommandDiscoveryRevocationCancelsTheProcess(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	ready := filepath.Join(t.TempDir(), "discovery-ready")
	writeBuildCommandMarker(t, p.root, "discover-blocked")
	instance := commandDiscoveryTestInstance(t, ready)
	h.app.discoverBuildTests(p, &instance, false)
	discovery := p.build.discovered[instance.ID]
	awaitStateWithin(t, h, 5*time.Second, "the discovery process to start", func() bool {
		_, err := os.Stat(ready)
		return err == nil
	})
	p.revokeBuildTests(instance.ID)
	state := buildStateDirectory(h.app.plugins.Root, p.root, instance)
	awaitStateWithin(t, h, 5*time.Second, "the cancelled discovery process to release its report directory", func() bool {
		entries, err := os.ReadDir(state)
		return err == nil && len(entries) == 0
	})
	if p.build.discovered[instance.ID] != nil || discovery.loaded {
		t.Fatal("revoked discovery published a result")
	}
	plugins.none(t)
}

func TestBuildCommandModelLoadIsRecordedAtTheStageItEnded(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	withoutTool := installBuildTool(t)
	for _, tc := range []struct {
		name   string
		mode   string
		root   string
		noTool bool
		want   core.PluginOperation
	}{
		{name: "the model decodes", mode: "model", root: ".", want: core.PluginOperation{PluginID: buildCommandPluginID, Operation: core.OperationBuildModel, Outcome: "finished", OperationID: "action-41"}},
		{name: "the command fails", mode: "fail", root: ".", want: failedBuildCommand(core.OperationBuildModel, "action-41", core.StageExit)},
		{name: "the output is no model", mode: "garbage", root: ".", want: failedBuildCommand(core.OperationBuildModel, "action-41", core.StageDecode)},
		{name: "the command cannot start", mode: "model", root: "absent", want: failedBuildCommand(core.OperationBuildModel, "action-41", core.StageLaunch)},
		{name: "no build tool is found", mode: "model", root: ".", noTool: true, want: failedBuildCommand(core.OperationBuildModel, "action-41", core.StageResolve)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			writeBuildCommandMarker(t, p.root, tc.mode)
			if tc.noTool {
				t.Setenv("PATH", withoutTool)
			}
			model, err := h.app.commandModel(buildLoadContext(t, "action-41", pluginOperationWait), p, buildCommandInstance(tc.root, false), h.app.kernel, nil, h.app.text.Build)
			if (err == nil) != (tc.want.Outcome == "finished") {
				t.Fatalf("load error = %v, want outcome %s", err, tc.want.Outcome)
			}
			if err == nil && len(model.Projects) != 1 {
				t.Fatalf("model = %+v, want the fixture project", model)
			}
			wantPluginOperation(t, plugins.next(t, tc.name), tc.want)
			plugins.none(t)
		})
	}
}

func TestBuildCommandModelLoadPastItsDeadlineIsRecordedAsATimeout(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	writeBuildCommandMarker(t, p.root, "hang")
	_, err := h.app.commandModel(buildLoadContext(t, "action-42", 500*time.Millisecond), p, buildCommandInstance(".", false), h.app.kernel, nil, h.app.text.Build)
	if err == nil {
		t.Fatal("a load past its deadline succeeded")
	}
	wantPluginOperation(t, plugins.next(t, "the hung model command"), failedBuildCommand(core.OperationBuildModel, "action-42", core.StageTimeout))
	plugins.none(t)
}

func TestBuildCommandLoadTheProjectCancelsIsNotRecorded(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	writeBuildCommandMarker(t, p.root, "model")
	ctx, cancel := context.WithCancel(core.WithOrigin(context.Background(), core.Origin{Operation: "action-43"}))
	cancel()
	if _, err := h.app.commandModel(ctx, p, buildCommandInstance(".", false), h.app.kernel, nil, h.app.text.Build); err == nil {
		t.Fatal("a cancelled model load succeeded")
	}
	kernel := h.app.kernel.(buildDependencyKernel)
	if _, err := h.app.buildDependencyTree(ctx, p, buildCommandInstance(".", false), kernel, nil, false); err == nil {
		t.Fatal("a cancelled dependency load succeeded")
	}
	plugins.none(t)
}

func TestBuildCommandDependencyLoadIsRecordedAtTheStageItEnded(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	withoutTool := installBuildTool(t)
	kernel, ok := h.app.kernel.(buildDependencyKernel)
	if !ok {
		t.Fatal("the test kernel does not load dependencies")
	}
	for _, tc := range []struct {
		name     string
		mode     string
		provider bool
		noTool   bool
		want     core.PluginOperation
	}{
		{name: "the tree decodes", mode: "dependencies", want: core.PluginOperation{PluginID: buildCommandPluginID, Operation: core.OperationBuildDependencies, Outcome: "finished", OperationID: "action-51"}},
		{name: "a provider system's command plan decodes", mode: "dependencies", provider: true, want: core.PluginOperation{PluginID: buildCommandPluginID, Operation: core.OperationBuildDependencies, Outcome: "finished", OperationID: "action-51"}},
		{name: "the command fails", mode: "fail", want: failedBuildCommand(core.OperationBuildDependencies, "action-51", core.StageExit)},
		{name: "the output is no tree", mode: "garbage", want: failedBuildCommand(core.OperationBuildDependencies, "action-51", core.StageDecode)},
		{name: "no build tool is found", mode: "dependencies", noTool: true, want: failedBuildCommand(core.OperationBuildDependencies, "action-51", core.StageResolve)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			writeBuildCommandMarker(t, p.root, tc.mode)
			if tc.noTool {
				t.Setenv("PATH", withoutTool)
			}
			tree, err := h.app.buildDependencyTree(buildLoadContext(t, "action-51", pluginOperationWait), p, buildCommandInstance(".", tc.provider), kernel, nil, false)
			if (err == nil) != (tc.want.Outcome == "finished") {
				t.Fatalf("load error = %v, want outcome %s", err, tc.want.Outcome)
			}
			if err == nil && len(tree.Dependencies) != 1 {
				t.Fatalf("tree = %+v, want the fixture dependency", tree)
			}
			wantPluginOperation(t, plugins.next(t, tc.name), tc.want)
			plugins.none(t)
		})
	}
}

// A provider-sourced dependency request that fails before its plan never ran a command, and
// what its provider does is the plugin's own to log.
func TestBuildProviderSystemFailingBeforeItsPlanIsNotRecorded(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	kernel := h.app.kernel.(buildDependencyKernel)
	ctx := buildLoadContext(t, "action-52", pluginOperationWait)
	instance := buildCommandInstance(".", true)
	instance.System.Dependencies.Source = "provider"
	if _, err := h.app.buildDependencyTree(ctx, p, instance, kernel, nil, false); err == nil {
		t.Fatal("a provider system without its build tool loaded a tree")
	}
	plugins.none(t)
}

// A system with a provider process may still read its tree with a command that writes to a
// file. The declaration's source, not the provider process, decides:
// the host allocates the output file and runs the command itself, where it used to send the
// plan request without the file, which Core refused with "pass outputFile".
func TestBuildProviderSystemReadsItsTreeWithAFileCommand(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	kernel := h.app.kernel.(buildDependencyKernel)
	writeBuildCommandMarker(t, p.root, "dependencies-file")
	instance := buildCommandInstance(".", true)
	instance.Manifest = json.RawMessage(buildCommandProviderManifest)
	tree, err := h.app.buildDependencyTree(buildLoadContext(t, "action-53", pluginOperationWait), p, instance, kernel, nil, false)
	if err != nil {
		t.Fatalf("the provider system's file command failed: %v", err)
	}
	if len(tree.Dependencies) != 1 || tree.Dependencies[0].Name != "fixture-dependency" {
		t.Fatalf("tree = %+v, want the fixture dependency from the output file", tree)
	}
	wantPluginOperation(t, plugins.next(t, "file command"), core.PluginOperation{PluginID: buildCommandPluginID, Operation: core.OperationBuildDependencies, Outcome: "finished", OperationID: "action-53"})
	plugins.none(t)
}

// The model of a system that declares a provider process but reads its model with a command
// comes from the command: the Build window and the settings source editor both load it through
// buildModel, which follows the model's source. The settings editor used to ask the provider
// process, which serves no model, so a source settings page could not read the plugin's modules.
func TestBuildProviderSystemReadsItsModelWithItsCommand(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	installBuildTool(t)
	writeBuildCommandMarker(t, p.root, "model")
	instance := buildCommandInstance(".", true)
	instance.Manifest = json.RawMessage(buildCommandProviderManifest)
	model, err := h.app.buildModel(buildLoadContext(t, "action-54", pluginOperationWait), p, instance, h.app.kernel, nil, h.app.text.Build, false)
	if err != nil {
		t.Fatalf("the provider system's model command failed: %v", err)
	}
	if len(model.Projects) != 1 || model.Projects[0].Name != "fixture" {
		t.Fatalf("model = %+v, want the command's project", model)
	}
	wantPluginOperation(t, plugins.next(t, "model command"), core.PluginOperation{PluginID: buildCommandPluginID, Operation: core.OperationBuildModel, Outcome: "finished", OperationID: "action-54"})
	plugins.none(t)
}

func TestBuildCommandStage(t *testing.T) {
	launch := &buildLaunchError{cause: errors.New("buildprocess: start fixture-build: no such directory")}
	for _, tc := range []struct {
		name   string
		runErr error
		want   core.PluginStage
	}{
		{name: "the process did not start", runErr: launch, want: core.StageLaunch},
		{name: "a joined start failure", runErr: errors.Join(launch, errors.New("decode")), want: core.StageLaunch},
		{name: "the process failed", runErr: errors.New("exit status 3"), want: core.StageExit},
		{name: "the process succeeded", want: core.StageDecode},
	} {
		if got := buildCommandStage(tc.runErr); got != tc.want {
			t.Errorf("%s: stage = %q, want %q", tc.name, got, tc.want)
		}
	}
	if launch.Error() != launch.cause.Error() || !errors.Is(launch, launch.cause) {
		t.Fatalf("a start failure changed its text or cause: %q", launch.Error())
	}
}

// Run and debug preparation carry the build executable the host resolves, as dependency and
// test requests do, so a provider that builds before launching uses the user's tool; without
// one the request goes out without the hint and the provider says what it misses.
func TestBuildRunPreparationCarriesTheResolvedTool(t *testing.T) {
	h, _, p := buildCommandHarness(t)
	withoutTool := installBuildTool(t)
	ctx := buildLoadContext(t, "action-61", pluginOperationWait)
	var request core.BuildPlanRequest
	h.app.addBuildToolHint(ctx, p, buildCommandInstance(".", true), &request)
	if request.Tool == nil || !strings.HasPrefix(filepath.Base(request.Tool.Executable), "fixture-build") {
		t.Fatalf("tool = %+v, want the fixture build tool", request.Tool)
	}
	t.Setenv("PATH", withoutTool)
	request = core.BuildPlanRequest{}
	h.app.addBuildToolHint(ctx, p, buildCommandInstance(".", true), &request)
	if request.Tool != nil {
		t.Fatalf("tool = %+v without a build tool on PATH", request.Tool)
	}
}
