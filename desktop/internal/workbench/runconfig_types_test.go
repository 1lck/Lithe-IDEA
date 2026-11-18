package workbench

import (
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

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const runTypesPluginID = "dev.lithe.test.run-types"

// runTypesManifest declares one build system, detected by build.runtypes, with one run
// configuration kind of its own: a mode choice, a checkbox that adds -v, a required target and
// the user's program arguments, run by the fixture-build tool, which is the copied test binary
// running TestRunTypeRunner.
const runTypesManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.run-types",
  "displayName": "Run Types Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0, "runConfigurationTypes": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build"],
  "activationEvents": ["onBuildSystem:fixture-runs"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-runs",
    "displayName": "Fixture Runs",
    "detection": {"markers": ["build.runtypes"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-build"}]},
    "model": {
      "source": "command",
      "arguments": ["-test.run=^TestRunTypeRunner$", "--", "model"],
      "decoder": "litheBuildModel",
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "runConfigurationTypes": [{
      "id": "fixture",
      "displayName": "Fixture Run",
      "description": "Runs the fixture tool.",
      "icon": {"host": "run"},
      "fields": [
        {"id": "mode", "title": "Mode", "kind": "choice", "choices": [
          {"value": "slow", "title": "Slow"}, {"value": "fast", "title": "Fast"}
        ], "default": "slow"},
        {"id": "verbose", "title": "Verbose", "kind": "checkbox", "arguments": ["-v"]},
        {"id": "target", "title": "Target", "kind": "text", "placeholder": "a name", "required": true}
      ],
      "arguments": ["-test.run=^TestRunTypeRunner$", "--", "${field:mode}", "${field:verbose}", "${field:target}", "${userArguments}"]
    }]
  }]
}`

// runTypesChinese is the package's Chinese translation of the kind and its fields.
const runTypesChinese = `{
  "runConfigurationTypes": {
    "fixture-runs": {
      "fixture": {
        "displayName": "夹具运行",
        "description": "运行夹具工具。",
        "fields": {
          "mode": {"title": "模式", "options": {"slow": "慢速", "fast": "快速"}},
          "verbose": {"title": "详细输出"},
          "target": {"title": "目标"}
        }
      }
    }
  }
}`

// runTypeMarker names the file in the run's working directory that tells TestRunTypeRunner to
// print its arguments ("print") or to keep running until it is stopped ("hang").
const runTypeMarker = "run-type.marker"

// TestRunTypeRunner is the fixture build tool a declared run starts: it prints the arguments it
// got after "--", and in the hang mode keeps running until the host stops it.
func TestRunTypeRunner(t *testing.T) {
	mode, err := os.ReadFile(runTypeMarker)
	if err != nil {
		t.Skip("not the run type fixture workspace")
	}
	if arguments := flag.Args(); len(arguments) > 0 && arguments[0] == "model" {
		// The build system's model, which the project's sync reads when it opens.
		fmt.Print(`{"format":"litheBuildModel","version":0,"projects":[{"name":"fixture"}]}`)
		os.Exit(0)
	}
	fmt.Println("run-type ran: " + strings.Join(flag.Args(), " "))
	if string(mode) == "hang" {
		// Stop ends the process; this only outlives the test's bounded wait for it.
		time.Sleep(pluginOperationWait)
	}
	os.Exit(0)
}

// runTypesKey is the fixture's declared kind.
var runTypesKey = core.RunTypeKey{PluginID: runTypesPluginID, BuildSystemID: "fixture-runs", Type: "fixture"}

// runTypesHarness installs and enables the run types fixture with its Chinese translation,
// puts the fixture build tool on PATH and opens a workspace that holds the build system's
// marker, unless detected is false, and the runner's marker in mode. It waits until the kinds
// and the configurations are read.
func runTypesHarness(t *testing.T, mode string, detected bool) (*harness, *project, string) {
	t.Helper()
	options, root := runTypesOptions(t, "dark", "zh-Hans", mode, detected)
	h := newHarnessWithOptions(t, options)
	h.open(root)
	return h, awaitRunTypes(t, h, detected), root
}

// runTypesOptions are runTypesHarness's options in theme and language, with the workspace it
// opens.
func runTypesOptions(t *testing.T, theme, language, mode string, detected bool) (Options, string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"`+theme+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, runTypesPluginID, "1.0.0")
	if err := os.MkdirAll(filepath.Join(installed, "l10n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(runTypesManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "l10n", "zh-Hans.json"), []byte(runTypesChinese), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled(runTypesPluginID, true); err != nil {
		t.Fatal(err)
	}
	installBuildTool(t)
	if runtime.GOOS == "windows" {
		t.Setenv("PATHEXT", ".EXE")
	}
	root := filepath.Join(t.TempDir(), "RunTypesDemo")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	markers := map[string]string{runTypeMarker: mode}
	if detected {
		markers["build.runtypes"] = "fixture\n"
	}
	for name, text := range markers {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{language},
	}, root
}

// awaitRunTypes reads the open project's configurations and waits until they, the kinds and
// the build system's detection, as detected says, are in.
func awaitRunTypes(t *testing.T, h *harness, detected bool) *project {
	t.Helper()
	p := h.app.project
	h.app.post(func(a *App) { a.loadTitleRunConfigs(p) })
	awaitStateWithin(t, h, 20*time.Second, "the detected build system and the kinds", func() bool {
		s := &p.runConfigs
		return p.runConfigsSettled() && !s.typesLoading && s.types != nil && p.hasRunTypeInstance(runTypesKey) == detected
	})
	return p
}

// newDeclaredRunDraft opens the dialog, adds a configuration of the fixture's kind as its +
// menu does and waits for the form, which reads the kind's fields in Chinese.
func newDeclaredRunDraft(t *testing.T, h *harness, p *project) *runConfigForm {
	t.Helper()
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) {
		a.openRunConfigDialog(p, "")
		a.addRunConfigDraft(p, declaredKind(runTypesKey), nil)
	})
	var f *runConfigForm
	awaitStateWithin(t, h, 10*time.Second, "the declared kind's form", func() bool {
		if draft := d.drafts[d.selected]; d.open && draft != nil && draft.form != nil {
			f = draft.form
		}
		return f != nil && f.ready() && f.fields != nil
	})
	if f.failure != "" {
		t.Fatalf("form failure %q", f.failure)
	}
	return f
}

// fillDeclaredRun names form f, sets the kind's fields and the program arguments and waits for
// the form to follow the edit.
func fillDeclaredRun(t *testing.T, h *harness, p *project, f *runConfigForm, name string, multiple bool) {
	t.Helper()
	h.app.post(func(a *App) {
		*f.texts["name"] = name
		*f.texts["field:mode"] = "fast"
		*f.flags["field:verbose"] = true
		*f.texts["field:target"] = "alpha"
		*f.texts["programArguments"] = "one two"
		*f.flags["storeAsProjectFile"] = true
		*f.flags["allowMultipleInstances"] = multiple
		a.runConfigFormEdited(p, f)
	})
	awaitStateWithin(t, h, 10*time.Second, "the edited form", func() bool { return !f.refreshing })
}

// A plugin's declared kind lists in the plugin's translation; the + menu adds it to a dialog
// group of its own, whose form shows the kind's translated fields beside the host's. The saved
// configuration is a build.run-type entry in the project file, and Run starts the build tool
// with the arguments the kind's template makes of the fields.
func TestPluginDeclaredRunKindIsCreatedSavedAndRun(t *testing.T) {
	h, p, root := runTypesHarness(t, "print", true)
	s := &p.runConfigs
	kind := s.runTypeKind(runTypesKey)
	if kind == nil || kind.DisplayName != "夹具运行" || kind.Description != "运行夹具工具。" {
		t.Fatalf("declared kind = %+v among %+v", kind, s.types)
	}
	if s.typePlugins == nil || len(s.typePlugins.Plugins) != 1 || s.typePlugins.Plugins[0].Localizations["l10n/zh-Hans.json"] == "" {
		t.Fatalf("declaring plugins = %+v, want the fixture with its translation read", s.typePlugins)
	}
	if got := s.kindTitle(h.app.language(), declaredKind(runTypesKey)); got != "夹具运行" {
		t.Fatalf("kind title = %q", got)
	}

	f := newDeclaredRunDraft(t, h, p)
	d := &s.dialog
	if group := p.runConfigDialogGroupKey(d.selected); group != declaredKind(runTypesKey).groupKey() {
		t.Fatalf("draft group = %q, want the declared kind's own", group)
	}
	labels := map[string]core.RunEditorField{}
	var order []string
	for _, field := range f.fields {
		labels[field.ID] = field
		order = append(order, field.ID)
	}
	if mode := labels["field:mode"]; mode.Label != "模式" || mode.OptionLabels["fast"] != "快速" {
		t.Fatalf("mode field = %+v", mode)
	}
	if target := labels["field:target"]; target.Label != "目标" || target.Placeholder != "a name" || !target.Required {
		t.Fatalf("target field = %+v", target)
	}
	for _, id := range []string{"name", "allowMultipleInstances", "programArguments", "workingDirectory", "environment"} {
		if !slices.Contains(order, id) {
			t.Fatalf("fields %v lack the host's %s", order, id)
		}
	}
	h.settle()
	for _, text := range []string{"夹具运行", "模式", "详细输出", "目标", "允许多个实例"} {
		if !h.shows(text) {
			t.Fatalf("the dialog does not show %q", text)
		}
	}

	fillDeclaredRun(t, h, p, f, "Fixture Alpha", false)
	applyDialog(t, h, p, runConfigDialogRun)
	if d.open {
		t.Fatalf("the dialog stayed open: errors %v failure %q / %q", f.errors, f.failure, d.failure)
	}
	run := awaitProcessRun(t, h, p, "Fixture Alpha", nil)
	if !strings.Contains(run.output.all(), "run-type ran: fast -v alpha one two") {
		t.Fatalf("console:\n%s", run.output.all())
	}
	if len(s.list) != 1 {
		t.Fatalf("configurations = %+v", s.list)
	}
	if key, ok := s.list[0].RunTypeReference(); !ok || key != runTypesKey || s.list[0].AllowMultipleInstances {
		t.Fatalf("saved configuration = %+v", s.list[0])
	}
	// A project configuration of a declared kind is kept in its plugin's run document.
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "plugin", runTypesPluginID+".toml"))
	if err != nil || !strings.Contains(string(data), "Fixture Alpha") || !strings.Contains(string(data), "fixture-runs") {
		t.Fatalf("plugin run document = %s, %v", data, err)
	}

	// No declared kind has a debugger.
	var refused error
	id := s.list[0].ID
	h.app.post(func(a *App) { _, refused = a.startRunConfigurationWith(p, id, &connectionDebug{}) })
	h.settle()
	var refusal *buildRefusal
	if !errors.As(refused, &refusal) || refusal.code != refusalNotSupported {
		t.Fatalf("debug start = %v, want not supported", refused)
	}
}

// A declared configuration that allows several instances starts a second one beside the one
// that runs, in a tab of its own; a debug start beside them is still refused, since only a run
// starts beside one of the same configuration. Stop ends both.
func TestPluginDeclaredRunStartsSeveralInstances(t *testing.T) {
	h, p, _ := runTypesHarness(t, "hang", true)
	f := newDeclaredRunDraft(t, h, p)
	fillDeclaredRun(t, h, p, f, "Fixture Hang", true)
	applyDialog(t, h, p, runConfigDialogOK)
	s := &p.runConfigs
	if len(s.list) != 1 || !s.list[0].AllowMultipleInstances {
		t.Fatalf("configurations = %+v failure %q", s.list, f.failure)
	}
	id := s.list[0].ID
	running := func() []*runEntry {
		var entries []*runEntry
		for _, entry := range p.build.runs {
			if entry.label == "Fixture Hang" && entry.running && strings.Contains(entry.output.all(), "run-type ran:") {
				entries = append(entries, entry)
			}
		}
		return entries
	}
	defer func() {
		h.app.post(func(a *App) {
			for _, op := range slices.Clone(p.build.running) {
				a.stopOperation(p, op)
			}
		})
		awaitStateWithin(t, h, 20*time.Second, "every instance to end", func() bool { return len(p.build.running) == 0 })
	}()
	h.app.post(func(a *App) { a.runConfiguration(p, id) })
	awaitStateWithin(t, h, 20*time.Second, "the first instance", func() bool { return len(running()) == 1 })
	h.app.post(func(a *App) { a.runConfiguration(p, id) })
	awaitStateWithin(t, h, 20*time.Second, "the second instance beside the first", func() bool { return len(running()) == 2 })
	if entries := running(); entries[0].id == entries[1].id {
		t.Fatalf("both instances share tab %q", entries[0].id)
	}

	// The hanging instances keep background work going, so the wait is for the answer alone.
	var refused error
	answered := false
	h.app.post(func(a *App) {
		_, refused = a.startRunConfigurationWith(p, id, &connectionDebug{})
		answered = true
	})
	awaitStateWithin(t, h, 10*time.Second, "the debug start's answer", func() bool { return answered })
	var refusal *buildRefusal
	if !errors.As(refused, &refusal) || refusal.code != refusalBusy {
		t.Fatalf("debug start = %v, want busy", refused)
	}
	if len(running()) != 2 {
		t.Fatalf("running instances = %d after the debug start, want 2", len(running()))
	}
}

// A declared configuration whose build system is not detected in the project lists, but the
// title bar says its instance is missing and a start is refused without running anything.
func TestPluginDeclaredRunWithoutItsBuildSystemDoesNotStart(t *testing.T) {
	h, p, root := runTypesHarness(t, "print", false)
	// The plugin's run document as the dialog saves it (TestPluginDeclaredRunKindIsCreatedSavedAndRun).
	saved := `schemaVersion = 1

[plugin]
id = "dev.lithe.test.run-types"
name = "Run Types Fixture"
version = "1.0.0"
versionRequirement = ">=1.0.0"
pluginAPIVersion = 0

[plugin.capabilities]
buildSystems = 0
runConfigurationTypes = 0

[[configurations]]
id = "user:fixture"
name = "Fixture"
provider = "build.run-type"
confidence = "declared"

[configurations.extensions.build]
pluginID = "dev.lithe.test.run-types"
buildSystemID = "fixture-runs"
type = "fixture"

[configurations.extensions.build.values]
target = "alpha"
`
	documents := filepath.Join(root, ".lithe", "run", "plugin")
	if err := os.MkdirAll(documents, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(documents, runTypesPluginID+".toml"), []byte(saved), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the saved declared configuration", func() bool {
		return p.runConfigsSettled() && len(p.runConfigs.list) == 1
	})
	configuration := p.runConfigs.list[0]
	if key, ok := configuration.RunTypeReference(); !ok || key != runTypesKey {
		t.Fatalf("configuration = %+v", configuration)
	}
	if p.runConfigurationReady(configuration) {
		t.Fatal("a declared configuration without its build system reads as ready")
	}
	var refused error
	h.app.post(func(a *App) { _, refused = a.startRunConfiguration(p, configuration.ID) })
	h.settle()
	var refusal *buildRefusal
	if !errors.As(refused, &refusal) || refusal.code != refusalNotReady {
		t.Fatalf("start = %v, want not ready", refused)
	}
	if len(p.build.runs) != 0 || p.build.active() {
		t.Fatalf("a run started: %d sessions", len(p.build.runs))
	}
}
