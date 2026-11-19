package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// beforeLaunchScript is a built-in run of the system's own shell (cmd on Windows) whose text
// prints line, sleeps or exits with code; so the tests need no developer tool.
func beforeLaunchScript(id string, text map[string]string, steps ...string) map[string]any {
	provider, script := runProviderShell, text["unix"]
	if runtime.GOOS == "windows" {
		provider, script = runProviderBatch, text["windows"]
	}
	entry := map[string]any{
		"id": id, "name": strings.TrimPrefix(id, "user:"), "provider": provider, "confidence": "declared",
		"extensions": map[string]any{"process": map[string]any{"text": script}},
	}
	if len(steps) > 0 {
		named := []map[string]string{}
		for _, step := range steps {
			named = append(named, map[string]string{"configuration": step})
		}
		entry["beforeLaunch"] = named
	}
	return entry
}

func beforeLaunchEcho(id, line string, steps ...string) map[string]any {
	return beforeLaunchScript(id, map[string]string{"unix": "echo " + line + "\n", "windows": "@echo " + line + "\r\n"}, steps...)
}

// writeBeforeLaunchDocument writes a run configuration layer; YAML reads the JSON as it is.
func writeBeforeLaunchDocument(t *testing.T, root, file string, configurations ...map[string]any) {
	t.Helper()
	data, err := json.Marshal(map[string]any{"version": 2, "configurations": configurations})
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(root, ".lithe", "run")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, file), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// openBeforeLaunchProject opens root with the real Core and waits for its configurations.
func openBeforeLaunchProject(t *testing.T, root string) (*harness, *project) {
	t.Helper()
	temporary := t.TempDir()
	for _, variable := range []string{"TMPDIR", "TMP", "TEMP"} {
		t.Setenv(variable, temporary)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the run configurations", func() bool {
		return p.runConfigs.generation > 0 && !p.runConfigs.loading
	})
	if p.runConfigs.failure != "" {
		t.Fatalf("configurations failed: %s", p.runConfigs.failure)
	}
	return h, p
}

// awaitEndedRun waits for the session labeled label other than previous to end, whatever
// its outcome.
func awaitEndedRun(t *testing.T, h *harness, p *project, label string, previous *runEntry) *runEntry {
	t.Helper()
	var found *runEntry
	awaitStateWithin(t, h, 20*time.Second, "the end of "+label, func() bool {
		for _, entry := range p.build.runs {
			if entry != previous && entry.label == label && !entry.running && !p.build.active() {
				found = entry
				return true
			}
		}
		return false
	})
	return found
}

// Steps a project file names ask once: Run starts them in order, nested steps first, with
// their output in the console of the configuration, and the configuration after them. The
// answer is remembered, so the next start runs the steps without asking.
func TestBeforeLaunchStepsRunInOrderAfterTheProjectListIsAllowed(t *testing.T) {
	root := t.TempDir()
	writeBeforeLaunchDocument(t, root, "configurations.yaml",
		beforeLaunchEcho("user:generate", "step-generate"),
		beforeLaunchEcho("user:compile", "step-compile", "user:generate"),
		beforeLaunchEcho("user:app", "app-ran", "user:compile"),
	)
	h, p := openBeforeLaunchProject(t, root)

	h.app.post(func(a *App) { a.runConfiguration(p, "user:app") })
	awaitStateWithin(t, h, 10*time.Second, "the confirmation", func() bool { return p.runConfigs.beforeLaunch != nil })
	ask := p.runConfigs.beforeLaunch
	if len(ask.steps) != 2 || ask.steps[0].ConfigurationID != "user:generate" || ask.steps[1].ConfigurationID != "user:compile" {
		t.Fatalf("steps = %+v", ask.steps)
	}
	h.settle()
	run := i18n.Shared(h.app.language(), "desktop.runConfig.beforeLaunch.confirmRun")
	if !h.shows(run) || !h.shows("1. generate") {
		t.Fatal("the confirmation does not list the steps")
	}
	h.clickNamed(run)
	first := awaitProcessRun(t, h, p, "app", nil)
	console := first.output.all()
	generate, compile, app := strings.Index(console, "step-generate"), strings.Index(console, "step-compile"), strings.Index(console, "app-ran")
	if generate < 0 || compile < generate || app < compile {
		t.Fatalf("the steps did not run in order before the configuration; console:\n%s", console)
	}

	h.app.post(func(a *App) { a.runConfiguration(p, "user:app") })
	again := awaitProcessRun(t, h, p, "app", first)
	if p.runConfigs.beforeLaunch != nil || !strings.Contains(again.output.all(), "step-compile") {
		t.Fatalf("the allowed list was asked again or skipped; console:\n%s", again.output.all())
	}

	// A changed list is a new question.
	writeBeforeLaunchDocument(t, root, "configurations.yaml",
		beforeLaunchEcho("user:generate", "step-generate-changed"),
		beforeLaunchEcho("user:compile", "step-compile", "user:generate"),
		beforeLaunchEcho("user:app", "app-ran", "user:compile"),
	)
	h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the changed configurations", func() bool { return !p.runConfigs.loading })
	h.app.post(func(a *App) { a.runConfiguration(p, "user:app") })
	awaitStateWithin(t, h, 10*time.Second, "the new confirmation", func() bool { return p.runConfigs.beforeLaunch != nil })
	h.app.post(func(a *App) { a.cancelBeforeLaunch(p) })
	cancelled := awaitEndedRun(t, h, p, "app", again)
	if cancelled.outcome == runSucceeded || strings.Contains(cancelled.output.all(), "app-ran") {
		t.Fatalf("a cancelled confirmation started the configuration; console:\n%s", cancelled.output.all())
	}
}

// A step that exits with a code other than 0 ends the start: the configuration does not run
// and the console names the step and its code. Steps of the user's own file run unasked.
func TestFailingBeforeLaunchStepStopsTheStart(t *testing.T) {
	root := t.TempDir()
	writeBeforeLaunchDocument(t, root, "local.yaml",
		beforeLaunchScript("user:check", map[string]string{"unix": "echo checking\nexit 3\n", "windows": "@echo checking\r\n@exit /b 3\r\n"}),
		beforeLaunchEcho("user:app", "app-ran", "user:check"),
	)
	h, p := openBeforeLaunchProject(t, root)
	h.app.post(func(a *App) { a.runConfiguration(p, "user:app") })
	ended := awaitEndedRun(t, h, p, "app", nil)
	console := ended.output.all()
	want := i18n.SharedFormat(h.app.language(), "desktop.runConfig.beforeLaunch.exited", map[string]string{"name": "check", "code": "3"})
	if ended.outcome == runSucceeded || strings.Contains(console, "app-ran") || !strings.Contains(console, "checking") || !strings.Contains(console, want) {
		t.Fatalf("outcome %v; console:\n%s", ended.outcome, console)
	}
}

// Stopping the configuration while a step runs stops the step, and the configuration does
// not start.
func TestStoppingDuringABeforeLaunchStepEndsIt(t *testing.T) {
	root := t.TempDir()
	writeBeforeLaunchDocument(t, root, "local.yaml",
		beforeLaunchScript("user:wait", map[string]string{"unix": "echo waiting\nsleep 30\n", "windows": "@echo waiting\r\n@ping -n 30 127.0.0.1 >nul\r\n"}),
		beforeLaunchEcho("user:app", "app-ran", "user:wait"),
	)
	h, p := openBeforeLaunchProject(t, root)
	h.app.post(func(a *App) { a.runConfiguration(p, "user:app") })
	var entry *runEntry
	awaitStateWithin(t, h, 10*time.Second, "the step's output", func() bool {
		for _, candidate := range p.build.runs {
			if candidate.label == "app" && strings.Contains(candidate.output.all(), "waiting") {
				entry = candidate
				return true
			}
		}
		return false
	})
	started := time.Now()
	h.app.post(func(a *App) { a.stopRun(p, entry) })
	ended := awaitEndedRun(t, h, p, "app", nil)
	if elapsed := time.Since(started); elapsed > 15*time.Second {
		t.Fatalf("the stop took %v", elapsed)
	}
	if ended.outcome == runSucceeded || strings.Contains(ended.output.all(), "app-ran") {
		t.Fatalf("outcome %v; console:\n%s", ended.outcome, ended.output.all())
	}
}

// The editor keeps the steps Core read, process runs and plugin tasks alike, sends the edited
// list in order, and counts a list as changed only when what it saves changed: the name and
// summary Core gave a task are not saved.
func TestRunConfigFormKeepsTheStepList(t *testing.T) {
	task := `{"task":{"pluginID":"io.example","buildSystemID":"go","type":"command","values":{"command":"generate"}},"name":"Run Go command","summary":"go generate"}`
	f := &runConfigForm{values: map[string]json.RawMessage{}, texts: map[string]*string{}, flags: map[string]*bool{}}
	f.fields = []core.RunEditorField{{ID: "beforeLaunch", Kind: runFieldBeforeLaunch}}
	f.readValues(f.fields, map[string]json.RawMessage{"beforeLaunch": json.RawMessage(`["user:a",` + task + `,"user:b"]`)})
	if !f.drawable(i18n.English, f.fields[0]) {
		t.Fatal("the step field is not drawn")
	}
	read := slices.Clone(f.beforeLaunch.items)
	moveRunConfigStep(f.beforeLaunch.items, 2, 0)
	moveRunConfigStep(f.beforeLaunch.items, 2, 3)
	var collected []json.RawMessage
	if err := json.Unmarshal(f.collect()["beforeLaunch"], &collected); err != nil || len(collected) != 3 {
		t.Fatalf("collected %s (%v)", f.collect()["beforeLaunch"], err)
	}
	if string(collected[0]) != `"user:b"` || string(collected[2]) != `"user:a"` {
		t.Fatalf("collected %s", f.collect()["beforeLaunch"])
	}
	var step core.RunTaskStep
	if err := json.Unmarshal(collected[1], &step); err != nil || step.Task.Type != "command" || string(step.Task.Values) != `{"command":"generate"}` {
		t.Fatalf("the task step collected as %s (%v)", collected[1], err)
	}

	renamed := slices.Clone(read)
	renamedTask := *renamed[1].Task
	renamedTask.Name, renamedTask.Summary = "another name", "another summary"
	renamed[1].Task = &renamedTask
	if !sameRunConfigSteps(read, renamed) {
		t.Fatal("a task's name and summary count as a change")
	}
	if sameRunConfigSteps(read, f.beforeLaunch.items) {
		t.Fatal("a moved step does not count as a change")
	}

	empty := &runConfigForm{values: map[string]json.RawMessage{}, texts: map[string]*string{}, flags: map[string]*bool{}}
	empty.fields = f.fields
	empty.readValues(empty.fields, map[string]json.RawMessage{})
	if got := string(empty.collect()["beforeLaunch"]); got != `[]` {
		t.Fatalf("an empty list collected %s", got)
	}
}

// In the Run/Debug Configurations window a step added from the Add New Task menu (Run Another
// Configuration) counts as a change, so Apply saves it with the configuration and the dialog
// shows nothing left to save.
func TestRunConfigDialogSavesAnAddedStep(t *testing.T) {
	root := t.TempDir()
	writeBeforeLaunchDocument(t, root, "local.yaml",
		beforeLaunchEcho("user:generate", "step-generate"),
		beforeLaunchEcho("user:app", "app-ran"),
	)
	h, p := openBeforeLaunchProject(t, root)
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) { a.openRunConfigDialog(p, "user:app") })
	var f *runConfigForm
	awaitStateWithin(t, h, 10*time.Second, "the editor of app", func() bool {
		if draft := d.drafts["user:app"]; draft != nil {
			f = draft.form
		}
		return f != nil && f.ready() && f.beforeLaunch != nil
	})
	h.settle()
	if d.dirty() {
		t.Fatal("the opened configuration shows as something to save")
	}
	h.clickNamed(i18n.Shared(h.app.language(), "desktop.runConfig.beforeLaunchAdd"))
	h.clickNamed(i18n.Shared(h.app.language(), "desktop.runConfig.beforeLaunchRunAnother"))
	h.clickNamed("generate")
	h.settle()
	if len(f.beforeLaunch.items) != 1 || f.beforeLaunch.items[0].ConfigurationID != "user:generate" || !d.dirty() {
		t.Fatalf("steps %+v, dirty %v after the menu added one", f.beforeLaunch.items, d.dirty())
	}

	applyDialog(t, h, p, runConfigDialogApply)
	configuration := p.runConfigs.configuration("user:app")
	if configuration == nil || len(configuration.BeforeLaunch) != 1 || configuration.BeforeLaunch[0].Configuration != "user:generate" {
		t.Fatalf("configuration = %+v, failure %q / %q", configuration, d.failure, f.failure)
	}
	if !d.open || d.dirty() {
		t.Fatalf("dialog open %v dirty %v after Apply", d.open, d.dirty())
	}
}

// A task a plugin declares is an entry of the Before Launch menu, under its translated name:
// choosing it opens the task's own form, OK has Core check the values, a missing required one
// stays in the form under its field, and the step Core returns joins the list. The saved
// configuration runs the task by the plugin's build tool before it starts, after the project
// file's list was allowed, with the task's output first in the configuration's console.
func TestPluginDeclaredBeforeLaunchTaskIsAddedAndRunsFirst(t *testing.T) {
	h, p, root := runTypesHarness(t, "print", true)
	f := newDeclaredRunDraft(t, h, p)
	if f.beforeLaunch == nil {
		t.Fatal("the new configuration has no Before Launch list")
	}
	fillDeclaredRun(t, h, p, f, "Fixture Alpha", false)
	h.settle()
	language := h.app.language()
	h.clickNamed(i18n.Shared(language, "desktop.runConfig.beforeLaunchAdd"))
	h.settle()
	if !h.shows(i18n.Shared(language, "desktop.runConfig.beforeLaunchRunAnother")) || !h.shows("夹具任务") {
		t.Fatal("the Before Launch menu does not offer the plugin's task under its Chinese name")
	}
	h.clickNamed("夹具任务")
	awaitStateWithin(t, h, 10*time.Second, "the task form", func() bool { return p.runConfigs.task != nil })
	task := p.runConfigs.task
	h.settle()
	if !h.shows("任务目标") || !h.shows("准备夹具。") {
		t.Fatal("the task form does not show the task's translated field and description")
	}

	ok := i18n.Shared(language, "desktop.runConfig.ok")
	h.clickNamed(ok)
	awaitStateWithin(t, h, 10*time.Second, "Core's check of the empty target", func() bool { return !task.checking })
	if p.runConfigs.task != task || task.form.errors["field:target"] != "required" || len(f.beforeLaunch.items) != 0 {
		t.Fatalf("an empty required target: form open %v, errors %v, steps %+v", p.runConfigs.task == task, task.form.errors, f.beforeLaunch.items)
	}
	h.app.post(func(a *App) { *task.form.texts["field:target"] = "beta" })
	h.settle()
	h.clickNamed(ok)
	awaitStateWithin(t, h, 10*time.Second, "the added task step", func() bool { return p.runConfigs.task == nil })
	prepare := core.RunTypeKey{PluginID: runTypesPluginID, BuildSystemID: "fixture-runs", Type: "prepare"}
	if len(f.beforeLaunch.items) != 1 || f.beforeLaunch.items[0].Task == nil || f.beforeLaunch.items[0].Task.Task.RunTypeKey != prepare {
		t.Fatalf("steps after OK = %+v", f.beforeLaunch.items)
	}
	h.settle()
	if !h.shows("夹具任务") {
		t.Fatal("the list does not show the added task")
	}

	applyDialog(t, h, p, runConfigDialogRun)
	awaitStateWithin(t, h, 10*time.Second, "the confirmation", func() bool { return p.runConfigs.beforeLaunch != nil })
	if steps := p.runConfigs.beforeLaunch.steps; len(steps) != 1 || steps[0].Task == nil || steps[0].Task.RunTypeKey != prepare {
		t.Fatalf("asked steps = %+v", steps)
	}
	h.settle()
	h.clickNamed(i18n.Shared(language, "desktop.runConfig.beforeLaunch.confirmRun"))
	run := awaitProcessRun(t, h, p, "Fixture Alpha", nil)
	console := run.output.all()
	step, own := strings.Index(console, "run-type ran: task beta"), strings.Index(console, "run-type ran: fast -v alpha one two")
	if step < 0 || own < step {
		t.Fatalf("the task did not run before the configuration; console:\n%s", console)
	}
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "plugin", runTypesPluginID+".toml"))
	if err != nil || !strings.Contains(string(data), "prepare") || !strings.Contains(string(data), "beta") {
		t.Fatalf("plugin run document = %s, %v", data, err)
	}
	if saved := p.runConfigs.configuration(p.runConfigs.list[0].ID); saved == nil || len(saved.BeforeLaunch) != 1 ||
		saved.BeforeLaunch[0].Task == nil || saved.BeforeLaunch[0].Task.RunTypeKey != prepare {
		t.Fatalf("saved configuration = %+v", saved)
	}
}

// The Before Launch section works as IntelliJ IDEA's: "−", the pencil and the arrows wait for
// a selected step; the arrows move it and the selection with it; the pencil on a run step
// opens the list of configurations to run, and the one chosen takes the step's place; "−"
// removes the step and selects the next; with no step left the list says so; the title folds
// the section and opens it again. Every change counts as an edit of the configuration.
func TestRunConfigBeforeLaunchToolbarEditsTheList(t *testing.T) {
	root := t.TempDir()
	writeBeforeLaunchDocument(t, root, "local.yaml",
		beforeLaunchEcho("user:generate", "step-generate"),
		beforeLaunchEcho("user:compile", "step-compile"),
		beforeLaunchEcho("user:lint", "step-lint"),
		beforeLaunchEcho("user:app", "app-ran", "user:generate", "user:compile"),
	)
	h, p := openBeforeLaunchProject(t, root)
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) { a.openRunConfigDialog(p, "user:app") })
	var f *runConfigForm
	awaitStateWithin(t, h, 10*time.Second, "the editor of app", func() bool {
		if draft := d.drafts["user:app"]; draft != nil {
			f = draft.form
		}
		return f != nil && f.ready() && f.beforeLaunch != nil
	})
	h.settle()
	language := h.app.language()
	text := func(id string) string { return i18n.Shared(language, id) }
	runStep := func(name string) string {
		return i18n.SharedFormat(language, "desktop.runConfig.beforeLaunchRunStep", map[string]string{"name": name})
	}
	order := func() []string {
		var ids []string
		for _, entry := range f.beforeLaunch.items {
			ids = append(ids, entry.ConfigurationID)
		}
		return ids
	}
	remove, edit, up, down := text("desktop.runConfig.beforeLaunchRemove"), text("desktop.runConfig.beforeLaunchEdit"),
		text("desktop.runConfig.beforeLaunchUp"), text("desktop.runConfig.beforeLaunchDown")
	if !h.shows(runStep("generate")) || !h.shows(runStep("compile")) {
		t.Fatal("the list does not show the saved steps as runs of their configurations")
	}
	for _, name := range []string{remove, edit, up, down} {
		if !h.pageHit(name).Disabled {
			t.Fatalf("%q acts with no step selected", name)
		}
	}

	h.clickNamed(runStep("compile"))
	h.settle()
	if f.beforeLaunch.selected != 1 || h.pageHit(remove).Disabled || h.pageHit(up).Disabled || !h.pageHit(down).Disabled {
		t.Fatalf("after selecting the last step: selected %d, remove/up/down disabled %v/%v/%v",
			f.beforeLaunch.selected, h.pageHit(remove).Disabled, h.pageHit(up).Disabled, h.pageHit(down).Disabled)
	}
	h.clickNamed(up)
	h.settle()
	if !slices.Equal(order(), []string{"user:compile", "user:generate"}) || f.beforeLaunch.selected != 0 || !d.dirty() {
		t.Fatalf("after moving up: steps %v, selected %d, dirty %v", order(), f.beforeLaunch.selected, d.dirty())
	}

	h.clickNamed(edit)
	h.settle()
	if !f.beforeLaunch.choose || !h.shows(text("desktop.runConfig.beforeLaunchChooseTitle")) {
		t.Fatal("the pencil on a run step does not open the list of configurations to run")
	}
	h.clickNamed("lint")
	h.settle()
	if !slices.Equal(order(), []string{"user:lint", "user:generate"}) || f.beforeLaunch.selected != 0 || f.beforeLaunch.choose {
		t.Fatalf("after choosing lint for the first step: steps %v, selected %d, chooser open %v", order(), f.beforeLaunch.selected, f.beforeLaunch.choose)
	}

	h.clickNamed(remove)
	h.settle()
	if !slices.Equal(order(), []string{"user:generate"}) || f.beforeLaunch.selected != 0 {
		t.Fatalf("after removing the first step: steps %v, selected %d", order(), f.beforeLaunch.selected)
	}
	h.clickNamed(remove)
	h.settle()
	empty := text("desktop.runConfig.beforeLaunchEmpty")
	if len(order()) != 0 || f.beforeLaunch.selected != -1 || !h.shows(empty) {
		t.Fatalf("after removing the last step: steps %v, selected %d, empty note shown %v", order(), f.beforeLaunch.selected, h.shows(empty))
	}

	title := text("desktop.runConfig.fieldBeforeLaunch")
	h.clickNamed(text("native.collapseSection") + " " + title)
	h.settle()
	if !f.beforeLaunch.collapsed || h.shows(empty) {
		t.Fatal("the title does not fold the section")
	}
	h.clickNamed(text("native.expandSection") + " " + title)
	h.settle()
	if f.beforeLaunch.collapsed || !h.shows(empty) {
		t.Fatal("the title does not open the folded section")
	}
}
