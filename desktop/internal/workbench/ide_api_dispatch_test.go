package workbench

import (
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestIDEAPIToolExposureIsTheServedList(t *testing.T) {
	exposure := ideAPIToolExposure()
	if len(exposure) != len(ideAPIServedTools) || len(exposure) == 0 {
		t.Fatalf("exposure = %v, served = %v", exposure, ideAPIServedTools)
	}
	for i, tool := range exposure {
		if tool.Name != ideAPIServedTools[i] || len(tool.Arguments) != 0 {
			t.Fatalf("exposure[%d] = %+v", i, tool)
		}
	}
	if !slices.Contains(ideAPIServedTools, "lithe_run_start") || slices.Contains(ideAPIServedTools, "lithe_build_configure") {
		t.Fatal("a tool the client does not dispatch is advertised")
	}
}

func TestIDEBuildInspectListsInstancesAndTheirIdentities(t *testing.T) {
	p := &project{}
	p.build.instances = []buildInstance{
		{
			BuildInstance: core.BuildInstance{ID: "gradle", DisplayName: "Gradle", BuildSystemID: "gradle", Root: "."},
			PluginID:      "dev.lithe.java",
			System: pluginservice.BuildSystemDeclaration{Tasks: []pluginservice.BuildTaskDeclaration{
				{ID: "build", DisplayName: "Build"},
				{ID: "test", DisplayName: "Test", RequiresUserArguments: true},
			}},
			Model: core.BuildModel{
				Projects: []core.BuildProject{{ID: "app", Name: "app", Path: ":app"}},
				Targets:  []core.BuildTarget{{ID: "run", ProjectID: "app", Name: "run"}},
				Tasks:    []core.BuildTask{{ID: "compile", Name: "compile", Execution: "provider"}},
			},
			modelLoaded: true,
		},
		{
			BuildInstance: core.BuildInstance{ID: "maven", DisplayName: "Maven", BuildSystemID: "maven", Root: "."},
			modelError:    "model could not be loaded",
		},
	}
	p.build.selected = 0
	p.build.projectID, p.build.targetID = "app", "run"

	inspect := ideAPIBuildInspect(p).(map[string]any)
	instances := inspect["instances"].([]map[string]any)
	if len(instances) != 2 || instances[0]["instanceID"] != "gradle" || !instances[0]["selected"].(bool) {
		t.Fatalf("instances = %#v", instances)
	}
	declared := instances[0]["declaredTasks"].([]map[string]any)
	if len(declared) != 2 || declared[1]["requiresUserArguments"] != true {
		t.Fatalf("declared tasks = %#v", declared)
	}
	targets := instances[0]["targets"].([]map[string]any)
	if len(targets) != 1 || targets[0]["targetID"] != "run" {
		t.Fatalf("targets = %#v", targets)
	}
	// A model that failed to load carries no identities and keeps the reason.
	if instances[1]["modelLoaded"].(bool) || len(instances[1]["targets"].([]map[string]any)) != 0 {
		t.Fatalf("failed instance = %#v", instances[1])
	}
	selected := inspect["selected"].(map[string]any)
	if selected["instanceID"] != "gradle" || selected["projectID"] != "app" || selected["targetID"] != "run" {
		t.Fatalf("selected = %#v", selected)
	}
}

func TestIDEBuildExecuteRefusesUnknownInstanceAndBusyWindow(t *testing.T) {
	app := &App{}
	p := &project{}
	result := app.ideAPIBuildExecute(p, ideAPIBuildExecuteArguments{InstanceID: "missing", TaskID: "build"})
	if failure, ok := result.(map[string]any); !ok || failure["error"] == nil {
		t.Fatalf("unknown instance = %#v", result)
	}
	p.build.instances = []buildInstance{{BuildInstance: core.BuildInstance{ID: "gradle"}}}
	p.build.operation = &buildOperation{label: "ui"}
	result = app.ideAPIBuildExecute(p, ideAPIBuildExecuteArguments{InstanceID: "gradle", TaskID: "build"})
	if failure, ok := result.(map[string]any); !ok || failure["error"] == nil {
		t.Fatalf("busy window = %#v", result)
	}
}

func TestIDEOperationOutputHonorsCursorAndReportsReset(t *testing.T) {
	p := &project{}
	p.build.output = []string{"a\n", "b\n", "c\n"}
	p.build.outputStart, p.build.outputSequence = 10, 13
	p.ideAPI.operations = []*ideAPIOperation{{ID: "op", State: "running", startSequence: 10}}

	first := ideAPIOperationOutput(p, "op", "").(map[string]any)
	if first["text"] != "a\nb\nc\n" || first["cursor"] != "12" || first["reset"] != false || first["state"] != "running" {
		t.Fatalf("first read = %#v", first)
	}
	incremental := ideAPIOperationOutput(p, "op", "11").(map[string]any)
	if incremental["text"] != "c\n" || incremental["cursor"] != "12" {
		t.Fatalf("incremental read = %#v", incremental)
	}
	// A trimmed console cannot replay the lost lines; the read reports a reset instead.
	p.build.output, p.build.outputStart = []string{"c\n"}, 12
	trimmed := ideAPIOperationOutput(p, "op", "10").(map[string]any)
	if trimmed["text"] != "c\n" || trimmed["reset"] != true || trimmed["cursor"] != "12" {
		t.Fatalf("trimmed read = %#v", trimmed)
	}
	if failure, ok := ideAPIOperationOutput(p, "missing", "").(map[string]any); !ok || failure["error"] == nil {
		t.Fatalf("unknown operation = %#v", failure)
	}
}

func TestIDEOperationsSettleOnlyRunningExecutions(t *testing.T) {
	p := &project{}
	exit := 3
	p.ideAPI.operations = []*ideAPIOperation{
		{ID: "running", State: "running"},
		{ID: "cancelled", State: "cancelled"},
		{ID: "finished", State: "succeeded"},
	}
	p.settleIDEOperations("failed", &exit)
	operations := p.ideAPI.operations
	if operations[0].State != "failed" || operations[0].ExitCode == nil || *operations[0].ExitCode != exit {
		t.Fatalf("running execution = %+v", operations[0])
	}
	if operations[1].State != "cancelled" || operations[2].State != "succeeded" {
		t.Fatalf("settled finished executions: %+v %+v", operations[1], operations[2])
	}
}
