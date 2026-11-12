package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	buildRowHeight     = 24
	buildOutputVisible = 200
	// buildOutputHeight is the height of the build console under the choices,
	// header included.
	buildOutputHeight = 110
)

// runView declares the provider-backed Run tool window: detected build systems,
// their projects, targets and tasks, bounded task output, and the runs plugins
// started.
func (a *App) runView(c ui.C, p *project) {
	b := &p.build
	if !b.loaded && !b.loading {
		a.loadBuildSystems(p)
	}
	t := a.text.Build
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.runHeader(c, p)
		ui.Divider(c)
		if run := p.activeRun(); run != nil {
			a.runConsole(c, p, run)
			return
		}
		if b.loading || !b.loaded {
			a.panelMessage(c, t.LoadingModel, a.colors.Subtle)
			return
		}
		if b.failed != "" {
			a.panelMessage(c, b.failed, a.colors.Warning)
			return
		}
		if len(b.instances) == 0 {
			a.panelMessage(c, t.NoBuildSystems, a.colors.Subtle)
			return
		}
		// The panes of the build systems are one, so the splitter under the run
		// configurations sizes the list against all of them.
		a.runConfigList(c, p)
		ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
			a.buildInstances(c, p)
			ui.Divider(c)
			a.buildChoices(c, p)
			ui.Divider(c)
			a.buildOutput(c, p)
		})
	})
}

// runHeader declares the title row: the switcher between the build console and
// the runs plugins started, then stop and refresh.
func (a *App) runHeader(c ui.C, p *project) {
	b, t := &p.build, a.text.Build
	ui.Row(c).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.Text(c, t.Systems).Color(a.colors.Text).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		a.runViews(c, p)
		ui.Spacer(c)
		if b.operation != nil {
			label := t.Stop
			if b.operation.cancelled {
				label = i18n.Shared(a.language(), "desktop.process.forceStop")
			}
			if ui.Button(c, label).Outline().Clicked() {
				a.stopBuildOperation(p)
			}
		}
		refresh := ui.Button(c, t.Refresh).Ghost().IconOnly().Icon(icons.RefreshCw).Tooltip(t.Refresh)
		if b.loading {
			refresh.Disabled(true)
		}
		if refresh.Clicked() {
			c.After(func() {
				b.generation++
				b.loading = false
				b.instances = nil
				b.loaded = false
				b.selected = 0
				a.loadBuildSystems(p)
			})
		}
	})
}

// runViews declares the switcher between the build console and the runs plugins
// started. It is empty until the first run.
func (a *App) runViews(c ui.C, p *project) {
	b := &p.build
	if len(b.runs) == 0 {
		return
	}
	views := make([]string, 0, len(b.runs)+1)
	views = append(views, "")
	for _, run := range b.runs {
		views = append(views, run.id)
	}
	if p.runEntry(b.view) == nil {
		b.view = ""
	}
	ui.Tabs(c, &b.view, views, func(id string) string {
		if id == "" {
			return a.text.Run.Build
		}
		return p.runEntry(id).label
	}).Shrink(0)
}

// buildInstances declares the build systems the workspace uses, one tab each.
func (a *App) buildInstances(c ui.C, p *project) {
	b, t := &p.build, a.text.Build
	panels := &p.panels
	ui.Row(c).FillWidth().Height(buildRowHeight + 8).Shrink(0).Items(ui.Center).Gap(4).PadX(8).Children(func() {
		indexes := make([]int, len(b.instances))
		for index := range indexes {
			indexes[index] = index
		}
		panels.instance = b.selected
		if len(b.instances) > 0 && ui.Button(c.Key("build-options"), i18n.Shared(a.language(), "desktop.build.options")).Ghost().Small().Clicked() {
			c.After(func() { a.openBuildOptions(p) })
		}
		ui.Tabs(c, &panels.instance, indexes, func(index int) string {
			instance := &b.instances[index]
			if instance.System.DisplayName != "" {
				return instance.System.DisplayName
			}
			return instance.BuildSystemID
		}).Shrink(1)
		if panels.instance != b.selected {
			a.selectBuildInstance(p, panels.instance)
		}
		ui.Spacer(c)
		ui.Text(c, t.Projects).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
}

// buildRowKind says what a row of the choices list is.
type buildRowKind uint8

const (
	buildRowSection buildRowKind = iota
	buildRowEmpty
	buildRowProject
	buildRowTarget
	buildRowTask
	buildRowDependency
	buildRowTest
)

// buildRow is one row of the choices list: a section heading, a note that the
// section is empty, or something to choose.
type buildRow struct {
	kind     buildRowKind
	label    string
	detail   string
	selected bool
	// id is the project, target or task the row chooses; project is the project a
	// target belongs to.
	id, project string
	target      *core.BuildTarget
	// depth, path and leaf place a dependency row in its tree (build_dependencies.go);
	// dependencies marks the line that stands for a tree still loading, failed or empty.
	depth        int
	path         string
	leaf         bool
	dependencies bool
	// tests marks a line of the Discovered Tests section that is not a test, and discover the
	// one that starts discovery; test is the discovered test a row runs (build_tests.go).
	tests    bool
	discover bool
	test     *core.BuildDiscoveredTest
}

// buildChoiceRows lists the sections of the selected build system with what is
// chosen in each, in the order the list shows them.
func (a *App) buildChoiceRows(p *project, instance *buildInstance) []buildRow {
	b, t := &p.build, a.text.Build
	model := &instance.Model
	rows := []buildRow{{kind: buildRowSection, label: t.Projects}}
	if len(model.Projects) == 0 {
		rows = append(rows, buildRow{kind: buildRowEmpty, label: t.NoProjects})
	}
	for _, project := range model.Projects {
		name := project.DisplayName
		if name == "" {
			name = project.Name
		}
		rows = append(rows, buildRow{kind: buildRowProject, label: name, detail: project.Path, id: project.ID, selected: b.projectID == project.ID})
	}
	rows = append(rows, a.buildDependencyRows(p, instance)...)
	rows = append(rows, buildRow{kind: buildRowSection, label: t.Targets})
	for index := range model.Targets {
		target := &model.Targets[index]
		if b.projectID != "" && target.ProjectID != b.projectID {
			continue
		}
		rows = append(rows, buildRow{kind: buildRowTarget, label: target.Name, detail: target.Path, id: target.ID, project: target.ProjectID, selected: b.targetID == target.ID, target: target})
	}
	rows = append(rows, buildRow{kind: buildRowSection, label: t.Tasks})
	declared := providerTasks(instance)
	if len(declared) == 0 && len(model.Tasks) == 0 {
		rows = append(rows, buildRow{kind: buildRowEmpty, label: t.NoTasks})
	}
	for _, task := range declared {
		rows = append(rows, buildRow{kind: buildRowTask, label: buildTaskName(&task), detail: task.Group, id: task.ID, selected: b.taskID == task.ID})
	}
	for _, task := range model.Tasks {
		name := task.DisplayName
		if name == "" {
			name = task.Name
		}
		rows = append(rows, buildRow{kind: buildRowTask, label: name, detail: strings.Join(task.Category, " / "), id: task.ID, selected: b.taskID == task.ID})
	}
	return append(rows, a.buildTestRows(p, instance)...)
}

// buildChoices declares the projects, targets and tasks of the selected build
// system and the button that runs the chosen task.
func (a *App) buildChoices(c ui.C, p *project) {
	b, t := &p.build, a.text.Build
	instance := p.selectedBuildInstance()
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Clip().Children(func() {
		if instance == nil {
			return
		}
		if instance.modelLoading && !instance.modelLoaded {
			a.panelMessage(c, t.LoadingModel, a.colors.Subtle)
			return
		}
		if instance.modelError != "" {
			a.panelMessage(c, t.ModelFailed(instance.modelError), a.colors.Warning)
			return
		}
		rows := a.buildChoiceRows(p, instance)
		list := &p.panels.choices
		list.Header = func(i int) bool { return rows[i].kind == buildRowSection }
		list.Label = func(i int) string { return rows[i].label }
		ui.List(c, list, len(rows), func(row ui.ListRow) {
			a.buildChoiceRow(row, p, instance, rows[row.Index])
		}).Label(t.Systems).FillWidth().Grow(1).PadY(4)
		ui.Divider(c)
		ui.Row(c).FillWidth().Height(36).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			if b.status != "" {
				ui.Text(c, b.status).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Grow(1)
			} else {
				ui.Spacer(c)
			}
			button := ui.Button(c, t.RunSelected)
			if b.operation != nil || b.taskID == "" {
				button.Disabled(true)
			}
			if button.Clicked() {
				a.runSelectedBuildTask(p)
			}
		})
	})
}

// buildChoiceRow declares one row of the choices list. Choosing a row changes
// which rows the list holds, so the change is made after the paint.
func (a *App) buildChoiceRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c, b, t := row.C, &p.build, a.text.Build
	small := a.theme.Metrics.FontSizeS
	if spec.kind == buildRowSection {
		row.Element.Height(buildRowHeight).PadX(8).Items(ui.Center).Background(a.colors.Editor)
		ui.Text(c, spec.label).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
		return
	}
	if spec.kind == buildRowEmpty && spec.tests {
		a.buildTestStatusRow(row, p, instance, spec)
		return
	}
	if spec.kind == buildRowTest {
		a.buildTestRow(row, p, instance, spec)
		return
	}
	if spec.kind == buildRowEmpty {
		row.Element.Height(buildRowHeight).PadX(16).Items(ui.Center)
		ui.Text(c, spec.label).FontSize(small).Color(a.colors.Subtle).Ellipsis()
		if spec.dependencies {
			a.buildDependencyMenu(c, row.Element, p, instance)
		}
		return
	}
	if spec.kind == buildRowDependency {
		a.buildDependencyRow(row, p, instance, spec)
		return
	}
	element := row.Element.Height(buildRowHeight).Items(ui.Center).Gap(6).PadX(8)
	if spec.selected {
		element.Background(a.colors.Active)
	} else {
		element.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	ui.Text(c, spec.label).Color(a.colors.Text).Ellipsis().Shrink(1).MaxWidth(240)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(small).Color(a.colors.Subtle).Ellipsis().Grow(1)
	} else {
		ui.Spacer(c)
	}
	if spec.kind == buildRowTarget {
		for _, run := range instance.System.Runs {
			if !buildRunApplies(run, *spec.target) {
				continue
			}
			button := ui.Button(c.Key(run.ID), t.RunTarget(run.Name)).Ghost().Small()
			if b.operation != nil || instance.modelLoading {
				button.Disabled(true)
			}
			if button.Clicked() {
				a.runBuildTarget(p, spec.id, run.ID)
			}
		}
		for _, entry := range buildTargetRunEntries(instance, spec.id) {
			button := ui.Button(c.Key("entry:"+entry.ID), t.RunTarget(entry.Name)).Ghost().Small()
			if b.operation != nil || instance.modelLoading {
				button.Disabled(true)
			}
			if button.Clicked() {
				a.runBuildEntry(p, entry.ID)
			}
		}
	}
	if element.Clicked() {
		c.After(func() {
			switch spec.kind {
			case buildRowProject:
				b.projectID, b.targetID, b.taskID = spec.id, "", ""
			case buildRowTarget:
				b.projectID, b.targetID = spec.project, spec.id
			case buildRowTask:
				b.taskID = spec.id
			}
		})
	}
	a.buildRowMenu(c, element, p, instance, spec)
}

// buildOutput declares the console of the build system under its choices.
func (a *App) buildOutput(c ui.C, p *project) {
	t := a.text.Build
	ui.Column(c).FillWidth().Height(buildOutputHeight).Shrink(0).Clip().Children(func() {
		ui.Row(c).FillWidth().Height(buildRowHeight).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
			ui.Text(c, t.Output).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
		})
		lines := buildVisibleOutput(p.build.output)
		if len(lines) == 0 {
			ui.Row(c).FillWidth().Grow(1).Items(ui.Center).PadX(shellContentPad).Children(func() {
				ui.Text(c, t.EmptyOutput).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
			return
		}
		menu := &outputMenu{key: "buildoutput", all: func() string { return strings.Join(p.build.output, "") }}
		a.outputList(c, p, &p.panels.output, outputScopeRun, t.Output, lines, menu).Grow(1)
	})
}

func buildVisibleOutput(chunks []string) []string {
	joined := strings.Join(chunks, "")
	if joined == "" {
		return nil
	}
	lines := strings.Split(joined, "\n")
	if len(lines) > buildOutputVisible {
		lines = lines[len(lines)-buildOutputVisible:]
	}
	return lines
}

func providerTasks(instance *buildInstance) []pluginservice.BuildTaskDeclaration {
	if instance == nil {
		return nil
	}
	tasks := make([]pluginservice.BuildTaskDeclaration, 0, len(instance.System.Tasks))
	for _, task := range instance.System.Tasks {
		if task.Source == "provider" && !task.FromModel {
			tasks = append(tasks, task)
		}
	}
	return tasks
}

func buildTaskName(task *pluginservice.BuildTaskDeclaration) string {
	if task.DisplayName != "" {
		return task.DisplayName
	}
	return task.ID
}

func buildRunApplies(run pluginservice.BuildRunDeclaration, target core.BuildTarget) bool {
	if len(run.Tags) == 0 {
		return true
	}
	for _, tag := range run.Tags {
		for _, targetTag := range target.Tags {
			if tag == targetTag {
				return true
			}
		}
	}
	return false
}

// runConsole declares one run: its controls, its output with the links the
// plugin's matchers found, and how it ended.
func (a *App) runConsole(c ui.C, p *project, run *runEntry) {
	t := a.text.Build
	ui.Column(c).Fill().Clip().Children(func() {
		ui.Row(c).FillWidth().Height(buildRowHeight + 8).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			ui.Text(c, run.label).Color(a.colors.Text).Ellipsis().Shrink(1)
			ui.Spacer(c)
			if run.running {
				if ui.Button(c, t.Stop).Outline().Clicked() {
					a.stopRun(p, run)
				}
			} else if run.rerun != nil {
				if ui.Button(c, a.text.Run.Rerun).Outline().Clicked() {
					a.rerunRun(p, run)
				}
			}
		})
		ui.Divider(c)
		a.runPerformanceChart(c, run)
		lines := buildVisibleOutput(run.output)
		if len(lines) == 0 {
			ui.Row(c).FillWidth().Grow(1).Items(ui.Center).PadX(shellContentPad).Children(func() {
				ui.Text(c, t.EmptyOutput).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		} else {
			menu := &outputMenu{
				key: "runsnapshot/" + run.id,
				all: func() string { return strings.Join(run.output, "") },
				extra: func(menu *ui.MenuItems) {
					if menu.Item(a.text.Run.Snapshot.Menu).Clicked() {
						c.After(func() { a.snapshotRunOutput(p, run) })
					}
				},
			}
			a.outputList(c, p, &run.list, outputScopeRun, t.Output, lines, menu).Grow(1)
		}
		if run.summary != "" {
			ui.Divider(c)
			ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
				ui.Text(c, run.summary).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		}
	})
}
