package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/ui"
)

// The Build tool window offers the test scopes the build system declares. A project row and a
// target row run their tests from the context menu, and a build system that discovers tests
// lists them under Discovered Tests, where one test runs on its own. Core plans discovery
// (build.testDiscoveryPlan), the plugin's provider answers lithe/build/discoverTests, and Core
// checks and bounds the list (build.decodeTestDiscovery). Every run is planned by Core's
// build.testPlan and shows in the Tests tool window (tests.go).

// buildTestDiscoveryKernel is the part of Core test discovery uses.
type buildTestDiscoveryKernel interface {
	PlanBuildTestDiscovery(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildPlanRequest) (core.BuildPlan, error)
	DecodeBuildTestDiscovery(ctx context.Context, manifest json.RawMessage, buildSystemID string, request core.BuildDecodeTestDiscoveryRequest) (core.BuildTestDiscovery, error)
}

// buildDiscoveredTests are the tests one build instance discovered. Discovery runs only when
// asked for, because it may compile the workspace.
type buildDiscoveredTests struct {
	loading bool
	loaded  bool
	failed  string
	tests   []core.BuildDiscoveredTest
	// generation rejects a discovery a reload replaced.
	generation uint64
}

// discoveredTestsOf is the discovery state of instance, created empty the first time.
func (p *project) discoveredTestsOf(instance *buildInstance) *buildDiscoveredTests {
	if p.build.discovered == nil {
		p.build.discovered = map[string]*buildDiscoveredTests{}
	}
	tests := p.build.discovered[instance.ID]
	if tests == nil {
		tests = &buildDiscoveredTests{}
		p.build.discovered[instance.ID] = tests
	}
	return tests
}

// discoveredTestsView is the discovery state of instance for drawing; an instance that never
// discovered reads as not loaded, without an entry.
func (p *project) discoveredTestsView(instance *buildInstance) buildDiscoveredTests {
	if tests := p.build.discovered[instance.ID]; tests != nil {
		return *tests
	}
	return buildDiscoveredTests{}
}

// revokeBuildTests forgets the tests the instance discovered: a reloaded model or a saved
// source file can rename, add or remove them, and a selector Core no longer recognizes would
// only fail when run. A discovery still running is dropped by its generation.
func (p *project) revokeBuildTests(instanceID string) {
	if tests := p.build.discovered[instanceID]; tests != nil {
		tests.generation++
		delete(p.build.discovered, instanceID)
	}
}

// revokeAllBuildTests forgets every discovered list, for a detection that replaced the
// instances.
func (p *project) revokeAllBuildTests() {
	for id := range p.build.discovered {
		p.revokeBuildTests(id)
	}
}

// buildTestDeclares reports whether the instance declares the test scope.
func buildTestDeclares(instance *buildInstance, scope string) bool {
	if instance == nil || instance.System.Test == nil {
		return false
	}
	for _, declared := range instance.System.Test.Scopes {
		if declared == scope {
			return true
		}
	}
	return false
}

// buildTargetTestable reports whether a target-scope run of target is offered. Core refuses a
// target without one of the declared tags (no tags accept every target); the window only
// leaves out the entry Core would refuse.
func buildTargetTestable(instance *buildInstance, target core.BuildTarget) bool {
	if !buildTestDeclares(instance, "target") {
		return false
	}
	tags := instance.System.Test.TargetTags
	if len(tags) == 0 {
		return true
	}
	for _, tag := range tags {
		for _, targetTag := range target.Tags {
			if tag == targetTag {
				return true
			}
		}
	}
	return false
}

// buildProjectSelection is the selection of a model project in a test request.
func buildProjectSelection(project core.BuildProject) *core.BuildSelection {
	return &core.BuildSelection{Name: project.Name, Path: project.Path, Properties: project.Properties}
}

// runBuildProjectTests runs the tests of one model project.
func (a *App) runBuildProjectTests(p *project, instance *buildInstance, projectID string) {
	project, ok := buildProjectByID(instance.Model, projectID)
	if !ok {
		a.notifyError(a.text.Build.ProjectMissing)
		return
	}
	a.startBuildTests(p, testSelection{
		instanceID: instance.ID,
		project:    buildProjectSelection(project),
		projects:   buildModelProjectPaths(instance.Model),
	})
}

// runBuildTargetTests runs the tests of one target with the project it belongs to, which Core
// requires beside a target.
func (a *App) runBuildTargetTests(p *project, instance *buildInstance, targetID string) {
	target, ok := buildTargetByID(instance.Model, targetID)
	if !ok {
		a.notifyError(a.text.Build.TargetMissing)
		return
	}
	project, ok := buildProjectByID(instance.Model, target.ProjectID)
	if !ok {
		a.notifyError(a.text.Build.ProjectMissing)
		return
	}
	a.startBuildTests(p, testSelection{
		instanceID: instance.ID,
		project:    buildProjectSelection(project),
		target:     &core.BuildSelection{Name: target.Name, Path: target.Path, Tags: target.Tags, Properties: target.Properties},
		projects:   buildModelProjectPaths(instance.Model),
	})
}

// runDiscoveredTest runs one discovered test with the selectors discovery returned, unchanged.
func (a *App) runDiscoveredTest(p *project, instance *buildInstance, test core.BuildDiscoveredTest) {
	a.startBuildTests(p, testSelection{
		instanceID: instance.ID,
		project:    test.Project,
		target:     test.Target,
		suite:      test.Suite,
		caseName:   test.Case,
		projects:   buildModelProjectPaths(instance.Model),
	})
}

// startBuildTests opens the Tests tool window and starts the run there.
func (a *App) startBuildTests(p *project, selection testSelection) {
	if p.tests.running {
		return
	}
	if !a.chrome.isOpen(catalogIndex[itemTests]) {
		a.reduceChrome(core.ToggleChrome(itemTests))
	}
	a.startTests(p, selection)
}

// discoverBuildTests asks the instance's provider for its tests off the window thread.
func (a *App) discoverBuildTests(p *project, instance *buildInstance, refresh bool) {
	kernel, ok := a.kernel.(buildTestDiscoveryKernel)
	if !ok || instance.System.Test == nil || !instance.System.Test.Discovery {
		return
	}
	tests := p.discoveredTestsOf(instance)
	if tests.loading {
		return
	}
	tests.loading, tests.failed = true, ""
	tests.generation++
	generation := tests.generation
	captured := *instance
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		discovery, err := a.buildTestDiscovery(ctx, p, captured, kernel, refresh)
		return func(a *App) {
			if tests.generation != generation {
				return
			}
			tests.loading = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("build_test_discovery", err))
				tests.failed = err.Error()
				return
			}
			tests.loaded = true
			tests.tests = discovery.Tests
		}
	})
}

// buildTestDiscovery plans, sends and decodes one discovery request.
func (a *App) buildTestDiscovery(ctx context.Context, p *project, instance buildInstance, kernel buildTestDiscoveryKernel, refresh bool) (core.BuildTestDiscovery, error) {
	execution, err := a.resolveBuildExecutable(ctx, p, instance, a.text.Build)
	if err != nil {
		return core.BuildTestDiscovery{}, err
	}
	request := core.BuildPlanRequest{Root: instance.Root, Options: instance.Options, WorkspaceRoot: p.root, Refresh: refresh}
	if execution.Executable != "" {
		request.Tool = &core.BuildTool{Executable: execution.Executable, Environment: execution.Environment}
	}
	plan, err := kernel.PlanBuildTestDiscovery(ctx, instance.Manifest, instance.BuildSystemID, request)
	if err != nil {
		return core.BuildTestDiscovery{}, err
	}
	if plan.Provider == nil {
		return core.BuildTestDiscovery{}, errors.New(a.text.Build.CommandUnsupported)
	}
	client, err := a.buildProvider(ctx, p, instance)
	if err != nil {
		return core.BuildTestDiscovery{}, err
	}
	operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
	if err != nil {
		return core.BuildTestDiscovery{}, err
	}
	result, err := operation.Wait(ctx)
	if err != nil {
		return core.BuildTestDiscovery{}, err
	}
	return kernel.DecodeBuildTestDiscovery(ctx, instance.Manifest, instance.BuildSystemID, core.BuildDecodeTestDiscoveryRequest{
		Root:    instance.Root,
		Options: instance.Options,
		Result:  result,
	})
}

// discoveredTestLabel names a discovered test by the selectors that tell it apart.
func discoveredTestLabel(test core.BuildDiscoveredTest) string {
	parts := make([]string, 0, 3)
	if test.Target != nil && test.Target.Name != "" {
		parts = append(parts, test.Target.Name)
	}
	for _, part := range []string{test.Suite, test.Case} {
		if part != "" {
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, " · ")
}

// buildScopedTests are the discovered tests of the project scope of instance (every test when
// scope is empty) whose name or project holds query, already lower case (every test when it is
// empty).
func buildScopedTests(instance *buildInstance, tests []core.BuildDiscoveredTest, scope, query string) []*core.BuildDiscoveredTest {
	chosen := ""
	if project, ok := buildProjectByID(instance.Model, scope); ok {
		chosen = project.Path
	}
	var scoped []*core.BuildDiscoveredTest
	for index := range tests {
		test := &tests[index]
		detail := ""
		if test.Project != nil {
			if chosen != "" && test.Project.Path != chosen {
				continue
			}
			detail = test.Project.Path
		}
		if query == "" || buildMatches(query, discoveredTestLabel(*test), detail) {
			scoped = append(scoped, test)
		}
	}
	return scoped
}

// buildTestRows are the rows of a Discovered Tests section of the build tree, at level, for the
// instance at index: the tests of scope (of every project when it is empty), or a line that
// discovers them, says discovery runs, failed or found nothing. With a query, only the tests
// already discovered that match it, and no line.
func (a *App) buildTestRows(p *project, index int, scope, query string, level int) []buildRow {
	instance := &p.build.instances[index]
	language := a.language()
	tests := p.discoveredTestsView(instance)
	status := func(label string, discover, warning bool) buildRow {
		return buildRow{kind: buildRowEmpty, tests: true, discover: discover, warning: warning, instance: index, level: level, label: label}
	}
	switch {
	case query != "" && (tests.loading || !tests.loaded):
		return nil
	case tests.loading:
		return []buildRow{status(i18n.Shared(language, "native.discovering"), false, false)}
	case tests.failed != "":
		return []buildRow{
			status(a.text.Build.TestDiscoveryFailed(tests.failed), false, true),
			status(i18n.Shared(language, "native.discoverTests"), true, false),
		}
	case !tests.loaded:
		return []buildRow{status(i18n.Shared(language, "native.discoverTests"), true, false)}
	}
	scoped := buildScopedTests(instance, tests.tests, scope, query)
	if len(scoped) == 0 {
		if query != "" {
			return nil
		}
		return []buildRow{status(i18n.Shared(language, "native.noTestsDiscovered"), false, false)}
	}
	rows := make([]buildRow, 0, len(scoped))
	for _, test := range scoped {
		detail := ""
		if test.Project != nil {
			detail = test.Project.Path
		}
		rows = append(rows, buildRow{kind: buildRowTest, instance: index, level: level, label: discoveredTestLabel(*test), detail: detail, id: test.ID, test: test})
	}
	return rows
}

// buildTestStatusRow declares a line of the Discovered Tests section that is not a test. The
// line that offers discovery starts it when clicked.
func (a *App) buildTestStatusRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c := row.C
	element := a.buildTreeRowElement(row, spec)
	ui.Row(c.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
	color := a.colors.Subtle
	switch {
	case spec.warning:
		color = a.colors.Warning
	case spec.discover:
		color = a.colors.Accent
		ui.Icon(c, icons.Search).Size(14, 14).Shrink(0).Color(color)
		if element.Clicked() {
			c.After(func() {
				a.performed("build.tests.discover", surfaceButton)
				a.discoverBuildTests(p, instance, false)
			})
		}
	}
	ui.Text(c, spec.label).FontSize(treeFontSize - 1).Color(color).Ellipsis().Shrink(1).MinWidth(0)
	a.buildTestsMenu(c, element, p, instance)
}

// buildTestRow declares one discovered test: its icon, name and project, and the button that
// runs it alone. A double click runs it too.
func (a *App) buildTestRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c := row.C
	element := a.buildTreeRowElement(row, spec)
	ui.Row(c.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
	ui.Icon(c, icons.CircleCheck).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
	ui.Text(c, spec.label).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Ellipsis().Shrink(1).MinWidth(0)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
	}
	ui.Spacer(c)
	test := *spec.test
	label := i18n.Shared(a.language(), "native.runTests")
	if a.gitIconButton(c.Part("run"), label, icons.Play, false, p.tests.running) || (element.DoubleClicked() && !p.tests.running) {
		c.After(func() {
			a.performed("build.tests.runCase", surfaceButton)
			a.runDiscoveredTest(p, instance, test)
		})
	}
	ui.ContextMenu(c, element, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		if menu.Item(label).Disabled(p.tests.running).Clicked() {
			c.After(func() {
				a.performed("build.tests.runCase", surfaceMenu)
				a.runDiscoveredTest(p, instance, test)
			})
		}
		a.buildTestsMenuItems(c, menu, p, instance)
	})
}

// buildTestsMenu is the menu of the Discovered Tests status lines.
func (a *App) buildTestsMenu(c ui.C, row ui.Box, p *project, instance *buildInstance) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		a.buildTestsMenuItems(c, menu, p, instance)
	})
}

// buildTestsMenuItems are the items every Discovered Tests line shares.
func (a *App) buildTestsMenuItems(c ui.C, menu *ui.MenuItems, p *project, instance *buildInstance) {
	tests := p.discoveredTestsView(instance)
	if menu.Item(i18n.Shared(a.language(), "native.refreshDiscoveredTests")).Disabled(tests.loading).Clicked() {
		c.After(func() {
			a.performed("build.tests.refresh", surfaceMenu)
			a.discoverBuildTests(p, instance, true)
		})
	}
}
