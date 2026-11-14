package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
)

// buildTreeShape names each row of the build tree by its kind, label and, for a group, its
// root, so a test compares the whole tree at once.
func buildTreeShape(rows []buildRow) []string {
	kinds := map[buildRowKind]string{
		buildRowGroup: "group", buildRowSection: "section", buildRowEmpty: "note", buildRowProject: "project",
		buildRowTarget: "target", buildRowTask: "task", buildRowDependency: "dependency", buildRowTest: "test",
	}
	shape := make([]string, 0, len(rows))
	for _, row := range rows {
		entry := kinds[row.kind] + " " + row.label
		if row.kind == buildRowGroup && row.detail != "" {
			entry += " @" + row.detail
		}
		shape = append(shape, entry)
	}
	return shape
}

// twoEngines is one build system used at two roots of the workspace, its second checkout's
// targets named apart from the first's.
func twoEngines() []buildInstance {
	alpha := runConfigInstance("alpha")
	alpha.System.DisplayName = "Engine"
	beta := runConfigInstance("beta")
	beta.System.DisplayName = "Engine"
	beta.Model.Targets = []core.BuildTarget{
		{ID: "main", ProjectID: "server", Name: "Beta Main", Tags: []string{"app"}},
		{ID: "lib", ProjectID: "server", Name: "Beta Lib", Tags: []string{"library"}},
	}
	return []buildInstance{alpha, beta}
}

// openBuildTree opens a workspace whose detected build systems are instances.
func openBuildTree(t *testing.T, kernel Kernel, instances []buildInstance) (*harness, *project) {
	t.Helper()
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	p := h.app.project
	h.app.post(func(a *App) {
		p.build.instances, p.build.loaded, p.build.selected = instances, true, 0
	})
	h.settle()
	return h, p
}

// Every build system is a group of one tree, named once with its root beside it. The selected
// one is open by default and the others closed; a group the user opens or closes stays so, and
// opening every group opens their sections but the dependencies.
func TestBuildTreeGroupsEveryBuildSystemAndOpensTheSelectedOne(t *testing.T) {
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, twoEngines())
	tb := h.app.text.Build
	alpha := []string{
		"section " + tb.Projects, "project server",
		"section " + tb.Targets, "target Main", "target Lib",
		"section " + tb.Tasks, "note " + tb.NoTasks,
	}
	beta := []string{
		"section " + tb.Projects, "project server",
		"section " + tb.Targets, "target Beta Main", "target Beta Lib",
		"section " + tb.Tasks, "note " + tb.NoTasks,
	}
	want := slices.Concat([]string{"group Engine @alpha"}, alpha, []string{"group Engine @beta"})
	if got := buildTreeShape(h.app.buildTreeRows(p)); !slices.Equal(got, want) {
		t.Fatalf("default tree =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	p.setBuildOpen(buildOpenKey(p.build.instances[1].ID, ""), true)
	p.setBuildOpen(buildOpenKey(p.build.instances[0].ID, buildSectionTargets), false)
	rows := h.app.buildTreeRows(p)
	want = slices.Concat([]string{"group Engine @alpha", "section " + tb.Projects, "project server", "section " + tb.Targets,
		"section " + tb.Tasks, "note " + tb.NoTasks, "group Engine @beta"}, beta)
	if got := buildTreeShape(rows); !slices.Equal(got, want) {
		t.Fatalf("tree after opening the second group =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if section := rows[3]; section.open || section.count != 2 {
		t.Fatalf("a closed section shows open %v with count %d, want closed with its 2 targets", section.open, section.count)
	}

	p.setAllBuildGroups(false)
	if got := buildTreeShape(h.app.buildTreeRows(p)); !slices.Equal(got, []string{"group Engine @alpha", "group Engine @beta"}) {
		t.Fatalf("collapsed tree = %q", got)
	}
	p.setAllBuildGroups(true)
	want = slices.Concat([]string{"group Engine @alpha"}, alpha, []string{"group Engine @beta"}, beta)
	if got := buildTreeShape(h.app.buildTreeRows(p)); !slices.Equal(got, want) {
		t.Fatalf("expanded tree =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if p.buildSectionOpen(p.build.instances[0].ID, buildSectionDependencies) {
		t.Fatal("opening every group opened the dependencies, which run the build tool")
	}
}

// The filter keeps a group whose name or root matches as it shows without one, and of another
// only the rows that match, open under their sections. It reads the models already loaded and
// never starts a load.
func TestBuildTreeFilterKeepsMatchesUnderTheirGroups(t *testing.T) {
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, twoEngines())
	tb := h.app.text.Build

	p.panels.buildFilter = "  MAIN "
	rows := h.app.buildTreeRows(p)
	want := []string{
		"group Engine @alpha", "section " + tb.Targets, "target Main",
		"group Engine @beta", "section " + tb.Targets, "target Beta Main",
	}
	if got := buildTreeShape(rows); !slices.Equal(got, want) {
		t.Fatalf("filtered tree =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	for _, row := range rows {
		if (row.kind == buildRowGroup || row.kind == buildRowSection) && (!row.open || !row.fixed) {
			t.Fatalf("row %q of a filtered group is open %v, fixed %v; want open and fixed", row.label, row.open, row.fixed)
		}
	}
	if rows[1].count != 1 {
		t.Fatalf("a filtered section counts %d rows, want its 1 match", rows[1].count)
	}

	p.panels.buildFilter = "beta"
	rows = h.app.buildTreeRows(p)
	if got := buildTreeShape(rows); !slices.Equal(got, []string{"group Engine @beta"}) {
		t.Fatalf("tree filtered by a root = %q", got)
	}
	if rows[0].fixed || rows[0].open {
		t.Fatalf("a group matching by its root shows open %v, fixed %v; want it as without a filter", rows[0].open, rows[0].fixed)
	}

	p.panels.buildFilter = "nothing matches this"
	if rows = h.app.buildTreeRows(p); len(rows) != 0 {
		t.Fatalf("tree filtered by an unmatched query = %q", buildTreeShape(rows))
	}

	p.build.instances[1].modelLoaded = false
	p.setBuildOpen(buildOpenKey(p.build.instances[1].ID, ""), true)
	p.panels.buildFilter = "main"
	if got := buildTreeShape(h.app.buildTreeRows(p)); !slices.Equal(got, want[:3]) {
		t.Fatalf("tree filtered with an unloaded model = %q", got)
	}
	if p.build.instances[1].modelLoading {
		t.Fatal("the filter started a model load")
	}
}

// A target whose name ends with its path, as a Go package's import path ends with its folder,
// shows the path alone and its full name while the pointer rests on the row; another target
// shows its name with its path beside it. The filter still finds a target by the part of its
// name the row leaves out.
func TestBuildTargetRowShowsThePathAndTheFullNameOnHover(t *testing.T) {
	instance := runConfigInstance("go")
	instance.System.DisplayName = "Engine"
	instance.Model.Targets = []core.BuildTarget{
		{ID: "api", ProjectID: "server", Name: "example.com/shop/cmd/api", Path: "shop/cmd/api", Tags: []string{"app"}},
		{ID: "cli", ProjectID: "server", Name: "shop-cli", Path: "cli", Tags: []string{"app"}},
		{ID: "shop", ProjectID: "server", Name: "shop", Path: "shop/", Tags: []string{"library"}},
	}
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, []buildInstance{instance})
	targets := func() [][3]string {
		var out [][3]string
		for _, row := range h.app.buildTreeRows(p) {
			if row.kind == buildRowTarget {
				out = append(out, [3]string{row.label, row.detail, row.tooltip})
			}
		}
		return out
	}
	want := [][3]string{{"shop/cmd/api", "", "example.com/shop/cmd/api"}, {"shop-cli", "cli", ""}, {"shop", "", ""}}
	if got := targets(); !slices.Equal(got, want) {
		t.Fatalf("target rows (label, detail, tooltip) = %q, want %q", got, want)
	}

	h.app.reduceChrome(core.SetChromeOpen(itemBuild, true))
	h.settle()
	h.settle()
	if h.labelBounds("shop/cmd/api") == (gfx.Rect{}) || h.labelBounds("example.com/shop/cmd/api") != (gfx.Rect{}) {
		t.Fatal("the row of a target named after its path did not show the path alone")
	}
	label, hinted := center(h.labelBounds("shop/cmd/api")), false
	for _, hit := range h.driver.Snapshot().Hits {
		b := hit.Bounds
		if hit.Hint == "example.com/shop/cmd/api" && !hit.ID.IsZero() && label.X >= b.X && label.X < b.Right() && label.Y >= b.Y && label.Y < b.Bottom() {
			hinted = true
		}
	}
	if !hinted {
		t.Fatal("the row of a target shown by its path does not give its full name on hover")
	}

	p.panels.buildFilter = "example.com"
	if got := targets(); len(got) != 1 || got[0][0] != "shop/cmd/api" {
		t.Fatalf("filtering by the hidden part of the name kept %q", got)
	}
}

// gatedModelKernel holds each model load of an instance whose root starts with "m" until
// release closes, then refuses it, so a test sees which loads run together.
type gatedModelKernel struct {
	*testKernel
	started chan string
	release chan struct{}
}

func (k *gatedModelKernel) ReadPluginSettingsState(context.Context, json.RawMessage, *string, *string, *core.PluginSettingsLocalizationRequest) (core.PluginSettingsState, error) {
	return core.PluginSettingsState{}, nil
}

func (k *gatedModelKernel) PlanBuildInvocation(ctx context.Context, _ json.RawMessage, _ string, request core.BuildInvocationRequest) (core.BuildInvocation, error) {
	if !strings.HasPrefix(request.Root, "m") {
		return core.BuildInvocation{}, errors.New("not a gated instance")
	}
	k.started <- request.Root
	select {
	case <-k.release:
	case <-ctx.Done():
	}
	return core.BuildInvocation{}, errors.New("refused")
}

// The open groups load their models a few at a time; a closed group loads nothing, and a model
// that failed is not tried again by itself.
func TestBuildTreeLoadsOpenModelsAFewAtATime(t *testing.T) {
	kernel := &gatedModelKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan string, 16), release: make(chan struct{})}
	released := false
	release := func() {
		if !released {
			released = true
			close(kernel.release)
		}
	}
	instances := make([]buildInstance, 6)
	for index := range instances {
		instances[index] = runConfigInstance(fmt.Sprintf("m%d", index))
		instances[index].modelLoaded = false
	}
	h, p := openBuildTree(t, kernel, instances)
	// The harness waits for every load when it closes; a gate still shut would hold it.
	t.Cleanup(release)
	if h.app.chrome.isOpen(h.app.chrome.index[itemBuild]) {
		t.Fatal("the Build window is open by default, so its view would start loads of its own")
	}
	p.setAllBuildGroups(true)
	p.setBuildOpen(buildOpenKey(p.build.instances[5].ID, ""), false)

	loading := func() []int {
		var indexes []int
		for index := range p.build.instances {
			if p.build.instances[index].modelLoading {
				indexes = append(indexes, index)
			}
		}
		return indexes
	}
	h.app.loadOpenBuildModels(p)
	if got := loading(); !slices.Equal(got, []int{0, 1, 2, 3}) {
		t.Fatalf("loading = %v, want the first %d open groups", got, buildModelLoadsAtOnce)
	}
	var roots []string
	for range buildModelLoadsAtOnce {
		roots = append(roots, awaitValueWithin(t, h, 10*time.Second, kernel.started, "a model load"))
	}
	slices.Sort(roots)
	if !slices.Equal(roots, []string{"m0", "m1", "m2", "m3"}) {
		t.Fatalf("loads started for %v", roots)
	}
	// A frame while they run starts no fifth.
	h.app.loadOpenBuildModels(p)
	if got := loading(); !slices.Equal(got, []int{0, 1, 2, 3}) {
		t.Fatalf("loading while full = %v", got)
	}

	release()
	awaitStateWithin(t, h, 10*time.Second, "the refused loads to end", func() bool {
		for index := range 4 {
			if p.build.instances[index].modelError == "" {
				return false
			}
		}
		return true
	})
	h.app.loadOpenBuildModels(p)
	if got := loading(); !slices.Equal(got, []int{4}) {
		t.Fatalf("loading after the refusals = %v, want only the open group not tried yet", got)
	}
	if root := awaitValueWithin(t, h, 10*time.Second, kernel.started, "the fifth model load"); root != "m4" {
		t.Fatalf("the next load is for %q", root)
	}
	awaitStateWithin(t, h, 10*time.Second, "the fifth load to end", func() bool { return p.build.instances[4].modelError != "" })
	h.app.loadOpenBuildModels(p)
	if got := loading(); len(got) != 0 {
		t.Fatalf("loading after every open group failed = %v", got)
	}
	if len(kernel.started) != 0 || p.build.instances[5].modelError != "" {
		t.Fatalf("a failed or closed group loaded again: %d more loads, closed group error %q", len(kernel.started), p.build.instances[5].modelError)
	}
}

// A click on a row of another group selects that group's build system and the row, so the
// window's Run button runs it; a click on a group selects it and leaves it open or closed, and
// its arrow opens and closes it.
func TestBuildTreeRowsChooseTheirBuildSystem(t *testing.T) {
	instances := twoEngines()
	instances[1].BuildSystemID, instances[1].System.DisplayName = "forge", "Forge"
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, instances)
	h.app.reduceChrome(core.SetChromeOpen(itemBuild, true))
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.settle()
	absent := func(value string) bool { return h.labelBounds(value) == (gfx.Rect{}) }
	if absent("Main") || !absent("Beta Main") {
		t.Fatal("the tree did not open the selected build system alone")
	}
	language := h.app.language()
	expand := i18n.Shared(language, "native.expandSection")
	collapse := i18n.Shared(language, "native.collapseSection")

	// The group row selects its build system and leaves it closed.
	h.click(center(h.labelBounds("beta")))
	if p.build.selected != 1 || p.buildGroupOpen(1) || !p.buildGroupOpen(0) {
		t.Fatalf("selected %d, open %v and %v after a click on the closed group", p.build.selected, p.buildGroupOpen(0), p.buildGroupOpen(1))
	}
	if _, _, ok := h.app.buildChosenAction(p); ok {
		t.Fatal("a selected group with nothing chosen in it has a run")
	}

	// Its arrow opens it.
	h.click(center(h.pageHit(expand + " Forge").Bounds))
	if !p.buildGroupOpen(1) || absent("Beta Main") {
		t.Fatal("the arrow did not open the group")
	}

	// A target of the other group selects that group's build system with the target.
	h.click(center(h.labelBounds("Main")))
	if p.build.selected != 0 || p.build.targetID != "main" || p.build.projectID != "server" || p.build.taskID != "" {
		t.Fatalf("selected %d, target %q, project %q, task %q", p.build.selected, p.build.targetID, p.build.projectID, p.build.taskID)
	}
	if label, run, ok := h.app.buildChosenAction(p); !ok || run == nil || label != h.app.text.Build.RunTarget("Run") {
		t.Fatalf("the chosen target runs as %q, %v", label, ok)
	}
	if !p.buildGroupOpen(1) {
		t.Fatal("selecting another build system closed the group the user opened")
	}

	// The arrow closes a group and hides its rows.
	h.click(center(h.pageHit(collapse + " Engine").Bounds))
	if p.buildGroupOpen(0) || !absent("Main") || absent("Beta Main") {
		t.Fatal("the arrow did not close the group alone")
	}
}

// A declared task runs on the project or target its scopes accept, fitted from the window's
// selection: Core refuses a request whose scope the task does not declare.
func TestBuildTaskSelectionFitsDeclaredScopes(t *testing.T) {
	rooted := core.BuildModel{
		Projects: []core.BuildProject{{ID: "root", Path: "."}, {ID: "server", Path: "server"}, {ID: "web", Path: "web"}},
		Targets: []core.BuildTarget{
			{ID: "main", ProjectID: "server", Tags: []string{"app"}},
			{ID: "lib", ProjectID: "server", Tags: []string{"library"}},
			{ID: "site", ProjectID: "web", Tags: []string{"app"}},
		},
	}
	flat := core.BuildModel{Projects: []core.BuildProject{{ID: "server", Path: "server"}, {ID: "web", Path: "web"}}}
	single := runConfigInstance("app").Model
	for _, test := range []struct {
		name                    string
		model                   core.BuildModel
		scopes, tags            []string
		project, target         string
		wantProject, wantTarget string
		ok                      bool
	}{
		{name: "a project task runs on the only project", model: single, scopes: []string{"project"}, wantProject: "server", ok: true},
		{name: "a project task runs on the root project", model: rooted, scopes: []string{"project"}, wantProject: "root", ok: true},
		{name: "a project task runs on the chosen project", model: rooted, scopes: []string{"project"}, project: "web", wantProject: "web", ok: true},
		{name: "a project task runs on the chosen target's project", model: rooted, scopes: []string{"project"}, target: "main", wantProject: "server", ok: true},
		{name: "a project task cannot pick among projects", model: flat, scopes: []string{"project"}},
		{name: "a target task runs on the chosen target", model: rooted, scopes: []string{"target"}, tags: []string{"app"}, target: "main", wantProject: "server", wantTarget: "main", ok: true},
		{name: "a target task refuses a target without its tags", model: rooted, scopes: []string{"target"}, tags: []string{"app"}, target: "lib"},
		{name: "a target task cannot pick among targets", model: rooted, scopes: []string{"target"}, tags: []string{"app"}},
		{name: "a target task runs on the only target of the chosen project", model: rooted, scopes: []string{"target"}, tags: []string{"app"}, project: "web", wantProject: "web", wantTarget: "site", ok: true},
		{name: "a target task runs on the only target it applies to", model: rooted, scopes: []string{"target"}, tags: []string{"library"}, wantProject: "server", wantTarget: "lib", ok: true},
		{name: "a target or project task falls back to the target's project", model: rooted, scopes: []string{"target", "project"}, tags: []string{"app"}, target: "lib", wantProject: "server", ok: true},
		{name: "a workspace task drops the chosen project", model: rooted, scopes: []string{"workspace"}, project: "web", ok: true},
		{name: "a workspace or project task keeps the chosen project", model: rooted, scopes: []string{"workspace", "project"}, project: "web", wantProject: "web", ok: true},
		{name: "a workspace or project task runs on the workspace", model: rooted, scopes: []string{"workspace", "project"}, ok: true},
		{name: "a target the model lost is kept for its report", model: rooted, scopes: []string{"project"}, project: "web", target: "gone", wantProject: "web", wantTarget: "gone", ok: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			instance := &buildInstance{Model: test.model}
			task := &pluginservice.BuildTaskDeclaration{ID: "task", Scopes: test.scopes, TargetTags: test.tags}
			project, target, ok := buildTaskSelection(instance, task, test.project, test.target)
			if ok != test.ok || project != test.wantProject || target != test.wantTarget {
				t.Fatalf("selection = %q, %q, %v, want %q, %q, %v", project, target, ok, test.wantProject, test.wantTarget, test.ok)
			}
		})
	}
}

// captureBuildTask records the task plans the window asks Core for and refuses each, so no
// task runs.
type captureBuildTask struct {
	Kernel
	requests chan core.BuildPlanRequest
}

func (k *captureBuildTask) PlanBuildTask(_ context.Context, _ json.RawMessage, _ string, request core.BuildPlanRequest) (core.BuildPlan, error) {
	k.requests <- request
	return core.BuildPlan{}, errors.New("captured")
}

// A task, and a target that has a run, lead with the green triangle that runs them whether
// they are chosen or not, as IntelliJ's Make window marks its targets: one click on it chooses
// the row and runs it. A target with nothing to run keeps the icon of its kind, a build
// operation in flight leaves no triangle to click, a row's hover hint holds its whole name and
// path, and the Dependencies heading has the ⓘ that says when its tree is read.
func TestBuildTreeRunMarksRunTheirRowsAtOnce(t *testing.T) {
	instance := runConfigInstance("app")
	instance.System.Tasks = []pluginservice.BuildTaskDeclaration{{ID: "vet", DisplayName: "Vet verification", Scopes: []string{"project"}, Source: "provider"}}
	instance.System.Dependencies = &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"project"}}
	instance.Model.Targets[0].Path = "server/cmd/main"
	kernel := &captureBuildTask{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := openBuildTree(t, kernel, []buildInstance{instance})
	h.app.reduceChrome(core.SetChromeOpen(itemBuild, true))
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.settle()
	text, language := h.app.text.Build, h.app.language()
	controls := func(label string) []gfx.Hit {
		var found []gfx.Hit
		for _, hit := range h.driver.Snapshot().Hits {
			if hit.Label == label && !hit.IsLabel {
				found = append(found, hit)
			}
		}
		return found
	}
	if marks := controls(text.RunTarget("Run")); len(marks) != 1 {
		t.Fatalf("%d target triangles, want only the one of the target that has a run", len(marks))
	}
	task := controls(text.RunTarget("Vet verification"))
	if len(task) != 1 || task[0].Hint != text.RunTarget("Vet verification") {
		t.Fatalf("the task's triangle is %+v", task)
	}
	if rows := controls("Main"); len(rows) != 1 || rows[0].Hint != "Main\nserver/cmd/main" {
		t.Fatalf("the target row's hover hint is %+v", rows)
	}
	help := controls(i18n.Shared(language, "native.moreInformation"))
	if len(help) != 1 || help[0].Hint != i18n.Shared(language, "desktop.build.dependenciesHelp") {
		t.Fatalf("the Dependencies heading's ⓘ is %+v", help)
	}

	// One click on the triangle of a task nothing chose chooses it and runs it.
	if p.build.taskID != "" || p.build.targetID != "" {
		t.Fatalf("task %q and target %q chosen before the click", p.build.taskID, p.build.targetID)
	}
	h.click(center(task[0].Bounds))
	awaitStateWithin(t, h, 10*time.Second, "the task plan request", func() bool { return len(kernel.requests) == 1 })
	if request := <-kernel.requests; request.Task != "vet" || p.build.taskID != "vet" {
		t.Fatalf("the triangle asked for %+v with task %q chosen", request, p.build.taskID)
	}
	awaitStateWithin(t, h, 10*time.Second, "the refused plan", func() bool { return p.build.operation == nil })

	// While a build operation runs, no triangle takes a click.
	var operation *buildOperation
	h.app.post(func(a *App) { operation = a.beginBuildOperation(p, "build", "vet", "") })
	h.settle()
	if len(controls(text.RunTarget("Vet verification"))) != 0 || len(controls(text.RunTarget("Run"))) != 0 {
		t.Fatal("a triangle took clicks while a build operation ran")
	}
	h.app.post(func(a *App) { a.finishBuildTask(p, operation, json.RawMessage(`{"exitCode":0}`)) })
	h.settle()
}

// A task row of the tree carries no project, so the run fits the selection to the task: a
// project task runs on the build system's only project instead of the workspace, a model task
// on its own project, and a project task with no project to infer asks for one.
func TestBuildTreeTasksRunOnTheScopeTheyDeclare(t *testing.T) {
	instance := runConfigInstance("app")
	instance.System.Tasks = []pluginservice.BuildTaskDeclaration{{ID: "vet", DisplayName: "Vet verification", Scopes: []string{"project"}, Source: "provider"}}
	instance.Model.Tasks = []core.BuildTask{{ID: "server:check", ProjectID: "server", Name: "check", Template: "check", Execution: "task"}}
	kernel := &captureBuildTask{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := openBuildTree(t, kernel, []buildInstance{instance})
	h.app.reduceChrome(core.SetChromeOpen(itemBuild, true))
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.settle()
	run := func(row string) core.BuildPlanRequest {
		t.Helper()
		h.click(center(h.labelBounds(row)))
		label, start, ok := h.app.buildChosenAction(p)
		if !ok || label != h.app.text.Build.RunSelected {
			t.Fatalf("the %q row runs as %q, %v", row, label, ok)
		}
		h.app.post(func(*App) { start() })
		awaitStateWithin(t, h, 10*time.Second, "the task plan request of "+row, func() bool { return len(kernel.requests) == 1 })
		request := <-kernel.requests
		awaitStateWithin(t, h, 10*time.Second, "the refused plan of "+row, func() bool { return p.build.operation == nil })
		return request
	}

	if request := run("Vet verification"); request.Task != "vet" || request.Project == nil || request.Project.Path != "server" || request.Target != nil {
		t.Fatalf("the project task asked for %+v", request)
	}
	if request := run("check"); request.Task != "check" || request.ModelTask == nil || request.Project == nil || request.Project.Path != "server" || request.Target != nil {
		t.Fatalf("the model task asked for %+v", request)
	}

	// Another project with neither at the build root leaves nothing to infer.
	h.app.post(func(*App) {
		p.build.instances[0].Model.Projects = append(p.build.instances[0].Model.Projects, core.BuildProject{ID: "web", Path: "web", Name: "web"})
		p.build.projectID, p.build.targetID, p.build.taskID = "", "", "vet"
	})
	h.settle()
	h.app.post(func(a *App) { a.runSelectedBuildTask(p) })
	h.settle()
	if h.app.notice != h.app.text.Build.ChooseTaskScope || len(kernel.requests) != 0 || p.build.operation != nil {
		t.Fatalf("notice %q, %d requests, operation %v", h.app.notice, len(kernel.requests), p.build.operation)
	}

	// The chosen project narrows the model tasks to its own.
	h.app.post(func(*App) { p.build.projectID, p.build.taskID = "web", "" })
	h.settle()
	h.settle()
	if h.labelBounds("check") != (gfx.Rect{}) || h.labelBounds("Vet verification") == (gfx.Rect{}) {
		t.Fatal("another project's model task stayed in the tree")
	}
}
