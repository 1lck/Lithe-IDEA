package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func runConfigInstance(root string) buildInstance {
	return buildInstance{
		BuildInstance: core.BuildInstance{ID: "engine@" + root, PluginID: "dev.example.engine", BuildSystemID: "engine", Root: root, ModelSource: "provider"},
		PluginID:      "dev.example.engine",
		System:        pluginservice.BuildSystemDeclaration{Runs: []pluginservice.BuildRunDeclaration{{ID: "application", Name: "Run", Tags: []string{"app"}}}},
		Model: core.BuildModel{
			Projects: []core.BuildProject{{ID: "server", Path: "server", Name: "server"}},
			Targets: []core.BuildTarget{
				{ID: "main", ProjectID: "server", Name: "Main", Tags: []string{"app"}},
				{ID: "lib", ProjectID: "server", Name: "Lib", Tags: []string{"library"}},
			},
		},
		modelLoaded: true,
	}
}

// The snapshot lists every target a run applies to, under its workspace-relative
// project, and only for loaded models.
func TestProviderRunsListTheLoadedModelsRuns(t *testing.T) {
	if _, loaded := providerRuns([]buildInstance{{}}); loaded {
		t.Fatal("an unloaded model counts as loaded")
	}
	runs, loaded := providerRuns([]buildInstance{runConfigInstance("app")})
	if !loaded || len(runs) != 1 {
		t.Fatalf("runs = %+v", runs)
	}
	run := runs[0]
	if run.Reference.PluginID != "dev.example.engine" || run.ProjectPath != "app/server" || run.Name != "Run Main" || run.Reference.TargetID != "main" || run.Reference.Run != "application" ||
		run.Reference.Root != "app" || run.Reference.UserArguments == nil {
		t.Fatalf("run = %+v", run)
	}
}

func TestDeclaredBuildTasksDoNotReplaceRunsBeforeTheModelLoads(t *testing.T) {
	taskOnly := buildInstance{modelLoaded: true}
	provider := runConfigInstance("app")
	provider.modelLoaded = false
	runs, loaded := providerRuns([]buildInstance{taskOnly, provider})
	if loaded || len(runs) != 0 {
		t.Fatalf("declared tasks made an unfinished run snapshot ready: %v, %+v", loaded, runs)
	}
}

// captureBuildPlan records the provider run request and refuses it, so no provider starts.
type captureBuildPlan struct {
	Kernel
	requests chan core.BuildPlanRequest
}

func (k *captureBuildPlan) PlanBuildRun(_ context.Context, _ json.RawMessage, _ string, request core.BuildPlanRequest) (core.BuildPlan, error) {
	k.requests <- request
	return core.BuildPlan{}, errors.New("captured")
}

// A detected run becomes the selected configuration; the choices saved for it in
// .lithe/run/local.json reach the provider's run request as launch options.
func TestRunConfigurationRunsWithItsSavedChoices(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h := newHarness(t, gate)
	h.open(root)
	p := h.app.project
	since := p.runConfigs.generation
	h.app.post(func(a *App) {
		setDetected(p, []buildInstance{runConfigInstance("app")})
		a.refreshRunConfigurations(p)
	})
	awaitRunConfigsAfter(t, h, p, since)
	s := &p.runConfigs
	if s.failure != "" || len(s.list) != 1 || s.selected != s.list[0].ID || s.list[0].Name != "Run Main" {
		t.Fatalf("configurations = %+v selected %q failure %q", s.list, s.selected, s.failure)
	}
	id := s.selected
	local := map[string]any{"version": 2, "configurations": []any{map[string]any{"id": id, "args": []string{"--port", "9"}, "env": map[string]string{"MODE": "dev"}}}}
	data, err := json.Marshal(local)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".lithe", "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".lithe", "run", "local.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.post(func(a *App) { a.runConfiguration(p, id) })
	awaitStateWithin(t, h, 10*time.Second, "the provider run request", func() bool { return len(gate.requests) == 1 })
	request := <-gate.requests
	options := request.LaunchOptions
	if request.Run != "application" || request.Target == nil || request.Target.Name != "Main" || options == nil ||
		!slices.Equal(options.Arguments, []string{"--port", "9"}) || options.Environment["MODE"] != "dev" || options.Execution != "application" {
		t.Fatalf("run request = %+v options = %+v", request, options)
	}
}

// A model run entry targeting a declared runConfigurationType becomes a generated
// `build.run-type` snapshot entry and lands in the exact same Run/Debug Configurations
// dialog group as a user-created configuration of that kind.
func TestGeneratedRunTypeSharesDialogGroupWithUserConfiguration(t *testing.T) {
	ref := &core.RunTypeReference{
		PluginID:      "dev.example.tasker",
		BuildSystemID: "tasker",
		Type:          "target",
		Values:        map[string]json.RawMessage{"targets": json.RawMessage(`["build"]`)},
	}
	instance := buildInstance{
		BuildInstance: core.BuildInstance{ID: "tasker@sub", PluginID: "dev.example.tasker", BuildSystemID: "tasker", Root: "sub", ModelSource: "provider"},
		PluginID:      "dev.example.tasker",
		Model: core.BuildModel{
			Projects: []core.BuildProject{{ID: "sub", Path: "sub", Name: "sub"}},
			Run: []core.BuildRunEntry{{
				ID:               "tasker.target:sub:build",
				Name:             "build",
				Provider:         core.RunTypeProvider,
				Execution:        "task",
				WorkingDirectory: "sub",
				BuildSystem:      core.BuildRunEntryBinding{ProjectID: "sub", TargetID: "sub:build"},
				RunType:          ref,
			}},
		},
		modelLoaded: true,
	}
	runs, loaded := providerRuns([]buildInstance{instance})
	if !loaded || len(runs) != 1 || runs[0].Reference != nil || runs[0].RunType == nil ||
		runs[0].ProjectPath != "sub" || runs[0].CWD != "sub" || runs[0].Selector != "tasker.target:sub:build" {
		t.Fatalf("runs = %+v loaded = %v", runs, loaded)
	}

	key := core.RunTypeKey{PluginID: "dev.example.tasker", BuildSystemID: "tasker", Type: "target"}
	ext, err := json.Marshal(ref)
	if err != nil {
		t.Fatal(err)
	}
	app := &App{}
	p := &project{}
	p.runConfigs.types = []core.RunConfigurationType{{
		Provider:    core.RunTypeProvider,
		RunType:     &key,
		DisplayName: "Tasker Target",
		Execution:   "task",
	}}
	p.runConfigs.list = []core.RunConfiguration{
		{
			ID:         "generated:run-type:0123456789abcdef",
			Name:       "build",
			Provider:   core.RunTypeProvider,
			Execution:  "task",
			Cwd:        "sub",
			Extensions: map[string]json.RawMessage{"build": ext},
		},
		{
			ID:         "user:custom-build",
			Name:       "Custom Build",
			Provider:   core.RunTypeProvider,
			Execution:  "task",
			Cwd:        "sub",
			Extensions: map[string]json.RawMessage{"build": ext},
		},
	}
	p.collectRunConfigDialogRows(app)
	if len(p.runConfigs.dialog.groups) != 1 {
		t.Fatalf("dialog groups = %+v, want 1 unified group", p.runConfigs.dialog.groups)
	}
	group := p.runConfigs.dialog.groups[0]
	if group.title != "Tasker Target" || len(group.keys) != 2 {
		t.Fatalf("group = %+v, want title Tasker Target with 2 entries", group)
	}
}
