package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// readBuildFixture returns a shared build-provider manifest.
func readBuildFixture(t *testing.T, name string) json.RawMessage {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(contractfixture.Path("fixtures/build-providers"), name))
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestBuildDetectFindsProviderInstance(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "build.gradle.kts"), []byte("plugins {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := readBuildFixture(t, "build-provider-execution.plugin.json")
	detection, err := client.DetectBuildSystems(ctx, root, []json.RawMessage{manifest})
	if err != nil {
		t.Fatal(err)
	}
	if len(detection.Instances) != 1 {
		t.Fatalf("instances = %+v", detection.Instances)
	}
	instance := detection.Instances[0]
	if instance.BuildSystemID != "gradle" || instance.PluginID != "dev.lithe.fixture.build-provider-execution" ||
		instance.Root != "." || instance.ModelSource != "provider" {
		t.Fatalf("instance = %+v", instance)
	}
}

func TestBuildTaskPlanCarriesProviderParams(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	root := t.TempDir()
	manifest := readBuildFixture(t, "build-provider-execution.plugin.json")
	plan, err := client.PlanBuildTask(ctx, manifest, "gradle", BuildPlanRequest{
		Root:          ".",
		WorkspaceRoot: root,
		Task:          "build",
		UserArguments: []string{"--warning-mode", "all"},
		Options:       map[string]json.RawMessage{"offline": json.RawMessage("true")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Provider == nil || plan.Provider.Method != "lithe/build/execute" || len(plan.Arguments) != 0 {
		t.Fatalf("plan = %+v", plan)
	}
	var params struct {
		BuildSystemID string          `json:"buildSystemID"`
		Root          string          `json:"root"`
		Task          string          `json:"task"`
		UserArguments []string        `json:"userArguments"`
		Options       map[string]bool `json:"options"`
	}
	if err := json.Unmarshal(plan.Provider.Params, &params); err != nil {
		t.Fatal(err)
	}
	if params.BuildSystemID != "gradle" || params.Root != "." || params.Task != "build" ||
		len(params.UserArguments) != 2 || !params.Options["offline"] {
		t.Fatalf("params = %+v", params)
	}
}

func TestBuildDecodeModelKeepsTargetsAndModelTasks(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app"), 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := readBuildFixture(t, "build-provider.plugin.json")
	result := json.RawMessage(`{
		"format": "litheBuildModel",
		"version": 0,
		"projects": [{"path": ".", "name": "shop"}],
		"targets": [{"project": ".", "name": "app", "path": "app", "tags": ["application"]}],
		"tasks": [{"project": ".", "name": "bootRun", "template": "gradle-task", "execution": "service"}]
	}`)
	model, err := client.DecodeBuildModel(ctx, manifest, "gradle", BuildDecodeModelRequest{
		WorkspaceRoot: root,
		Root:          ".",
		Result:        result,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(model.Projects) != 1 || model.Projects[0].Name != "shop" {
		t.Fatalf("projects = %+v", model.Projects)
	}
	if len(model.Targets) != 1 || len(model.Targets[0].Tags) != 1 || model.Targets[0].Tags[0] != "application" {
		t.Fatalf("targets = %+v", model.Targets)
	}
	if len(model.Tasks) != 1 || model.Tasks[0].Template != "gradle-task" || model.Tasks[0].Execution != "service" {
		t.Fatalf("tasks = %+v", model.Tasks)
	}
}

// TestBuildDecodeModelDerivesCommandRunEntries decodes a `go list -json` stream with the
// shared Go fixture: its command run declaration becomes one Run entry per main package,
// bound to the package's target, with `go run <import path>` expanded and the module as the
// working directory. The Build window runs these entries; a library package has none.
func TestBuildDecodeModelDerivesCommandRunEntries(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{"cmd/hello", "lib"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/build-systems/build-command-stdout.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	module := map[string]string{"Path": "example.com/m", "Dir": root, "GoVersion": "1.21"}
	var output []byte
	for _, pkg := range []map[string]any{
		{"Dir": filepath.Join(root, "cmd", "hello"), "ImportPath": "example.com/m/cmd/hello", "Name": "main", "Module": module},
		{"Dir": filepath.Join(root, "lib"), "ImportPath": "example.com/m/lib", "Name": "lib", "Module": module},
	} {
		line, err := json.Marshal(pkg)
		if err != nil {
			t.Fatal(err)
		}
		output = append(append(output, line...), '\n')
	}
	model, err := client.DecodeBuildModel(ctx, manifest, "go", BuildDecodeModelRequest{
		WorkspaceRoot: root,
		Root:          ".",
		Output:        string(output),
	})
	if err != nil {
		t.Fatal(err)
	}
	var application *BuildTarget
	for index := range model.Targets {
		if model.Targets[index].Name == "example.com/m/cmd/hello" {
			application = &model.Targets[index]
		}
	}
	if application == nil {
		t.Fatalf("targets = %+v", model.Targets)
	}
	if len(model.Run) != 1 {
		t.Fatalf("run entries = %+v, want one for the main package", model.Run)
	}
	entry := model.Run[0]
	if entry.Name != "hello" || entry.ID == "" || entry.Execution != "application" {
		t.Fatalf("entry = %+v", entry)
	}
	if len(entry.Arguments) != 2 || entry.Arguments[0] != "run" || entry.Arguments[1] != "example.com/m/cmd/hello" {
		t.Fatalf("arguments = %q, want go run of the import path", entry.Arguments)
	}
	if entry.WorkingDirectory != "." {
		t.Fatalf("working directory = %q, want the module", entry.WorkingDirectory)
	}
	if entry.BuildSystem.TargetID != application.ID || entry.BuildSystem.ProjectID != application.ProjectID || entry.BuildSystem.TaskID != "" {
		t.Fatalf("binding = %+v, want target %s of project %s", entry.BuildSystem, application.ID, application.ProjectID)
	}
}

func TestBuildDecodeRunKeepsValidatedExecutable(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "app"), 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := readBuildFixture(t, "build-provider-run-preparation.plugin.json")
	raw, err := os.ReadFile(contractfixture.Path("fixtures/build-providers/build-run-preparation.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Result json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	launch, err := client.DecodeBuildRun(ctx, manifest, "gradle", BuildDecodeRunRequest{
		WorkspaceRoot: root,
		Root:          ".",
		Result:        fixture.Result,
	})
	if err != nil {
		t.Fatal(err)
	}
	if launch.Executable.Kind != "toolchain" || launch.Executable.Value != "project-jdk" {
		t.Fatalf("executable = %+v", launch.Executable)
	}
	if launch.WorkingDirectory != "app" || len(launch.Arguments) != 4 || launch.Environment["APP_ENV"] != "test" {
		t.Fatalf("launch = %+v", launch)
	}
}

func TestBuildProviderRequestNeedsAnOpenSession(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	_, err := client.RequestPluginBuild(ctx, PluginBuildProviderRequest{
		SessionID: "missing",
		Method:    "lithe/build/model",
		Params:    json.RawMessage(`{}`),
	})
	if err == nil {
		t.Fatal("a build request to a missing session succeeded")
	}
}
