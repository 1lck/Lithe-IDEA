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
