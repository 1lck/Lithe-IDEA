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

// gatedModelKernel holds each model load of an instance whose root starts with "m" until
// release closes, then refuses it, so a test sees which loads run together.
type gatedModelKernel struct {
	*testKernel
	started chan string
	release chan struct{}
}

func (k *gatedModelKernel) ReadPluginSettingsState(context.Context, json.RawMessage, *string, *string) (core.PluginSettingsState, error) {
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
