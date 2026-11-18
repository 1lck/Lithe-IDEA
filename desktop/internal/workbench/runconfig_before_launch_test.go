package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
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

// The editor shows the chosen steps by name, offers the other process runs and sends the
// edited list; a save that did not change the list sends none.
func TestRunConfigFormKeepsTheStepList(t *testing.T) {
	f := &runConfigForm{values: map[string]json.RawMessage{}, texts: map[string]*string{}, flags: map[string]*bool{}}
	f.fields = []core.RunEditorField{{ID: "beforeLaunch", Kind: runFieldBeforeLaunch}}
	f.readValues(f.fields, map[string]json.RawMessage{"beforeLaunch": json.RawMessage(`["user:a","user:b"]`)})
	if !f.drawable(i18n.English, f.fields[0]) {
		t.Fatal("the step field is not drawn")
	}
	moveRunConfigStep(f.beforeLaunch, 1, 0)
	moveRunConfigStep(f.beforeLaunch, 1, 2)
	if got := string(f.collect()["beforeLaunch"]); got != `["user:b","user:a"]` {
		t.Fatalf("collected %s", got)
	}

	empty := &runConfigForm{values: map[string]json.RawMessage{}, texts: map[string]*string{}, flags: map[string]*bool{}}
	empty.fields = f.fields
	empty.readValues(empty.fields, map[string]json.RawMessage{})
	if got := string(empty.collect()["beforeLaunch"]); got != `[]` {
		t.Fatalf("an empty list collected %s", got)
	}

	s := runConfigState{list: []core.RunConfiguration{
		{ID: "user:a", Name: "a", Provider: runProviderShell},
		{ID: "user:self", Name: "self", Provider: runProviderShell},
		{ID: "run:maven", Name: "maven", Provider: "build.example"},
	}}
	candidates := s.beforeLaunchCandidates("user:self")
	if len(candidates) != 1 || candidates[0].ID != "user:a" {
		t.Fatalf("candidates = %+v", candidates)
	}
}
