package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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

// buildTestRows are the Discovered Tests section of the choices list: a heading, then the tests
// of the chosen project (of every project when none is chosen), or a line that discovers them,
// says discovery runs, failed or found nothing.
func (a *App) buildTestRows(p *project, instance *buildInstance) []buildRow {
	if !instance.modelLoaded || instance.System.Test == nil || !instance.System.Test.Discovery {
		return nil
	}
	language := a.language()
	rows := []buildRow{{kind: buildRowSection, label: i18n.Shared(language, "native.discoveredTests")}}
	tests := p.discoveredTestsView(instance)
	switch {
	case tests.loading:
		return append(rows, buildRow{kind: buildRowEmpty, tests: true, label: i18n.Shared(language, "native.discovering")})
	case tests.failed != "":
		return append(rows,
			buildRow{kind: buildRowEmpty, tests: true, label: a.text.Build.TestDiscoveryFailed(tests.failed)},
			buildRow{kind: buildRowEmpty, tests: true, discover: true, label: i18n.Shared(language, "native.discoverTests")})
	case !tests.loaded:
		return append(rows, buildRow{kind: buildRowEmpty, tests: true, discover: true, label: i18n.Shared(language, "native.discoverTests")})
	case len(tests.tests) == 0:
		return append(rows, buildRow{kind: buildRowEmpty, tests: true, label: i18n.Shared(language, "native.noTestsDiscovered")})
	}
	chosen := ""
	if project, ok := buildProjectByID(instance.Model, p.build.projectID); ok {
		chosen = project.Path
	}
	for index := range tests.tests {
		test := &tests.tests[index]
		detail := ""
		if test.Project != nil {
			if chosen != "" && test.Project.Path != chosen {
				continue
			}
			detail = test.Project.Path
		}
		rows = append(rows, buildRow{kind: buildRowTest, label: discoveredTestLabel(*test), detail: detail, id: test.ID, test: test})
	}
	return rows
}

// buildTestStatusRow declares a line of the Discovered Tests section that is not a test. The
// line that offers discovery starts it when clicked.
func (a *App) buildTestStatusRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c := row.C
	element := row.Element.Height(buildRowHeight).PadX(16).Items(ui.Center)
	color := a.colors.Subtle
	if spec.discover {
		color = a.colors.Accent
		element.Hover(ui.Look{}.Background(a.colors.Hover))
		if element.Clicked() {
			c.After(func() {
				a.performed("build.tests.discover", surfaceButton)
				a.discoverBuildTests(p, instance, false)
			})
		}
	}
	ui.Text(c, spec.label).FontSize(a.theme.Metrics.FontSizeS).Color(color).Ellipsis()
	a.buildTestsMenu(c, element, p, instance)
}

// buildTestRow declares one discovered test. A double click or its button runs it alone.
func (a *App) buildTestRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c := row.C
	small := a.theme.Metrics.FontSizeS
	element := row.Element.Height(buildRowHeight).Items(ui.Center).Gap(6).PadX(16).Hover(ui.Look{}.Background(a.colors.Hover))
	ui.Text(c, spec.label).Color(a.colors.Text).Ellipsis().Shrink(1)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(small).Color(a.colors.Subtle).Ellipsis().Grow(1)
	} else {
		ui.Spacer(c)
	}
	test := *spec.test
	button := ui.Button(c, i18n.Shared(a.language(), "native.runTests")).Ghost().Small().Disabled(p.tests.running)
	if button.Clicked() || (element.DoubleClicked() && !p.tests.running) {
		c.After(func() {
			a.performed("build.tests.runCase", surfaceButton)
			a.runDiscoveredTest(p, instance, test)
		})
	}
	ui.ContextMenu(c, element, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		if menu.Item(i18n.Shared(a.language(), "native.runTests")).Disabled(p.tests.running).Clicked() {
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
