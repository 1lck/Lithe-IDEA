package workbench

import (
	"context"
	"encoding/json"
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

// loadedRunConfigs opens root with one detected run and waits until Core resolved it.
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

// The editor opens on the resolved values, saving writes the local layer through Core
// and the configurations resolve again with the edit.
func TestRunConfigEditorSavesTheLocalLayer(t *testing.T) {
	root := t.TempDir()
	h, p := loadedRunConfigs(t, &testKernel{Client: core.NewClient()}, root)
	id := p.runConfigs.selected
	e := &p.runConfigs.editor
	h.app.post(func(a *App) { a.openRunConfigEditor(p, id) })
	awaitStateWithin(t, h, 10*time.Second, "the editor's argument text", func() bool { return e.open && !e.loading })
	language := h.app.language()
	if title := i18n.SharedFormat(language, "desktop.runConfig.editTitle", map[string]string{"name": "Run Main"}); !h.shows(title) {
		t.Fatalf("the editor titled %q is not shown", title)
	}
	h.app.post(func(*App) {
		e.arguments = `--name "Alice Smith"`
		e.directory = "app/server"
		e.environment = "MODE=prod\n\nTRACE=1"
	})
	h.settle()
	save := h.hitLabeled(i18n.Shared(language, "ui.save"))
	h.click(gfx.Point{X: save.X + save.Width/2, Y: save.Y + save.Height/2})
	awaitStateWithin(t, h, 10*time.Second, "the saved configuration", func() bool {
		return !e.open && !p.runConfigs.loading && len(p.runConfigs.list) == 1 && len(p.runConfigs.list[0].Args) == 2
	})
	got := p.runConfigs.list[0]
	if !slices.Equal(got.Args, []string{"--name", "Alice Smith"}) || got.Cwd != "app/server" || got.Env["MODE"] != "prod" || got.Env["TRACE"] != "1" {
		t.Fatalf("configuration = %+v", got)
	}
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "local.json"))
	if err != nil || !json.Valid(data) || !strings.Contains(string(data), "Alice Smith") {
		t.Fatalf("local.json = %s, %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe", "run", "configurations.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the project layer was written: %v", err)
	}

	// Reopening shows the saved values as editor text.
	h.app.post(func(a *App) { a.openRunConfigEditor(p, id) })
	awaitStateWithin(t, h, 10*time.Second, "the reopened editor", func() bool { return e.open && !e.loading })
	if e.arguments != `--name "Alice Smith"` || e.environment != "MODE=prod\nTRACE=1" || e.directory != "app/server" {
		t.Fatalf("editor = %+v", *e)
	}

	// A line without a name keeps the editor open with the line number, and writes nothing.
	h.app.post(func(a *App) {
		e.environment = "MODE=prod\n=oops"
		a.saveRunConfigEditor(p)
	})
	h.settle()
	want := i18n.SharedFormat(language, "desktop.runConfig.environmentInvalid", map[string]string{"line": "2"})
	if !e.open || e.saving || e.failure != want {
		t.Fatalf("editor = %+v, want failure %q", *e, want)
	}
}

// conflictingKernel rewrites the target layer while Core is editing it.
type conflictingKernel struct {
	Kernel
	path string
}

func (k *conflictingKernel) UpdateRunConfigurationOptions(ctx context.Context, edit core.RunOptionsEdit) (string, error) {
	if err := os.WriteFile(k.path, []byte(`{"version":2,"configurations":[]}`), 0o600); err != nil {
		return "", err
	}
	return k.Kernel.UpdateRunConfigurationOptions(ctx, edit)
}

// A layer file another writer changed after it was captured is not replaced.
func TestRunConfigSaveRefusesAConcurrentlyChangedLayer(t *testing.T) {
	root := t.TempDir()
	h, p := loadedRunConfigs(t, &testKernel{Client: core.NewClient()}, root)
	path := filepath.Join(root, ".lithe", "run", "configurations.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"version":2,"configurations":[] }`), 0o600); err != nil {
		t.Fatal(err)
	}
	kernel := &conflictingKernel{Kernel: h.app.kernel, path: path}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	err := saveRunConfigOptions(ctx, kernel, core.RunOptionsEdit{Root: root, Scope: "project", ConfigurationID: p.runConfigs.selected,
		Arguments: "--port 9", Environment: map[string]string{}})
	if !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("save = %v, want a conflict", err)
	}
	if data, _ := os.ReadFile(path); string(data) != `{"version":2,"configurations":[]}` {
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
