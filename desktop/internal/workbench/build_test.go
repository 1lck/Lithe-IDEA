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
	op := h.app.beginBuildOperation(p, "build", "build", "", nil)
	feedBuildOutput(h.app, p, op, strings.Repeat("line "+strings.Repeat("x", 8)+"\n", buildOutputMaxLines+50))
	output := &op.session.output
	if len(output.lines) > buildOutputMaxLines {
		t.Fatalf("output has %d lines, want at most %d", len(output.lines), buildOutputMaxLines)
	}
	if output.bytes > buildOutputBytes {
		t.Fatalf("output has %d bytes, want at most %d", output.bytes, buildOutputBytes)
	}
	if output.open.text != "" || output.lines[len(output.lines)-1].text != "line xxxxxxxx" {
		t.Fatalf("the last output line was cut: %q, open %q", output.lines[len(output.lines)-1].text, output.open.text)
	}
	if output.sequence != buildOutputMaxLines+50 || output.start != output.sequence-len(output.lines) {
		t.Fatalf("output counts %d lines from %d, holding %d", output.sequence, output.start, len(output.lines))
	}
}

// feedBuildOutput decodes text as op's readers do and adds it to op's console at once, where
// streamBuildOutput posts it to the window thread.
func feedBuildOutput(a *App, p *project, op *buildOperation, text string) {
	op.decoder.deliver(text, func(chunk outputChunk, failure error) {
		a.reportOutputStyleFailure(failure)
		a.applyBuildOutput(p, op, chunk)
	})
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
	setDetected(p, nil)
	p.build.loading = true
	h.app.finishBuildDetection(p, p.build.generation, []buildInstance{{BuildInstance: instance}}, context.Canceled)
	if p.build.failed != "" {
		t.Fatalf("a warning hid the detected instance: %q", p.build.failed)
	}
	if len(p.build.instances) != 1 {
		t.Fatalf("instances = %+v", p.build.instances)
	}
}

// The window names two instances of one system by their roots.
func TestBuildWindowNamesInstancesByTheirRoots(t *testing.T) {
	instance := &buildInstance{
		BuildInstance: core.BuildInstance{BuildSystemID: "go", Root: "."},
		System:        pluginservice.BuildSystemDeclaration{DisplayName: "Go Modules"},
	}
	if name, root := buildSystemName(instance), buildRootDetail(instance); name != "Go Modules" || root != "" {
		t.Fatalf("workspace root group = %q, %q", name, root)
	}
	instance.Root = ".claude/worktrees/x/desktop"
	if name, root := buildSystemName(instance), buildRootDetail(instance); name != "Go Modules" || root != ".claude/worktrees/x/desktop" {
		t.Fatalf("nested root group = %q, %q", name, root)
	}
}

func TestBuildPanelShowsDeclaredTasksWithoutLoadingAModel(t *testing.T) {
	h, p := openIgnoredPathsProject(t, "", nil)
	p.setAllBuildGroups(true)
	checkTasks := func() {
		t.Helper()
		taskCount := 0
		for _, row := range laidOutBuildRows(t, h, p) {
			if row.model || row.warning {
				t.Fatalf("declarative build system showed a model warning: %q", row.label)
			}
			if row.kind == buildRowTask && row.label == "Fixture Task" {
				taskCount++
			}
		}
		if taskCount != 2 {
			t.Fatalf("found %d workspace task rows, want one for each of 2 detected instances", taskCount)
		}
		if count := buildSyncSessions(p); count != 0 {
			t.Fatalf("opening the declared task tree started %d model-load sessions", count)
		}
	}
	checkTasks()

	h.app.reloadBuildModel(p, 0)
	h.settle()
	checkTasks()

	h.app.reloadPluginBuildModels(p, "dev.lithe.test.ignored-paths")
	h.settle()
	checkTasks()
}
