package workbench

import (
	"context"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestBuildPanelWithoutBuildPluginsSaysSo(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	h.open(t.TempDir())
	h.app.reduceChrome(core.ToggleChrome(itemBuild))
	h.settle()
	h.settle()
	if !h.shows("没有检测到由提供者驱动的构建系统。") {
		t.Fatal("the Build panel did not explain that no provider-backed build system was detected")
	}
}

func TestBuildOutputKeepsWholeLinesWithinTheBudget(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	op := h.app.beginBuildOperation(p, "build", "build", "")
	for i := 0; i < buildOutputMaxLines+50; i++ {
		h.app.appendBuildOutput(p, op, "line "+strings.Repeat("x", 8)+"\n")
	}
	if len(p.build.output) > buildOutputMaxLines {
		t.Fatalf("output has %d lines, want at most %d", len(p.build.output), buildOutputMaxLines)
	}
	if p.build.outputBytes > buildOutputBytes {
		t.Fatalf("output has %d bytes, want at most %d", p.build.outputBytes, buildOutputBytes)
	}
	if !strings.HasSuffix(p.build.output[len(p.build.output)-1], "\n") {
		t.Fatal("the last output line lost its terminator")
	}
	visible := buildVisibleOutput(p.build.output)
	if len(visible) == 0 || len(visible) > buildOutputVisible {
		t.Fatalf("visible lines = %d", len(visible))
	}
}

func TestBuildRunAppliesToTargetTags(t *testing.T) {
	run := pluginservice.BuildRunDeclaration{Tags: []string{"application"}}
	if !buildRunApplies(run, core.BuildTarget{Tags: []string{"library", "application"}}) {
		t.Fatal("a matching tag was refused")
	}
	if buildRunApplies(run, core.BuildTarget{Tags: []string{"test"}}) {
		t.Fatal("a non-matching target was accepted")
	}
	if !buildRunApplies(pluginservice.BuildRunDeclaration{}, core.BuildTarget{Tags: []string{"test"}}) {
		t.Fatal("a run without tags did not accept every target")
	}
}

func TestBuildTaskLookupUsesDeclaredAndModelTasks(t *testing.T) {
	instance := &buildInstance{
		BuildInstance: core.BuildInstance{ID: "fixture:."},
		System: pluginservice.BuildSystemDeclaration{Tasks: []pluginservice.BuildTaskDeclaration{
			{ID: "build", Source: "provider", DisplayName: "Build"},
			{ID: "command", Source: "command"},
			{ID: "template", Source: "provider", FromModel: true},
		}},
		Model: core.BuildModel{Tasks: []core.BuildTask{{ID: "model-task", Template: "template"}}},
	}
	task, modelTask := buildTaskByID(instance, "build")
	if task == nil || modelTask != nil {
		t.Fatalf("declared task = %+v, model task = %+v", task, modelTask)
	}
	task, modelTask = buildTaskByID(instance, "model-task")
	if task != nil || modelTask == nil || modelTask.Template != "template" {
		t.Fatalf("declared task = %+v, model task = %+v", task, modelTask)
	}
	if task, modelTask = buildTaskByID(instance, "command"); task == nil || modelTask != nil || task.ID != "command" {
		t.Fatalf("command task = %+v, model task = %+v", task, modelTask)
	}
}

func TestBuildLoadKeepsWorkingWhenDetectionReportsAnInvalidManifest(t *testing.T) {
	// Detection's rejected entries do not hide an instance another plugin
	// supplied. The panel records the warning without replacing the list.
	instance := core.BuildInstance{ID: "fixture:.", BuildSystemID: "fixture", PluginID: "example"}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	p.build.loading = true
	h.app.finishBuildDetection(p, p.build.generation, []buildInstance{{BuildInstance: instance}}, context.Canceled)
	if p.build.failed != "" {
		t.Fatalf("a warning hid the detected instance: %q", p.build.failed)
	}
	if len(p.build.instances) != 1 {
		t.Fatalf("instances = %+v", p.build.instances)
	}
}

// The window asks only for dependencies of a scope the build system declares (Core refuses any
// other with plugin.build.invalidSelection), names two instances of one system by their roots, and
// lists command tasks beside provider ones.
func TestBuildWindowPresentsDeclaredScopesRootsAndCommandTasks(t *testing.T) {
	instance := &buildInstance{
		BuildInstance: core.BuildInstance{BuildSystemID: "go", Root: "."},
		System: pluginservice.BuildSystemDeclaration{
			DisplayName:  "Go Modules",
			Dependencies: &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"project"}},
			Tasks: []pluginservice.BuildTaskDeclaration{
				{ID: "build", Source: "command", Category: []string{"Build"}},
				{ID: "goal", Source: "provider", Group: "other"},
				{ID: "model", FromModel: true},
			},
		},
		Model: core.BuildModel{Projects: []core.BuildProject{{ID: "root", Path: "."}, {ID: "lib", Path: "lib"}}},
	}
	if _, ok := buildDependencyProject(instance, ""); ok {
		t.Fatal("a build declaring only the project scope was asked for workspace dependencies")
	}
	if project, ok := buildDependencyProject(instance, "lib"); !ok || project != "lib" {
		t.Fatalf("chosen project = %q, %v", project, ok)
	}
	instance.Model.Projects = instance.Model.Projects[:1]
	if project, ok := buildDependencyProject(instance, ""); !ok || project != "root" {
		t.Fatalf("the only project = %q, %v", project, ok)
	}
	instance.System.Dependencies = nil
	if _, ok := buildDependencyProject(instance, "root"); ok {
		t.Fatal("a build declaring no dependencies was asked for them")
	}
	if name, root := buildSystemName(instance), buildRootDetail(instance); name != "Go Modules" || root != "" {
		t.Fatalf("workspace root group = %q, %q", name, root)
	}
	instance.Root = ".claude/worktrees/x/desktop"
	if name, root := buildSystemName(instance), buildRootDetail(instance); name != "Go Modules" || root != ".claude/worktrees/x/desktop" {
		t.Fatalf("nested root group = %q, %q", name, root)
	}
	tasks := declaredTasks(instance)
	if len(tasks) != 2 || tasks[0].ID != "build" || tasks[1].ID != "goal" {
		t.Fatalf("declared tasks = %+v", tasks)
	}
	if detail := buildTaskDetail(&tasks[0]); detail != "Build" {
		t.Fatalf("category detail = %q", detail)
	}
}
