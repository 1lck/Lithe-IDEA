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
	"github.com/vivaui/viva/gfx"
)

const runTypesPluginID = "dev.lithe.test.run-types"

// runTypesManifest declares one build system, detected by build.runtypes, with one run
// configuration kind of its own: a mode choice, a checkbox that adds -v, a required target and
// the user's program arguments, run by the fixture-build tool, which is the copied test binary
// running TestRunTypeRunner. The build system also declares one before-launch task, which runs
// the same tool with "task" and its required target.
const runTypesManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.run-types",
  "displayName": "Run Types Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0, "runConfigurationTypes": 0, "beforeLaunchTasks": 0},
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
    }],
    "beforeLaunchTasks": [{
      "id": "prepare",
      "displayName": "Fixture Task",
      "description": "Prepares the fixture.",
      "icon": {"host": "run"},
      "fields": [{"id": "target", "title": "Target", "kind": "text", "required": true}],
      "arguments": ["-test.run=^TestRunTypeRunner$", "--", "task", "${field:target}"]
    }]
  }]
}`

// runTypesChinese is the package's Chinese translation of the kind, the task and their fields.
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
  },
  "beforeLaunchTasks": {
    "fixture-runs": {
      "prepare": {
        "displayName": "夹具任务",
        "description": "准备夹具。",
        "fields": {"target": {"title": "任务目标"}}
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

// The menu of kinds keeps each row one line: a kind's description, in its plugin's translation,
// is the tip of the ⓘ at the row's end, shown while the pointer rests on the ⓘ, and pressing the
// ⓘ does not choose the kind.
func TestRunConfigKindMenuShowsDescriptionsBehindInfo(t *testing.T) {
	h, p, _ := runTypesHarness(t, "print", true)
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) {
		a.openRunConfigDialog(p, "")
		d.newMenu = runConfigNewMenuToolbar
	})
	h.settle()
	const title, description = "夹具运行", "运行夹具工具。"
	if !h.shows(title) || h.shows(description) {
		t.Fatalf("the menu shows the kind %v and its description %v, want the kind alone", h.shows(title), h.shows(description))
	}
	var info gfx.Hit
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Hint == description {
			info = hit
		}
	}
	if info.ID.IsZero() || info.Label != h.shared("native.moreInformation") {
		t.Fatalf("no ⓘ carries the description: %+v", info)
	}
	at := center(info.Bounds)
	if err := h.driver.Move(at.X, at.Y); err != nil {
		t.Fatalf("Move: %v", err)
	}
	if err := h.driver.Advance(150 * time.Millisecond); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	h.settle()
	if !h.shows(description) {
		t.Fatal("resting on the ⓘ does not show the kind's description")
	}
	h.click(at)
	h.settle()
	if d.newMenu != runConfigNewMenuToolbar || len(d.drafts) != 0 {
		t.Fatalf("pressing the ⓘ left the menu %v with drafts %v, want it open with none", d.newMenu, d.drafts)
	}
}

// runTypesIconHarness is runTypesHarness, in a dark theme, with the fixture's kind naming the
// package icon icons/fixture.svg, and icons/fixture-dark.svg as its dark variant, holding the
// given SVG documents. Logs go to the returned recorder from the start; the plugin root is
// returned too.
func runTypesIconHarness(t *testing.T, light, dark string) (*harness, *project, *treeRecordingLog, string) {
	t.Helper()
	options, root := runTypesOptions(t, "dark", "zh-Hans", "print", true)
	installed := filepath.Join(options.PluginRoot, runTypesPluginID, "1.0.0")
	manifest := strings.Replace(runTypesManifest, `"icon": {"host": "run"}`,
		`"icon": {"path": "icons/fixture.svg", "darkPath": "icons/fixture-dark.svg", "mode": "original"}`, 1)
	files := map[string]string{"plugin.json": manifest, "icons/fixture.svg": light, "icons/fixture-dark.svg": dark}
	for name, content := range files {
		target := filepath.Join(installed, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h := newHarnessWithOptions(t, options)
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	h.open(root)
	return h, awaitRunTypes(t, h, true), logger, options.PluginRoot
}

// pluginIconFailures are the logged failures to read a package icon.
func pluginIconFailures(logger *treeRecordingLog) []core.LogEvent {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var failures []core.LogEvent
	for _, event := range logger.events {
		if event.Event == backgroundFailedEvent && event.Fields["operation"] == "plugin_icon" {
			failures = append(failures, event)
		}
	}
	return failures
}

// iconFill is an SVG square in one color.
func iconFill(color string) string {
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M1 1H15V15H1Z" fill="` + color + `"/></svg>`
}

// A declared kind that names an SVG in its package is drawn with it in the + menu, in its own
// colors and, in a dark theme, its dark variant; the package stays as installed.
func TestRunConfigKindDrawsItsPackageIcon(t *testing.T) {
	h, p, logger, _ := runTypesIconHarness(t, iconFill("#FF0000"), iconFill("#0000FF"))
	if failures := pluginIconFailures(logger); len(failures) != 0 {
		t.Fatalf("the icon was not read: %+v", failures)
	}
	icon := p.runConfigs.kindIcon(declaredKind(runTypesKey), &h.app.pluginIcons, h.app.colors.Dark)
	if len(icon.Layers) != 1 || icon.Layers[0].Fill.Blue != 1 || icon.Layers[0].Fill.Red != 0 {
		t.Fatalf("the kind's icon = %+v, want the package's dark variant in its own color", icon)
	}
	if light := p.runConfigs.kindIcon(declaredKind(runTypesKey), &h.app.pluginIcons, false); len(light.Layers) != 1 || light.Layers[0].Fill.Red != 1 {
		t.Fatalf("the light theme's icon = %+v, want the package's icon", light)
	}
	h.app.post(func(a *App) {
		a.openRunConfigDialog(p, "")
		p.runConfigs.dialog.newMenu = runConfigNewMenuToolbar
	})
	h.settle()
	if !h.shows("夹具运行") {
		t.Fatal("the + menu does not list the kind")
	}
}

// An icon the contract refuses leaves the kind its execution's icon and is logged once, by its
// package-relative path and never by where the package is installed.
func TestRunConfigKindWithARefusedIconKeepsItsFallback(t *testing.T) {
	refused := `<svg viewBox="0 0 16 16" onload="x()"><path d="M1 1H15V15H1Z" fill="#FF0000"/></svg>`
	h, p, logger, pluginRoot := runTypesIconHarness(t, refused, iconFill("#0000FF"))
	kind := p.runConfigs.runTypeKind(runTypesKey)
	if kind == nil {
		t.Fatal("the kind is not listed")
	}
	icon := p.runConfigs.kindIcon(declaredKind(runTypesKey), &h.app.pluginIcons, h.app.colors.Dark)
	if fallback := runExecutionIcon(kind.Execution); !slices.Equal(icon.Commands, fallback.Commands) || len(icon.Layers) != 0 {
		t.Fatalf("a refused icon is drawn: %+v", icon)
	}
	// A second read of the kinds, as opening the dialog makes, does not log the same icon again.
	read := false
	h.app.post(func(a *App) {
		a.loadRunConfigTypes(p, true)
		read = p.runConfigs.typesLoading
	})
	awaitStateWithin(t, h, 20*time.Second, "the second read of the kinds", func() bool { return read && !p.runConfigs.typesLoading })
	failures := pluginIconFailures(logger)
	if len(failures) != 1 {
		t.Fatalf("the refused icon was logged %d times, want once: %+v", len(failures), failures)
	}
	message, _ := failures[0].Fields["error"].(string)
	if !strings.Contains(message, "icons/fixture.svg") || !strings.Contains(message, runTypesPluginID) || strings.Contains(message, pluginRoot) {
		t.Fatalf("the failure reads %q", message)
	}
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
