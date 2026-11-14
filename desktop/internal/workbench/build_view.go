package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	buildRowHeight     = 24
	buildOutputVisible = 200
)

// runView declares the Run tool window, which shows only what runs print: the console of what
// the Build window runs, beside the runs plugins started. The build systems, with their
// projects, targets and tasks, and the run configurations are the Build window's
// (build_tree_view.go).
func (a *App) runView(c ui.C, p *project) {
	ui.Column(c).Fill().Background(a.colors.Editor).Children(func() {
		a.runHeader(c, p)
		ui.Divider(c)
		if run := p.activeRun(); run != nil {
			a.runConsole(c, p, run)
			return
		}
		a.buildOutput(c, p)
	})
}

// runHeader declares the title row: the switcher between the build console and the runs
// plugins started, else the console's name, then the stop of the running build operation.
func (a *App) runHeader(c ui.C, p *project) {
	b, t := &p.build, a.text.Build
	ui.Row(c).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		if len(b.runs) == 0 {
			ui.Text(c, a.text.Run.Build).Color(a.colors.Text).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
		}
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

// showBuildConsole brings the Run window's build console forward, for an action of the Build
// window that prints there. A run a plugin starts switches to its own tab when it starts.
func (a *App) showBuildConsole(p *project) {
	p.build.view = ""
	a.openToolWindow(itemRun)
}

// buildRowKind says what a row of the build tree is.
type buildRowKind uint8

const (
	buildRowGroup buildRowKind = iota
	buildRowSection
	buildRowEmpty
	buildRowProject
	buildRowTarget
	buildRowTask
	buildRowDependency
	buildRowTest
)

// buildRow is one row of the build tree (build_tree.go): a build system's group, a section
// of it, a note that a section is empty or still loading, or something to choose or run.
type buildRow struct {
	kind     buildRowKind
	label    string
	detail   string
	selected bool
	// tooltip is what the row shows while the pointer rests on it: the full name of a target
	// whose label is its path alone (buildTargetLabel); empty for none.
	tooltip string
	// instance is the index of the build system the row belongs to, level its indentation in
	// the tree, and section the section a section row heads.
	instance int
	level    int
	section  string
	// count is what a section row shows beside its name, -1 for not known yet; open says a
	// group or a section shows its rows, and fixed that a filter keeps it open.
	count       int
	open, fixed bool
	// warning marks a row that tells of a failure, loading one of a model still loading.
	warning, loading bool
	// id is the project, target or task the row chooses; project is the project a
	// target belongs to.
	id, project string
	target      *core.BuildTarget
	// path and leaf place a dependency row in its tree (build_dependencies.go); dependencies
	// marks the line that stands for a tree still loading, failed or empty.
	path         string
	leaf         bool
	dependencies bool
	// tests marks a line of the Discovered Tests section that is not a test, and discover the
	// one that starts discovery; test is the discovered test a row runs (build_tests.go).
	tests    bool
	discover bool
	test     *core.BuildDiscoveredTest
}

// buildOutput declares the console of the build tasks: its header with the status of the last
// operation, then its lines.
func (a *App) buildOutput(c ui.C, p *project) {
	t := a.text.Build
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Clip().Children(func() {
		ui.Row(c).FillWidth().Height(buildRowHeight).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			ui.Text(c, t.Output).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Shrink(0)
			ui.Spacer(c)
			if status := p.build.status; status != "" {
				ui.Text(c, status).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			}
		})
		lines := buildVisibleOutput(p.build.output)
		if len(lines) == 0 {
			ui.Row(c).FillWidth().Grow(1).Items(ui.Center).PadX(shellContentPad).Children(func() {
				ui.Text(c, t.EmptyOutput).FontSize(small).Color(a.colors.Subtle).Ellipsis()
			})
			return
		}
		menu := &outputMenu{key: "buildoutput", all: func() string { return strings.Join(p.build.output, "") }}
		a.outputList(c, p, &p.panels.output, outputScopeRun, t.Output, lines, menu).Grow(1)
	})
}

// buildVisibleOutput splits what was printed into lines and keeps the last buildOutputVisible.
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

// declaredTasks are the tasks the manifest names itself, command and provider alike; a fromModel
// template is listed through the model tasks it stands for.
func declaredTasks(instance *buildInstance) []pluginservice.BuildTaskDeclaration {
	if instance == nil {
		return nil
	}
	tasks := make([]pluginservice.BuildTaskDeclaration, 0, len(instance.System.Tasks))
	for _, task := range instance.System.Tasks {
		if !task.FromModel {
			tasks = append(tasks, task)
		}
	}
	return tasks
}

// buildTaskDetail is what a task row shows beside its name: its category path, else its group.
func buildTaskDetail(task *pluginservice.BuildTaskDeclaration) string {
	if len(task.Category) != 0 {
		return strings.Join(task.Category, " / ")
	}
	return task.Group
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
