package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

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

// buildCommandMarker names the file in the command's working directory that tells the runner
// what to do: print a model or a tree, exit with a failure, print what is no document, or hang.
const buildCommandMarker = "build-command.marker"

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
	case "fail":
		os.Exit(3)
	case "explain":
		// A tool that says why it failed, in color, as Maven does with -Dstyle.color=always.
		fmt.Print("\x1b[1mScanning\x1b[m\r\n\r\n")
		fmt.Fprint(os.Stderr, "\x1b[1;31m[ERROR]\x1b[m The JAVA_HOME environment variable is not defined correctly\r\n")
		os.Exit(1)
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
	h.open(t.TempDir())
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
		System:        pluginservice.BuildSystemDeclaration{Provider: provider},
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
			model, err := h.app.commandModel(buildLoadContext(t, "action-41", pluginOperationWait), p, buildCommandInstance(tc.root, false), h.app.kernel, h.app.text.Build)
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
	_, err := h.app.commandModel(buildLoadContext(t, "action-42", 500*time.Millisecond), p, buildCommandInstance(".", false), h.app.kernel, h.app.text.Build)
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
	if _, err := h.app.commandModel(ctx, p, buildCommandInstance(".", false), h.app.kernel, h.app.text.Build); err == nil {
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

// A provider system that fails before its plan names a command never ran a command, and what
// its provider does is the plugin's own to log.
func TestBuildProviderSystemFailingBeforeItsPlanIsNotRecorded(t *testing.T) {
	h, plugins, p := buildCommandHarness(t)
	kernel := h.app.kernel.(buildDependencyKernel)
	ctx := buildLoadContext(t, "action-52", pluginOperationWait)
	if _, err := h.app.buildDependencyTree(ctx, p, buildCommandInstance(".", true), kernel, nil, false); err == nil {
		t.Fatal("a provider system without its build tool loaded a tree")
	}
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
