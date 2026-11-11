package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// The Build tool window lists the dependencies of the chosen project (of the whole build when
// none is chosen) under its projects. The build plugin says how to get them: Core plans the
// command or the provider request (build.dependencyPlan) and decodes the answer into a
// bounded tree (build.decodeDependencies); the window only runs, shows and navigates. A
// dependency row opens and closes its children; a double click opens the project's build file.

// buildDependencyKernel is the part of Core the dependency tree uses.
type buildDependencyKernel interface {
	PlanBuildDependencies(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	DecodeBuildDependencies(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeDependenciesRequest) (core.BuildDependencyTree, error)
}

// buildDependencies is the tree of one project of one build instance.
type buildDependencies struct {
	loading bool
	failed  string
	tree    core.BuildDependencyTree
	// open are the rows shown opened, by their path of indexes ("0/3/1").
	open map[string]bool
	// generation rejects a load a reload replaced.
	generation uint64
}

// buildDependencyKey names the tree of project (empty for the whole build) of instance.
func buildDependencyKey(instance, project string) string { return instance + "\x00" + project }

// dependenciesOf is the tree of the chosen project of the selected instance, loading it the
// first time it is asked for.
func (a *App) dependenciesOf(p *project, instance *buildInstance) *buildDependencies {
	if p.build.dependencies == nil {
		p.build.dependencies = map[string]*buildDependencies{}
	}
	key := buildDependencyKey(instance.ID, p.build.projectID)
	deps := p.build.dependencies[key]
	if deps == nil {
		deps = &buildDependencies{open: map[string]bool{}}
		p.build.dependencies[key] = deps
		a.loadBuildDependencies(p, instance, p.build.projectID, deps, false)
	}
	return deps
}

// reloadBuildDependencies forgets every loaded tree, for a reloaded model.
func (p *project) reloadBuildDependencies() {
	for _, deps := range p.build.dependencies {
		deps.generation++
	}
	p.build.dependencies = nil
}

// loadBuildDependencies loads the tree of projectID into deps off the window thread.
func (a *App) loadBuildDependencies(p *project, instance *buildInstance, projectID string, deps *buildDependencies, refresh bool) {
	kernel, ok := a.kernel.(buildDependencyKernel)
	if !ok {
		return
	}
	var selection *core.BuildSelection
	if projectID != "" {
		project, found := buildProjectByID(instance.Model, projectID)
		if !found {
			deps.failed = a.text.Errors.Core("unknown project")
			return
		}
		selection = &core.BuildSelection{Name: project.Name, Path: project.Path}
	}
	deps.loading, deps.failed = true, ""
	deps.generation++
	generation := deps.generation
	captured := *instance
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		tree, err := a.buildDependencyTree(ctx, p, captured, kernel, selection, refresh)
		return func(a *App) {
			if deps.generation != generation {
				return
			}
			deps.loading = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("build_dependencies", err))
				deps.failed = err.Error()
				return
			}
			deps.tree = tree
		}
	})
}

// buildDependencyTree plans, runs and decodes one dependency request.
func (a *App) buildDependencyTree(ctx context.Context, p *project, instance buildInstance, kernel buildDependencyKernel, selection *core.BuildSelection, refresh bool) (core.BuildDependencyTree, error) {
	execution, err := a.resolveBuildExecutable(ctx, p, instance, a.text.Build)
	if err != nil {
		return core.BuildDependencyTree{}, err
	}
	request := core.BuildPlanRequest{Root: instance.Root, Options: instance.Options, WorkspaceRoot: p.root, Project: selection}
	decode := core.BuildDecodeDependenciesRequest{WorkspaceRoot: p.root, Root: instance.Root, Project: selection}
	if instance.System.Provider {
		if execution.Executable != "" {
			request.Tool = &core.BuildTool{Executable: execution.Executable, Environment: execution.Environment}
		}
		request.Refresh = refresh
		plan, err := kernel.PlanBuildDependencies(ctx, instance.Manifest, instance.BuildSystemID, request)
		if err != nil {
			return core.BuildDependencyTree{}, err
		}
		if plan.Provider == nil {
			return a.commandDependencies(ctx, p, instance, kernel, plan, execution, decode, "")
		}
		client, err := a.buildProvider(ctx, p, instance)
		if err != nil {
			return core.BuildDependencyTree{}, err
		}
		operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
		if err != nil {
			return core.BuildDependencyTree{}, err
		}
		result, err := operation.Wait(ctx)
		if err != nil {
			return core.BuildDependencyTree{}, err
		}
		decode.Result = result
		return kernel.DecodeBuildDependencies(ctx, instance.Manifest, instance.BuildSystemID, decode)
	}
	// A command may write its tree to a file the host allocates in the plugin's state.
	state := buildStateDirectory(a.plugins.Root, p.root, instance)
	if err := os.MkdirAll(state, 0o700); err != nil {
		return core.BuildDependencyTree{}, err
	}
	file, err := os.CreateTemp(state, "dependencies-*.json")
	if err != nil {
		return core.BuildDependencyTree{}, err
	}
	outputFile := file.Name()
	_ = file.Close()
	_ = os.Remove(outputFile)
	defer os.Remove(outputFile)
	request.OutputFile = outputFile
	plan, err := kernel.PlanBuildDependencies(ctx, instance.Manifest, instance.BuildSystemID, request)
	if err != nil {
		return core.BuildDependencyTree{}, err
	}
	if plan.Provider != nil {
		return core.BuildDependencyTree{}, errors.New("the build system answered with a provider request")
	}
	return a.commandDependencies(ctx, p, instance, kernel, plan, execution, decode, outputFile)
}

// commandDependencies runs a command plan and decodes what it printed or wrote.
func (a *App) commandDependencies(ctx context.Context, p *project, instance buildInstance, kernel buildDependencyKernel, plan core.BuildPlan, execution buildExecution, decode core.BuildDecodeDependenciesRequest, outputFile string) (core.BuildDependencyTree, error) {
	workingDirectory := filepath.Join(p.root, filepath.FromSlash(plan.WorkingDirectory))
	output, runErr := captureBuildProcess(ctx, execution.Executable, plan.Arguments, workingDirectory, applyToolchainSelection(plan.Environment, execution.selection()))
	if plan.Output == "outputFile" && outputFile != "" {
		decode.OutputFile = outputFile
	} else {
		decode.Output = output
	}
	tree, err := kernel.DecodeBuildDependencies(ctx, instance.Manifest, instance.BuildSystemID, decode)
	if err != nil {
		return core.BuildDependencyTree{}, errors.Join(runErr, err)
	}
	return tree, runErr
}

// buildDependencyRow is one shown row of a tree: its node, depth and path of indexes.
type buildDependencyRow struct {
	node  *core.BuildDependency
	depth int
	path  string
}

// shownDependencyRows lists the rows of the opened part of the tree, in order.
func (deps *buildDependencies) shownRows() []buildDependencyRow {
	var rows []buildDependencyRow
	var walk func(nodes []core.BuildDependency, depth int, prefix string)
	walk = func(nodes []core.BuildDependency, depth int, prefix string) {
		for i := range nodes {
			path := prefix + strconv.Itoa(i)
			rows = append(rows, buildDependencyRow{node: &nodes[i], depth: depth, path: path})
			if deps.open[path] {
				walk(nodes[i].Children, depth+1, path+"/")
			}
		}
	}
	walk(deps.tree.Dependencies, 0, "")
	return rows
}

// dependencyLabel is a dependency as group:name:version.
func dependencyLabel(d *core.BuildDependency) string {
	parts := make([]string, 0, 3)
	if d.Group != "" {
		parts = append(parts, d.Group)
	}
	parts = append(parts, d.Name)
	if d.Version != "" {
		parts = append(parts, d.Version)
	}
	return strings.Join(parts, ":")
}

// openBuildFile opens the build file of the chosen project (of the instance's root when
// none is chosen).
func (a *App) openBuildFile(p *project, instance *buildInstance) {
	if path := buildFileOf(p, instance, p.build.projectID); path != "" {
		a.performed("build.dependencies.openBuildFile", surfaceButton)
		a.openFile(p, path)
	}
}

// buildFileOf is the build file of projectID (of the instance's root when it is empty): the
// first of the build system's detection markers found in its directory, or "" when none is.
// A model's project path is relative to the build root or absolute inside the workspace, and
// the build root is relative to the workspace.
func buildFileOf(p *project, instance *buildInstance, projectID string) string {
	directory := filepath.FromSlash(instance.Root)
	if project, ok := buildProjectByID(instance.Model, projectID); ok && project.Path != "" {
		if path := filepath.FromSlash(project.Path); filepath.IsAbs(path) {
			directory = path
		} else {
			directory = filepath.Join(directory, path)
		}
	}
	if !filepath.IsAbs(directory) {
		directory = filepath.Join(p.root, filepath.FromSlash(directory))
	}
	for _, marker := range buildMarkers(instance.Manifest, instance.BuildSystemID) {
		path := filepath.Join(directory, filepath.FromSlash(marker))
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

// buildMarkers reads the detection markers a build system declares in its manifest.
func buildMarkers(manifest json.RawMessage, buildSystemID string) []string {
	var declared struct {
		BuildSystems []struct {
			ID        string `json:"id"`
			Detection struct {
				Markers []string `json:"markers"`
			} `json:"detection"`
		} `json:"buildSystems"`
	}
	if json.Unmarshal(manifest, &declared) != nil {
		return nil
	}
	for _, system := range declared.BuildSystems {
		if system.ID == buildSystemID {
			return system.Detection.Markers
		}
	}
	return nil
}

// buildDependencyRows are the Dependencies section of the choices list: a heading, then the
// tree, or a line saying it loads, failed or is empty.
func (a *App) buildDependencyRows(p *project, instance *buildInstance) []buildRow {
	if !instance.modelLoaded {
		return nil
	}
	language := a.language()
	rows := []buildRow{{kind: buildRowSection, label: i18n.Shared(language, "native.dependencies")}}
	deps := a.dependenciesOf(p, instance)
	switch {
	case deps.loading:
		return append(rows, buildRow{kind: buildRowEmpty, dependencies: true, label: i18n.Shared(language, "native.loadingDependencies.variant2")})
	case deps.failed != "":
		return append(rows, buildRow{kind: buildRowEmpty, dependencies: true, label: i18n.Shared(language, "native.couldNotLoadDependencies") + ": " + deps.failed})
	case len(deps.tree.Dependencies) == 0:
		return append(rows, buildRow{kind: buildRowEmpty, dependencies: true, label: i18n.Shared(language, "native.noDependencies")})
	}
	for _, shown := range deps.shownRows() {
		rows = append(rows, buildRow{
			kind: buildRowDependency, label: dependencyLabel(shown.node), detail: shown.node.Scope,
			depth: shown.depth, path: shown.path, leaf: len(shown.node.Children) == 0,
		})
	}
	return rows
}

// buildDependencyRow declares one dependency: its opener, name and scope. A click opens or
// closes its children; a double click opens the project's build file.
func (a *App) buildDependencyRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c := row.C
	deps := a.dependenciesOf(p, instance)
	element := row.Element.Height(buildRowHeight).Items(ui.Center).Gap(4).
		PadSides(0, 8, 0, 8+float32(spec.depth)*14).Hover(ui.Look{}.Background(a.colors.Hover))
	open := deps.open[spec.path]
	if spec.leaf {
		ui.Row(c).Size(14, 14).Shrink(0)
	} else {
		icon := icons.ChevronRight
		if open {
			icon = icons.ChevronDown
		}
		ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
	}
	ui.Text(c, spec.label).Color(a.colors.Text).Ellipsis().Shrink(1)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	}
	ui.Spacer(c)
	switch {
	case element.DoubleClicked():
		c.After(func() { a.openBuildFile(p, instance) })
	case element.Clicked() && !spec.leaf:
		path := spec.path
		c.After(func() { deps.open[path] = !deps.open[path] })
	}
	a.buildDependencyMenu(c, element, p, instance)
}
