package workbench

import (
	"cmp"
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

// buildTestManifest is a plugin manifest declaring the build system of instance as the window
// knows it, for the Core requests the window sends with an instance's manifest: the layout of
// its tree and the build file a project opens. Every task runs through the provider, so the
// declaration needs no command lines; a task without a name or a group shows its ID and files
// under "other".
func buildTestManifest(instance *buildInstance) json.RawMessage {
	type task struct {
		ID                    string   `json:"id"`
		DisplayName           string   `json:"displayName"`
		Description           string   `json:"description,omitempty"`
		Group                 string   `json:"group"`
		Scopes                []string `json:"scopes,omitempty"`
		TargetTags            []string `json:"targetTags,omitempty"`
		RequiresUserArguments bool     `json:"requiresUserArguments,omitempty"`
		FromModel             bool     `json:"fromModel,omitempty"`
		Category              []string `json:"category,omitempty"`
		Source                string   `json:"source"`
		Arguments             []string `json:"arguments"`
	}
	system, id := instance.System, instance.BuildSystemID
	tasks := make([]task, 0, len(system.Tasks))
	for _, declared := range system.Tasks {
		tasks = append(tasks, task{
			ID: declared.ID, DisplayName: cmp.Or(declared.DisplayName, declared.ID), Description: declared.Description,
			Group: cmp.Or(declared.Group, "other"), Scopes: declared.Scopes, TargetTags: declared.TargetTags,
			RequiresUserArguments: declared.RequiresUserArguments, FromModel: declared.FromModel, Category: declared.Category,
			Source: "provider", Arguments: []string{},
		})
	}
	declaration := map[string]any{
		"id": id, "displayName": buildSystemName(instance),
		"detection":  map[string]any{"markers": []string{id + ".build"}},
		"invocation": map[string]any{"executables": []any{map[string]string{"kind": "command", "command": id}}},
		"provider": map[string]any{
			"launch": map[string]string{"kind": "packaged", "path": "provider"}, "arguments": []string{},
			"executesProjectCode": false, "mayUseNetwork": false,
		},
		"model": map[string]string{"source": "provider"},
		"tasks": tasks,
	}
	if system.Dependencies != nil {
		declaration["dependencies"] = map[string]any{"source": "provider", "scopes": system.Dependencies.Scopes}
	}
	if test := system.Test; test != nil {
		entry := map[string]any{"source": "provider", "scopes": test.Scopes, "arguments": []string{}}
		if len(test.TargetTags) != 0 {
			entry["targetTags"] = test.TargetTags
		}
		if test.Discovery {
			entry["discovery"], entry["filters"] = true, []string{"suite", "case"}
		}
		declaration["test"] = entry
	}
	body, err := json.Marshal(map[string]any{
		"schemaVersion": 0, "id": cmp.Or(instance.PluginID, "dev.example."+id), "displayName": buildSystemName(instance),
		"version": "1.0.0", "pluginAPIVersion": 0, "requires": map[string]int{"buildProviders": 0, "buildSystems": 0},
		"vendor":      map[string]string{"id": "dev.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
		"permissions": []string{"languageServer.launch", "process.build"}, "activationEvents": []string{"onBuildSystem:" + id},
		"languages": []string{}, "buildSystems": []any{declaration},
	})
	if err != nil {
		panic(err)
	}
	return body
}

// buildRowName is the name a row shows: a group standing for its only root project shows that
// project's name.
func buildRowName(row buildRow) string {
	if row.kind == buildRowGroup && row.node != nil {
		return row.node.Label
	}
	return row.label
}

// buildTreeShape names each row of the build tree by its depth, kind, label and detail, and a
// group standing for a project by both names, so a test compares the whole tree at once.
func buildTreeShape(rows []buildRow) []string {
	kinds := map[buildRowKind]string{
		buildRowGroup: "group", buildRowFolder: "folder", buildRowEmpty: "note", buildRowProject: "project",
		buildRowTarget: "target", buildRowTask: "task", buildRowDependency: "dependency", buildRowTest: "test",
		buildRowOptionChoice: "choice",
	}
	shape := make([]string, 0, len(rows))
	for _, row := range rows {
		entry := strings.Repeat("  ", row.level) + kinds[row.kind]
		if row.kind == buildRowOptionChoice {
			if row.node != nil && row.node.Checked {
				entry += " [x]"
			} else {
				entry += " [ ]"
			}
		}
		entry += " " + row.label
		if row.kind == buildRowGroup && row.node != nil {
			entry += ": " + row.node.Label
		}
		if row.detail != "" {
			entry += " (" + row.detail + ")"
		}
		shape = append(shape, entry)
	}
	return shape
}

// buildRowAt is the row a path down the tree names: the first row named by the last name that
// follows the rows named by the names before it, in order.
func buildRowAt(t *testing.T, rows []buildRow, names ...string) buildRow {
	t.Helper()
	at := 0
	for step, name := range names {
		for at < len(rows) && buildRowName(rows[at]) != name {
			at++
		}
		if at == len(rows) {
			t.Fatalf("no row %q in\n%s", names[:step+1], strings.Join(buildTreeShape(rows), "\n"))
		}
		if step < len(names)-1 {
			at++
		}
	}
	return rows[at]
}

// setBuildNodeOpen opens or closes the node of the row at the path names, as its arrow does.
func setBuildNodeOpen(t *testing.T, p *project, rows []buildRow, open bool, names ...string) {
	t.Helper()
	row := buildRowAt(t, rows, names...)
	p.setBuildOpen(buildOpenKey(p.build.instances[row.instance].ID, row.node.Key),
		buildOpenState{open: open, dependencies: row.node.Kind == core.BuildTreeDependencies})
}

// laidOutBuildRows lists the tree's rows once Core has laid out every tree they show. A listing
// starts the layouts it lacks and shows what it already has, so the listing after them is the
// one the window settles on.
func laidOutBuildRows(t *testing.T, h *harness, p *project) []buildRow {
	t.Helper()
	for range 5 {
		rows, out := h.app.buildTreeRows(p)
		for index := range p.build.instances {
			trees := &p.build.instances[index].trees
			out = out || trees.wholeOut || trees.filteredOut
		}
		if !out {
			return slices.Clone(rows)
		}
		h.settle()
	}
	t.Fatal("the build trees were still being laid out")
	return nil
}

// expectBuildTree fails unless the tree's rows, once laid out, are want.
func expectBuildTree(t *testing.T, h *harness, p *project, what string, want []string) []buildRow {
	t.Helper()
	rows := laidOutBuildRows(t, h, p)
	if got := buildTreeShape(rows); !slices.Equal(got, want) {
		t.Fatalf("%s =\n%s\nwant\n%s", what, strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	return rows
}

// nestedEngine is a build of several modules at root, as a Maven reactor is: the root project
// shop holds shop-core and shop-web, and shop-web holds shop-web-api. Every project cleans and
// packages, the build runs a goal the user types once for the whole build, shop-web has an
// application that starts, and shop-core lists a plugin goal its model reports.
func nestedEngine(root string) buildInstance {
	instance := buildInstance{
		BuildInstance: core.BuildInstance{ID: "engine@" + root, PluginID: "dev.example.engine", BuildSystemID: "engine", Root: root, ModelSource: "provider"},
		PluginID:      "dev.example.engine",
		System: pluginservice.BuildSystemDeclaration{
			DisplayName: "Engine",
			Runs:        []pluginservice.BuildRunDeclaration{{ID: "application", Name: "Run", Tags: []string{"app"}}},
			Tasks: []pluginservice.BuildTaskDeclaration{
				{ID: "clean", DisplayName: "clean", Group: "lifecycle", Category: []string{"Lifecycle"}, Scopes: []string{"workspace", "project"}, Source: "provider"},
				{ID: "package", DisplayName: "package", Group: "lifecycle", Category: []string{"Lifecycle"}, Scopes: []string{"workspace", "project"}, Source: "provider"},
				{ID: "goal", DisplayName: "Run Goal…", Group: "other", Scopes: []string{"workspace", "project"}, RequiresUserArguments: true, Source: "provider"},
				{ID: "start", DisplayName: "Start", Group: "run", Scopes: []string{"target"}, TargetTags: []string{"app"}, Source: "provider"},
				{ID: "plugin", DisplayName: "Plugin Goal", Group: "build", Category: []string{"Plugins"}, FromModel: true, Source: "provider"},
			},
			Dependencies: &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"project"}},
		},
		Model: core.BuildModel{
			Projects: []core.BuildProject{
				{ID: "shop", Path: ".", Name: "shop"},
				{ID: "core", Path: "core", Name: "shop-core", ParentID: "shop"},
				{ID: "web", Path: "web", Name: "shop-web", ParentID: "shop"},
				{ID: "api", Path: "web/api", Name: "shop-web-api", ParentID: "web"},
			},
			Targets: []core.BuildTarget{{ID: "app", ProjectID: "web", Name: "ShopApplication", Path: "web", Tags: []string{"app"}}},
			Tasks: []core.BuildTask{{
				ID: "core:compile", ProjectID: "core", Name: "compiler:compile", Template: "plugin", Group: "build",
				Category: []string{"Plugins"}, Execution: "task",
			}},
		},
		modelLoaded: true,
	}
	return instance
}

// twoEngines is one build system used at two roots of the workspace: the nested build at alpha,
// and at beta two projects side by side with no root project above them.
func twoEngines() []buildInstance {
	beta := nestedEngine("beta")
	beta.Model = core.BuildModel{Projects: []core.BuildProject{{ID: "a", Path: "a", Name: "tool-a"}, {ID: "b", Path: "b", Name: "tool-b"}}}
	return []buildInstance{nestedEngine("alpha"), beta}
}

// openBuildTree opens a workspace whose detected build systems are instances, each declared by
// a manifest of its own unless it has one.
func openBuildTree(t *testing.T, kernel Kernel, instances []buildInstance) (*harness, *project) {
	t.Helper()
	for index := range instances {
		if instances[index].Manifest == nil {
			instances[index].Manifest = buildTestManifest(&instances[index])
		}
	}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	p := h.app.project
	h.app.post(func(a *App) {
		setDetected(p, instances)
		p.build.selected = 0
	})
	h.settle()
	return h, p
}

// buildTreeWords are the headings the host gives the nodes Core leaves unnamed, and the
// heading of the "other" task group.
func buildTreeWords(h *harness) (dependencies, targets, other string) {
	language := h.app.language()
	return i18n.Shared(language, "native.dependencies"), h.app.text.Build.Targets, i18n.Shared(language, "desktop.build.group.other")
}

// Every build system is a group of one tree, as IntelliJ's Maven window shows a build: child
// projects nest under their parent, and every project holds its tasks in folders, its
// dependencies and its targets. A group whose build has one root project stands for it; one
// with several lists them. The selected group is open by default and the others closed, the
// projects open and everything else closed. What the user opens and closes stays so, across a
// reload of the model too; opening every node leaves the dependencies closed, since each one
// opened runs the build tool. A task every project lists shows chosen under its own project
// only.
func TestBuildTreeNestsProjectsWithTheirFolders(t *testing.T) {
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, twoEngines())
	dependencies, targets, other := buildTreeWords(h)
	alpha := []string{
		"group Engine: shop (alpha)",
		"  folder Lifecycle",
		"  folder " + other,
		"  folder " + dependencies,
		"  project shop-core (core)",
		"    folder Lifecycle",
		"    folder Plugins",
		"    folder " + dependencies,
		"  project shop-web (web)",
		"    folder Lifecycle",
		"    folder " + dependencies,
		"    folder " + targets,
		"    project shop-web-api (web/api)",
		"      folder Lifecycle",
		"      folder " + dependencies,
	}
	rows := expectBuildTree(t, h, p, "default tree", append(slices.Clone(alpha), "group Engine (beta)"))

	p.setBuildGroupOpen(1, true)
	setBuildNodeOpen(t, p, rows, true, "shop-core", "Lifecycle")
	setBuildNodeOpen(t, p, rows, false, "shop-web")
	beta := []string{
		"group Engine (beta)",
		"  folder " + other,
		"  project tool-a (a)",
		"    folder Lifecycle",
		"    folder " + dependencies,
		"  project tool-b (b)",
		"    folder Lifecycle",
		"    folder " + dependencies,
	}
	changed := slices.Concat(alpha[:5], []string{"    folder Lifecycle", "      task clean", "      task package"}, alpha[6:9], beta)
	expectBuildTree(t, h, p, "tree after opening and closing nodes", changed)

	// A reload keeps every node as the user left it: Core keys a node by what it stands for.
	instance := &p.build.instances[0]
	instance.Model.Projects = append(slices.Clone(instance.Model.Projects), core.BuildProject{ID: "docs", Path: "docs", Name: "shop-docs", ParentID: "shop"})
	instance.modelVersion++
	reloaded := slices.Concat(changed[:len(changed)-len(beta)], []string{"  project shop-docs (docs)", "    folder Lifecycle", "    folder " + dependencies}, beta)
	expectBuildTree(t, h, p, "tree after a reload", reloaded)

	p.setAllBuildGroups(false)
	expectBuildTree(t, h, p, "collapsed tree", []string{"group Engine: shop (alpha)", "group Engine (beta)"})
	p.setAllBuildGroups(true)
	expanded := []string{
		"group Engine: shop (alpha)",
		"  folder Lifecycle",
		"    task clean",
		"    task package",
		"  folder " + other,
		"    task Run Goal…",
		"  folder " + dependencies,
		"  project shop-core (core)",
		"    folder Lifecycle",
		"      task clean",
		"      task package",
		"    folder Plugins",
		"      task compiler:compile",
		"    folder " + dependencies,
		"  project shop-web (web)",
		"    folder Lifecycle",
		"      task clean",
		"      task package",
		"    folder " + dependencies,
		"    folder " + targets,
		"      target ShopApplication (web)",
		"        task Start",
		"    project shop-web-api (web/api)",
		"      folder Lifecycle",
		"        task clean",
		"        task package",
		"      folder " + dependencies,
		"  project shop-docs (docs)",
		"    folder Lifecycle",
		"      task clean",
		"      task package",
		"    folder " + dependencies,
		"group Engine (beta)",
		"  folder " + other,
		"    task Run Goal…",
		"  project tool-a (a)",
		"    folder Lifecycle",
		"      task clean",
		"      task package",
		"    folder " + dependencies,
		"  project tool-b (b)",
		"    folder Lifecycle",
		"      task clean",
		"      task package",
		"    folder " + dependencies,
	}
	rows = expectBuildTree(t, h, p, "expanded tree", expanded)

	p.build.projectID, p.build.taskID = "core", "clean"
	want := buildRowAt(t, rows, "shop-core", "clean").node.Key
	// A group row's flag says its build system is selected; the rows below it say what is chosen.
	var chosen []string
	for _, row := range laidOutBuildRows(t, h, p) {
		if row.selected && row.kind != buildRowGroup {
			chosen = append(chosen, row.node.Key)
		}
	}
	if !slices.Equal(chosen, []string{want}) {
		t.Fatalf("the chosen rows are %q, want only shop-core's clean %q", chosen, want)
	}
}

// The filter keeps of every group the nodes that match and the nodes on the way to them, open
// and fixed so, and leaves out a group where nothing matches. A match shows as the user left it,
// with all it holds; so does a whole group whose name, root or project matches. The folder
// headings the host names match too. While the first filtered layout is out the window does
// not yet say nothing matches, and a later query shows the tree of the one before until its
// own is laid out. The filter reads the models already loaded and never starts a load.
func TestBuildTreeFilterKeepsMatchesUnderTheirProjects(t *testing.T) {
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, twoEngines())
	dependencies, targets, other := buildTreeWords(h)

	p.panels.buildFilter = "  START "
	if rows, pending := h.app.buildTreeRows(p); len(rows) != 0 || !pending {
		t.Fatalf("before its layout the filtered tree shows %q, pending %v", buildTreeShape(rows), pending)
	}
	started := []string{
		"group Engine: shop (alpha)",
		"  project shop-web (web)",
		"    folder " + targets,
		"      target ShopApplication (web)",
		"        task Start",
	}
	rows := expectBuildTree(t, h, p, "filtered tree", started)
	for _, row := range rows[:4] {
		if !row.open || !row.fixed {
			t.Fatalf("row %q on the way to a match is open %v, fixed %v; want open and fixed", row.label, row.open, row.fixed)
		}
	}
	p.panels.buildFilter = "star"
	if rows, _ := h.app.buildTreeRows(p); !slices.Equal(buildTreeShape(rows), started) {
		t.Fatalf("while the next query is laid out the tree shows %q", buildTreeShape(rows))
	}
	expectBuildTree(t, h, p, "tree filtered by the next query", started)

	p.panels.buildFilter = "shop-web"
	rows = expectBuildTree(t, h, p, "tree filtered by a project", []string{
		"group Engine: shop (alpha)",
		"  project shop-web (web)",
		"    folder Lifecycle",
		"    folder " + dependencies,
		"    folder " + targets,
		"    project shop-web-api (web/api)",
		"      folder Lifecycle",
		"      folder " + dependencies,
	})
	if row := rows[1]; row.fixed || !row.open {
		t.Fatalf("a matching project shows open %v, fixed %v; want as the user left it", row.open, row.fixed)
	}

	p.panels.buildFilter = "shop"
	rows = expectBuildTree(t, h, p, "tree filtered by the project a group stands for", []string{
		"group Engine: shop (alpha)",
		"  folder Lifecycle",
		"  folder " + other,
		"  folder " + dependencies,
		"  project shop-core (core)",
		"    folder Lifecycle",
		"    folder Plugins",
		"    folder " + dependencies,
		"  project shop-web (web)",
		"    folder Lifecycle",
		"    folder " + dependencies,
		"    folder " + targets,
		"    project shop-web-api (web/api)",
		"      folder Lifecycle",
		"      folder " + dependencies,
	})
	if !rows[0].fixed || rows[4].fixed {
		t.Fatalf("the group is fixed %v and its projects %v; want the group fixed open and the rest as without a filter", rows[0].fixed, rows[4].fixed)
	}

	p.panels.buildFilter = "beta"
	rows = expectBuildTree(t, h, p, "tree filtered by a root", []string{"group Engine (beta)"})
	if rows[0].fixed || rows[0].open {
		t.Fatalf("a group matching by its root shows open %v, fixed %v; want it as without a filter", rows[0].open, rows[0].fixed)
	}

	p.panels.buildFilter = other
	expectBuildTree(t, h, p, "tree filtered by a folder heading", []string{
		"group Engine: shop (alpha)", "  folder " + other, "group Engine (beta)", "  folder " + other,
	})

	p.panels.buildFilter = "nothing matches this"
	laidOutBuildRows(t, h, p)
	if rows, pending := h.app.buildTreeRows(p); len(rows) != 0 || pending {
		t.Fatalf("tree filtered by an unmatched query = %q, pending %v", buildTreeShape(rows), pending)
	}

	p.build.instances[0].modelLoaded = false
	p.setBuildGroupOpen(0, true)
	p.panels.buildFilter = "tool-a"
	expectBuildTree(t, h, p, "tree filtered with an unloaded model", []string{
		"group Engine (beta)", "  project tool-a (a)",
		"    folder Lifecycle", "    folder " + dependencies,
	})
	if p.build.instances[0].modelLoading {
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
	p.setAllBuildGroups(true)
	targets := func() [][3]string {
		t.Helper()
		var out [][3]string
		for _, row := range laidOutBuildRows(t, h, p) {
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

	openBuildWindow(t, h, p)
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
	p.setBuildGroupOpen(5, false)

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
// window's Run button runs it; a click on a group, which shows the name of the project it
// stands for, selects it and leaves it open or closed, and its arrow opens and closes it.
func TestBuildTreeRowsChooseTheirBuildSystem(t *testing.T) {
	alpha := runConfigInstance("alpha")
	alpha.System.DisplayName = "Engine"
	beta := runConfigInstance("beta")
	beta.BuildSystemID, beta.System.DisplayName = "forge", "Forge"
	beta.Model.Projects = []core.BuildProject{{ID: "server", Path: "server", Name: "tools"}}
	beta.Model.Targets = []core.BuildTarget{
		{ID: "main", ProjectID: "server", Name: "Beta Main", Tags: []string{"app"}},
		{ID: "lib", ProjectID: "server", Name: "Beta Lib", Tags: []string{"library"}},
	}
	h, p := openBuildTree(t, &testKernel{Client: core.NewClient()}, []buildInstance{alpha, beta})
	// Every node opens, so a group shows its targets once it opens; the second group closes.
	p.setAllBuildGroups(true)
	p.setBuildGroupOpen(1, false)
	h.app.reduceChrome(core.SetChromeOpen(itemBuild, true))
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	laidOutBuildRows(t, h, p)
	h.settle()
	h.settle()
	absent := func(value string) bool { return h.labelBounds(value) == (gfx.Rect{}) }
	if absent("Main") || !absent("Beta Main") || absent("tools") {
		t.Fatal("the tree did not show the first group open and the second closed by the name of its project")
	}
	language := h.app.language()
	expand := i18n.Shared(language, "native.expandSection")
	collapse := i18n.Shared(language, "native.collapseSection")

	// The group row selects its build system and leaves it closed.
	h.click(center(h.labelBounds("tools")))
	if p.build.selected != 1 || p.buildGroupOpen(1) || !p.buildGroupOpen(0) {
		t.Fatalf("selected %d, open %v and %v after a click on the closed group", p.build.selected, p.buildGroupOpen(0), p.buildGroupOpen(1))
	}
	if _, _, ok := h.app.buildChosenAction(p); ok {
		t.Fatal("a selected group with nothing chosen in it has a run")
	}

	// Its arrow opens it.
	h.click(center(h.pageHit(expand + " tools").Bounds))
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
	h.click(center(h.pageHit(collapse + " server").Bounds))
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

// openBuildWindow opens every node of the tree and the Build window, tall enough for all of it.
// The window opens through a post, which wakes the driver to paint it.
func openBuildWindow(t *testing.T, h *harness, p *project) {
	t.Helper()
	p.setAllBuildGroups(true)
	h.app.post(func(a *App) { a.reduceChrome(core.SetChromeOpen(itemBuild, true)) })
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	laidOutBuildRows(t, h, p)
	h.settle()
	h.settle()
}

// A task, and a target that has a run, lead with the green triangle that runs them whether
// they are chosen or not, as IntelliJ's Make window marks its targets: one click on it chooses
// the row and runs it. A target with nothing to run keeps the icon of its kind, a build
// operation in flight leaves no triangle to click, a row's hover hint holds its whole name and
// path, and the Dependencies node has the ⓘ that says when its tree is read.
func TestBuildTreeRunMarksRunTheirRowsAtOnce(t *testing.T) {
	instance := runConfigInstance("app")
	instance.System.Tasks = []pluginservice.BuildTaskDeclaration{{ID: "vet", DisplayName: "Vet verification", Scopes: []string{"project"}, Source: "provider"}}
	instance.System.Dependencies = &pluginservice.BuildDependenciesDeclaration{Scopes: []string{"project"}}
	instance.Model.Targets[0].Path = "server/cmd/main"
	kernel := &captureBuildTask{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := openBuildTree(t, kernel, []buildInstance{instance})
	openBuildWindow(t, h, p)
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
		t.Fatalf("the Dependencies node's ⓘ is %+v", help)
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

	// While a build operation runs, a task's triangle takes no click, since the Build window
	// runs one task at a time; a target's run runs beside it, so its triangle still does.
	var operation *buildOperation
	h.app.post(func(a *App) { operation = a.beginBuildOperation(p, "build", "vet", "", nil) })
	h.settle()
	if len(controls(text.RunTarget("Vet verification"))) != 0 {
		t.Fatal("a task's triangle took clicks while a build operation ran")
	}
	if len(controls(text.RunTarget("Run"))) != 1 {
		t.Fatal("a target's triangle took no click while a build operation ran")
	}
	h.app.post(func(a *App) { a.finishBuildTask(p, operation, json.RawMessage(`{"exitCode":0}`)) })
	h.settle()
}

// A task row runs on the project and target Core filed it under: a declared project task on
// the project it shows under, a model task on its own project. A project task chosen with no
// project, which nothing in the tree offers, asks for one when the build has several.
func TestBuildTreeTasksRunOnTheScopeTheyDeclare(t *testing.T) {
	instance := runConfigInstance("app")
	instance.System.Tasks = []pluginservice.BuildTaskDeclaration{
		{ID: "vet", DisplayName: "Vet verification", Scopes: []string{"project"}, Source: "provider"},
		{ID: "check", DisplayName: "Check", Group: "verification", FromModel: true, Source: "provider"},
	}
	instance.Model.Tasks = []core.BuildTask{{ID: "server:check", ProjectID: "server", Name: "check", Template: "check", Group: "verification", Execution: "task"}}
	kernel := &captureBuildTask{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := openBuildTree(t, kernel, []buildInstance{instance})
	openBuildWindow(t, h, p)
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
}

func TestBuildInstanceManifestCacheAndOptionOn(t *testing.T) {
	manifestWithToolbar := json.RawMessage(`{
		"buildSystems": [{
			"id": "fixture",
			"options": [
				{"id": "offline", "displayName": "Offline", "kind": "boolean", "presentation": "toolbar", "icon": {"path": "icons/offline.svg"}},
				{"id": "profiles", "displayName": "Profiles", "kind": "multiSelect"}
			]
		}]
	}`)
	instance := &buildInstance{
		BuildInstance: core.BuildInstance{
			BuildSystemID: "fixture",
			Options: map[string]json.RawMessage{
				"on":      json.RawMessage(`true`),
				"padded":  json.RawMessage(" true \n"),
				"off":     json.RawMessage(`false`),
				"invalid": json.RawMessage(`"true"`),
			},
		},
		Manifest: manifestWithToolbar,
	}
	if !instance.hasDeclaredOptions() {
		t.Fatal("hasDeclaredOptions = false, want true")
	}
	toolbar := instance.toolbarOptions()
	if len(toolbar) != 1 || toolbar[0].id != "offline" {
		t.Fatalf("toolbarOptions = %+v, want single offline toggle", toolbar)
	}
	// Mutating cached fields proves subsequent lookups reuse the cache while Manifest and ID match.
	instance.manifestHasOptions = false
	if instance.hasDeclaredOptions() {
		t.Fatal("hasDeclaredOptions reparsed manifest unexpectedly when cache key matched")
	}
	// Replacing Manifest invalidates the cache.
	instance.Manifest = json.RawMessage(`{"buildSystems":[{"id":"fixture","options":[{"id":"other","kind":"boolean"}]}]}`)
	if !instance.hasDeclaredOptions() || len(instance.toolbarOptions()) != 0 {
		t.Fatalf("cache did not invalidate on Manifest change: hasOptions=%v toolbar=%+v", instance.hasDeclaredOptions(), instance.toolbarOptions())
	}
	// Changing BuildSystemID invalidates the cache.
	instance.BuildSystemID = "other"
	if instance.hasDeclaredOptions() || len(instance.toolbarOptions()) != 0 {
		t.Fatalf("cache did not invalidate on BuildSystemID change: hasOptions=%v toolbar=%+v", instance.hasDeclaredOptions(), instance.toolbarOptions())
	}
	if !instance.optionOn("on") || !instance.optionOn("padded") {
		t.Fatal("optionOn returned false for true values")
	}
	if instance.optionOn("off") || instance.optionOn("invalid") || instance.optionOn("missing") {
		t.Fatal("optionOn returned true for non-true values")
	}
}

func TestBuildDependenciesCachesShownRowsUntilDirty(t *testing.T) {
	deps := &buildDependencies{
		open: map[string]bool{},
		tree: core.BuildDependencyTree{
			Dependencies: []core.BuildDependency{
				{
					Group:   "org.example",
					Name:    "parent",
					Version: "1.0",
					Children: []core.BuildDependency{
						{Group: "org.example", Name: "child", Version: "2.0"},
					},
				},
			},
		},
	}
	first := deps.shownRows()
	if len(first) != 1 || first[0].label != "org.example:parent:1.0" || first[0].depth != 0 {
		t.Fatalf("first shownRows = %+v", first)
	}
	second := deps.shownRows()
	if len(second) != 1 || &first[0] != &second[0] {
		t.Fatalf("second shownRows reallocated instead of returning cached slice")
	}
	deps.open["0"] = true
	deps.rowsDirty = true
	expanded := deps.shownRows()
	if len(expanded) != 2 || expanded[1].label != "org.example:child:2.0" || expanded[1].depth != 1 {
		t.Fatalf("expanded shownRows = %+v", expanded)
	}
	deps.tree = core.BuildDependencyTree{}
	deps.rowsDirty = true
	empty := deps.shownRows()
	if empty == nil || len(empty) != 0 {
		t.Fatalf("empty shownRows = %#v, want non-nil empty slice", empty)
	}
}
