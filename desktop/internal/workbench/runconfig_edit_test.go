package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// loadedRunConfigs opens root with one provider run and waits until Core resolved it.
func loadedRunConfigs(t *testing.T, kernel Kernel, root string) (*harness, *project) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "app", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, kernel)
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) {
		p.build.instances = []buildInstance{runConfigInstance("app")}
		a.refreshRunConfigurations(p)
	})
	awaitStateWithin(t, h, 10*time.Second, "the run configurations", func() bool { return p.runConfigs.generation > 0 && !p.runConfigs.loading })
	if s := &p.runConfigs; s.failure != "" || len(s.list) != 1 {
		t.Fatalf("configurations = %+v failure %q", s.list, s.failure)
	}
	return h, p
}

// The editor opens in the Run/Debug Configurations dialog on the resolved values, OK writes the
// local layer through Core and the configurations resolve again with the edit.
func TestRunConfigEditorSavesTheLocalLayer(t *testing.T) {
	root := t.TempDir()
	h, p := loadedRunConfigs(t, &testKernel{Client: core.NewClient()}, root)
	id := p.runConfigs.selected
	d := &p.runConfigs.dialog
	// open opens the dialog on configuration id and waits for its editor.
	open := func() *runConfigEditor {
		t.Helper()
		h.app.post(func(a *App) { a.editRunConfiguration(p, id) })
		var e *runConfigEditor
		awaitStateWithin(t, h, 10*time.Second, "the editor's argument text", func() bool {
			if draft := d.drafts[id]; d.open && draft != nil {
				e = draft.editor
			}
			return e != nil && !e.loading
		})
		return e
	}
	e := open()
	language := h.app.language()
	if !h.shows(i18n.Shared(language, "desktop.runConfig.dialogTitle")) || !h.shows("Run Main") {
		t.Fatal("the dialog with the configuration's editor is not shown")
	}
	h.app.post(func(*App) {
		e.arguments = `--name "Alice Smith"`
		e.directory = "app/server"
		e.environment = "MODE=prod\n\nTRACE=1"
	})
	h.settle()
	if !d.dirty() {
		t.Fatal("the edit does not show as something to save")
	}
	ok := h.hitLabeled(i18n.Shared(language, "desktop.runConfig.ok"))
	h.click(gfx.Point{X: ok.X + ok.Width/2, Y: ok.Y + ok.Height/2})
	awaitStateWithin(t, h, 10*time.Second, "the saved configuration", func() bool {
		return !d.open && !p.runConfigs.loading && len(p.runConfigs.list) == 1 && len(p.runConfigs.list[0].Args) == 2
	})
	got := p.runConfigs.list[0]
	if !slices.Equal(got.Args, []string{"--name", "Alice Smith"}) || got.Cwd != "app/server" || got.Env["MODE"] != "prod" || got.Env["TRACE"] != "1" {
		t.Fatalf("configuration = %+v", got)
	}
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "plugin", "dev.example.engine.local.toml"))
	if err != nil || !strings.Contains(string(data), "Alice Smith") {
		t.Fatalf("dev.example.engine.local.toml = %s, %v", data, err)
	}
	for _, layer := range []string{"dev.example.engine.toml", "../configurations.yaml", "../local.yaml"} {
		if _, err := os.Stat(filepath.Join(root, ".lithe", "run", "plugin", layer)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s was written: %v", layer, err)
		}
	}

	// Reopening shows the saved values as editor text, with nothing to save.
	e = open()
	if e.arguments != `--name "Alice Smith"` || e.environment != "MODE=prod\nTRACE=1" || e.directory != "app/server" || d.dirty() {
		t.Fatalf("editor = %+v, dirty %v", *e, d.dirty())
	}

	// A changed step list counts as a change; one emptied again is the list the editor read.
	h.app.post(func(*App) { e.beforeLaunch = []string{"user:prepare"} })
	h.settle()
	if !d.dirty() {
		t.Fatal("a changed step list does not show as something to save")
	}
	h.app.post(func(*App) { e.beforeLaunch = []string{} })
	h.settle()
	if d.dirty() {
		t.Fatal("an emptied step list shows as something to save")
	}

	// A line without a name keeps the dialog open with the line number, and writes nothing.
	h.app.post(func(a *App) {
		e.environment = "MODE=prod\n=oops"
		a.applyRunConfigDialog(p, runConfigDialogOK)
	})
	h.settle()
	want := i18n.SharedFormat(language, "desktop.runConfig.environmentInvalid", map[string]string{"line": "2"})
	if !d.open || d.saving || e.saving || e.failure != want || d.selected != id {
		t.Fatalf("dialog open %v saving %v, editor = %+v, want failure %q", d.open, d.saving, *e, want)
	}
}

// conflictingKernel writes a layer file after Core read the layers and before the host
// applies the changes Core computed from what it read.
type conflictingKernel struct {
	Kernel
	path string
}

const conflictingContent = "# written by another program\n"

func (k *conflictingKernel) UpdateRunConfigurationOptions(ctx context.Context, edit core.RunOptionsEdit) ([]core.RunConfigChange, error) {
	changes, err := k.Kernel.UpdateRunConfigurationOptions(ctx, edit)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(k.path), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(k.path, []byte(conflictingContent), 0o600); err != nil {
		return nil, err
	}
	return changes, nil
}

// A layer file another writer created or changed after Core read the layers is not
// replaced: the save fails with a conflict and the other writer's file stays as written.
func TestRunConfigSaveRefusesAConcurrentlyChangedLayer(t *testing.T) {
	root := t.TempDir()
	h, p := loadedRunConfigs(t, &testKernel{Client: core.NewClient()}, root)
	path := filepath.Join(root, ".lithe", "run", "plugin", "dev.example.engine.toml")
	h.app.kernel = &conflictingKernel{Kernel: h.app.kernel, path: path}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	err := h.app.saveRunConfigOptions(ctx, core.RunOptionsEdit{Root: root, Scope: "project", ConfigurationID: p.runConfigs.selected,
		Arguments: "--port 9", Environment: map[string]string{}})
	if !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("save = %v, want a conflict", err)
	}
	if data, _ := os.ReadFile(path); string(data) != conflictingContent {
		t.Fatalf("the other writer's file was replaced: %s", data)
	}
}

func TestEnvironmentTextRoundTrips(t *testing.T) {
	text := environmentText(map[string]string{"B": "2", "A": "x=y"})
	if text != "A=x=y\nB=2" {
		t.Fatalf("text = %q", text)
	}
	environment, line := parseEnvironment(text + "\r\n\n")
	if line != 0 || len(environment) != 2 || environment["A"] != "x=y" {
		t.Fatalf("environment = %v line %d", environment, line)
	}
	if _, line := parseEnvironment("A=1\nnoequals"); line != 2 {
		t.Fatalf("line = %d, want 2", line)
	}
}
