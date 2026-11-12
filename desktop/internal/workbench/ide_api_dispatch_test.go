package workbench

import (
	"slices"
	"strings"
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
	// Build configure is dispatched since the Build window applies configuration changes.
	if !slices.Contains(ideAPIServedTools, "lithe_run_start") || !slices.Contains(ideAPIServedTools, "lithe_build_configure") {
		t.Fatal("a tool the client dispatches is not advertised")
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

// TestIDEBuildExecuteRefusesWithTheContractCodes checks that every start the window refuses
// before it reserves an execution answers with the IDE API code the contract gives the cause.
func TestIDEBuildExecuteRefusesWithTheContractCodes(t *testing.T) {
	app := &App{}
	p := &project{}
	p.build.instances = []buildInstance{{
		BuildInstance: core.BuildInstance{ID: "cargo", BuildSystemID: "cargo"},
		System: pluginservice.BuildSystemDeclaration{Tasks: []pluginservice.BuildTaskDeclaration{
			{ID: "build", DisplayName: "Build"},
			{ID: "test", DisplayName: "Test", RequiresUserArguments: true},
		}},
	}}
	for _, refusal := range []struct {
		name string
		args ideAPIBuildExecuteArguments
		busy bool
		code string
	}{
		{"an unknown instance", ideAPIBuildExecuteArguments{InstanceID: "missing", TaskID: "build"}, false, "NOT_FOUND"},
		{"a busy window", ideAPIBuildExecuteArguments{InstanceID: "cargo", TaskID: "build"}, true, "BUSY"},
		{"a model task before the model loaded", ideAPIBuildExecuteArguments{InstanceID: "cargo", ModelTaskID: "compile"}, false, "NOT_READY"},
		{"an unknown task", ideAPIBuildExecuteArguments{InstanceID: "cargo", TaskID: "deploy"}, false, "NOT_FOUND"},
		{"a task without its user arguments", ideAPIBuildExecuteArguments{InstanceID: "cargo", TaskID: "test"}, false, "INVALID_ARGUMENTS"},
	} {
		p.build.operation = nil
		if refusal.busy {
			p.build.operation = &buildOperation{}
		}
		operation, failure := app.ideAPIBuildExecute(p, refusal.args)
		if operation != nil || ideAPIFailureCode(failure) != refusal.code {
			t.Fatalf("%s: operation %v, failure %#v, want %s", refusal.name, operation, failure, refusal.code)
		}
	}
	if p.ideAPI.current != nil {
		t.Fatalf("a refused start recorded the execution %+v", p.ideAPI.current)
	}
}

// TestIDEOperationIDsAreCurrentExpiredOrUnknown checks the identity rule of the contract: only
// the latest execution is retained, an ID this client issued before is expired, in this project
// or in the project before it was reopened, and an ID it never issued is unknown.
func TestIDEOperationIDsAreCurrentExpiredOrUnknown(t *testing.T) {
	p, reopened := &project{}, &project{}
	first := p.recordIDEOperation("build", "Cargo: build", "")
	before := reopened.recordIDEOperation("run", "Main", "main")
	latest := p.recordIDEOperation("run", "Main", "main")
	if first.ID == latest.ID || before.ID == latest.ID || !strings.HasPrefix(latest.ID, "ide-run-") {
		t.Fatalf("IDs %q, %q and %q", first.ID, before.ID, latest.ID)
	}
	if found, failure := p.ideAPIOperationByID(latest.ID); found != latest || failure != nil {
		t.Fatalf("the latest execution: %v, %#v", found, failure)
	}
	for _, id := range []string{first.ID, before.ID} {
		if _, failure := p.ideAPIOperationByID(id); ideAPIFailureCode(failure) != "OPERATION_EXPIRED" {
			t.Fatalf("%s answered %#v, want OPERATION_EXPIRED", id, failure)
		}
	}
	epoch := p.ideAPI.epoch
	for _, id := range []string{
		"ide-run-" + epoch + "-3",  // not issued yet
		"ide-run-" + epoch + "-02", // not the canonical number
		"ide-test-" + epoch + "-1", // not a kind this client issues
		"ide-run-" + strings.ToUpper(epoch) + "x-1",
		"operation-1",
		"",
	} {
		if _, failure := p.ideAPIOperationByID(id); ideAPIFailureCode(failure) != "NOT_FOUND" {
			t.Fatalf("%q answered %#v, want NOT_FOUND", id, failure)
		}
	}
}

// TestIDEOperationLifecycleSettlesOnce checks the states an execution passes through: it leaves
// preparation once, whether it launched, was stopped or failed first, and keeps its first ending.
func TestIDEOperationLifecycleSettlesOnce(t *testing.T) {
	p := &project{}
	launched := func(o *ideAPIOperation) bool {
		select {
		case <-o.launched:
			return true
		default:
			return false
		}
	}
	run := p.recordIDEOperation("run", "Main", "main")
	if run.State != "preparing" || launched(run) || run.terminal() {
		t.Fatalf("a new execution is %+v", run)
	}
	run.start()
	run.start()
	if run.State != "running" || !launched(run) {
		t.Fatalf("a started execution is %+v", run)
	}
	exit := 3
	run.settle("failed", &exit, 7, "never reported for a launched execution")
	run.settle("completed", nil, 9, "")
	run.stopping()
	if run.State != "failed" || run.ExitCode == nil || *run.ExitCode != 3 || run.endSequence != 7 {
		t.Fatalf("a settled execution changed to %+v", run)
	}

	stopped := p.recordIDEOperation("build", "Cargo: build", "")
	stopped.stopping()
	if stopped.State != "stopping" || !launched(stopped) {
		t.Fatalf("an execution stopped while preparing is %+v", stopped)
	}
	stopped.settle("cancelled", nil, 0, "ignored")
	if stopped.State != "cancelled" || stopped.ExitCode != nil || stopped.failure != "" {
		t.Fatalf("a cancelled execution is %+v", stopped)
	}

	failed := p.recordIDEOperation("build", "Cargo: build", "")
	failed.settle("failed", nil, 0, "the plan was refused")
	if failed.State != "failed" || failed.failure != "the plan was refused" || !launched(failed) {
		t.Fatalf("an execution that failed while preparing is %+v", failed)
	}
}

// ideAPIFailureCode returns the code of a failure answer, "" for anything else.
func ideAPIFailureCode(result any) string {
	failure, ok := result.(map[string]any)
	if !ok {
		return ""
	}
	described, ok := failure["error"].(map[string]string)
	if !ok {
		return ""
	}
	return described["code"]
}
