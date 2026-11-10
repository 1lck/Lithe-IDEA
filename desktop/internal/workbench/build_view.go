package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	buildRefreshID = tree.ID(shellPage, "build-refresh")
	buildRunTaskID = tree.ID(shellPage, "build-run-task")
	buildStopID    = tree.ID(shellPage, "build-stop")
	buildListID    = tree.ID(shellPage, "build-list")
	buildOutputID  = tree.ID(shellPage, "build-output")
	runOutputID    = tree.ID(shellPage, "run-output")
	runStopID      = tree.ID(shellPage, "run-stop")
	runRerunID     = tree.ID(shellPage, "run-rerun")
	runViews       = tree.Sub(shellPage, tree.Name("run-view"))

	buildInstances  = tree.Sub(shellPage, tree.Name("build-instance"))
	buildProjects   = tree.Sub(shellPage, tree.Name("build-project"))
	buildTargets    = tree.Sub(shellPage, tree.Name("build-target"))
	buildTasks      = tree.Sub(shellPage, tree.Name("build-task"))
	buildRunTargets = tree.Sub(shellPage, tree.Name("build-run-target"))
)

const (
	buildRowHeight     = 24
	buildOutputVisible = 200
)

// drawBuildPanel declares the provider-backed Build tool window: detected
// build systems, their projects, targets and tasks, and bounded task output.
func (a *App) drawBuildPanel(f *ui.Frame, p *project) {
	if p == nil {
		return
	}
	b := &p.build
	if !b.loaded && !b.loading {
		a.loadBuildSystems(p)
	}
	t := a.text.Build
	f.Column().Fill().Background(a.colors.Editor).Children(func() {
		f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			f.Text(t.Systems).Color(a.colors.Text).Weight(gfx.WeightMedium).Ellipsis().Shrink(1)
			a.drawRunViews(f, p)
			f.Spacer()
			if b.operation != nil {
				if f.Button(buildStopID, t.Stop).Outline().Clicked() {
					a.stopBuildOperation(p)
				}
			}
			if a.logIconButton(f, buildRefreshID, t.Refresh, icons.RefreshCw, false, b.loading) {
				b.generation++
				b.loading = false
				b.instances = nil
				b.loaded = false
				b.selected = 0
				a.loadBuildSystems(p)
			}
		})
		f.Divider()
		if run := p.activeRun(); run != nil {
			a.drawRunConsole(f, p, run)
			return
		}
		if b.loading || !b.loaded {
			a.logEmpty(f, t.LoadingModel)
			return
		}
		if b.failed != "" {
			f.Column().Fill().Center().PadX(shellContentPad).Children(func() {
				f.Paragraph(b.failed, 4).TextCenter().Color(a.colors.Warning)
			})
			return
		}
		if len(b.instances) == 0 {
			a.logEmpty(f, t.NoBuildSystems)
			return
		}
		a.drawBuildInstances(f, p).Shrink(0)
		f.Divider()
		a.drawBuildChoices(f, p).Grow(1)
		f.Divider()
		a.drawBuildOutput(f, p).Height(110).Shrink(0)
	})
}

func (a *App) drawBuildInstances(f *ui.Frame, p *project) ui.Box {
	b, t := &p.build, a.text.Build
	return f.Row().Height(buildRowHeight + 8).Shrink(0).Items(ui.Center).Gap(4).PadX(8).Children(func() {
		for index := range b.instances {
			instance := &b.instances[index]
			label := instance.System.DisplayName
			if label == "" {
				label = instance.BuildSystemID
			}
			row := f.Row().Height(buildRowHeight).Shrink(0).Items(ui.Center).PadX(8).
				HitWith(buildInstances.At(index), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
			if index == b.selected {
				row = row.Background(a.colors.Active)
			} else {
				row = row.Hover(ui.Look{}.Background(a.colors.Hover))
			}
			row.Children(func() {
				f.Text(label).Color(a.colors.Text).Ellipsis().MaxWidth(180)
			})
			if row.Clicked() {
				a.selectBuildInstance(p, index)
			}
		}
		f.Spacer()
		f.Text(t.Projects).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
	})
}

func (a *App) drawBuildChoices(f *ui.Frame, p *project) ui.Box {
	b, t := &p.build, a.text.Build
	instance := p.selectedBuildInstance()
	return f.Column().FillWidth().Clip().Children(func() {
		if instance == nil {
			return
		}
		if instance.modelLoading && !instance.modelLoaded {
			a.logEmpty(f, t.LoadingModel)
			return
		}
		if instance.modelError != "" {
			f.Column().Fill().Center().PadX(shellContentPad).Children(func() {
				f.Paragraph(t.ModelFailed(instance.modelError), 4).TextCenter().Color(a.colors.Warning)
			})
			return
		}
		model := &instance.Model
		f.ScrollArea(buildListID).Grow(1).PadY(4).Children(func() {
			a.drawBuildSection(f, t.Projects)
			if len(model.Projects) == 0 {
				a.drawBuildEmptyRow(f, t.NoProjects)
			}
			for index, project := range model.Projects {
				name := project.DisplayName
				if name == "" {
					name = project.Name
				}
				selected := b.projectID == project.ID
				row := buildChoiceRow(f, a, buildProjects.At(index), name, project.Path, selected)
				if row.Clicked() {
					b.projectID, b.targetID, b.taskID = project.ID, "", ""
				}
			}

			a.drawBuildSection(f, t.Targets)
			for index, target := range model.Targets {
				if b.projectID != "" && target.ProjectID != b.projectID {
					continue
				}
				selected := b.targetID == target.ID
				row := buildChoiceRow(f, a, buildTargets.At(index), target.Name, target.Path, selected)
				if row.Clicked() {
					b.projectID, b.targetID = target.ProjectID, target.ID
				}
				for runIndex, run := range instance.System.Runs {
					if !buildRunApplies(run, target) {
						continue
					}
					button := f.Button(buildRunTargets.At(index*len(instance.System.Runs)+runIndex), t.RunTarget(run.Name)).Ghost()
					if b.operation != nil || instance.modelLoading {
						button = button.Disabled(true)
					}
					if button.Clicked() {
						a.runBuildTarget(p, target.ID, run.ID)
					}
				}
			}

			a.drawBuildSection(f, t.Tasks)
			declared := providerTasks(instance)
			if len(declared) == 0 && len(model.Tasks) == 0 {
				a.drawBuildEmptyRow(f, t.NoTasks)
			}
			for index, task := range declared {
				selected := b.taskID == task.ID
				row := buildChoiceRow(f, a, buildTasks.At(index), buildTaskName(&task), task.Group, selected)
				if row.Clicked() {
					b.taskID = task.ID
				}
			}
			for index, task := range model.Tasks {
				selected := b.taskID == task.ID
				name := task.DisplayName
				if name == "" {
					name = task.Name
				}
				row := buildChoiceRow(f, a, buildTasks.At(len(declared)+index), name, strings.Join(task.Category, " / "), selected)
				if row.Clicked() {
					b.taskID = task.ID
				}
			}
		})
		f.Divider()
		f.Row().Height(36).Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			if b.status != "" {
				f.Text(b.status).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Grow(1)
			} else {
				f.Spacer()
			}
			button := f.Button(buildRunTaskID, t.RunSelected).Disabled(b.operation != nil || b.taskID == "")
			if button.Clicked() {
				a.runSelectedBuildTask(p)
			}
		})
	})
}

func (a *App) drawBuildSection(f *ui.Frame, label string) {
	f.Row().Height(buildRowHeight).FillWidth().Shrink(0).Items(ui.Center).PadX(8).Children(func() {
		f.Text(label).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
	})
}

func (a *App) drawBuildEmptyRow(f *ui.Frame, label string) {
	f.Row().Height(buildRowHeight).FillWidth().Shrink(0).Items(ui.Center).PadX(16).Children(func() {
		f.Text(label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
	})
}

func buildChoiceRow(f *ui.Frame, a *App, id gfx.ID, name, detail string, selected bool) ui.Box {
	row := f.Row().Height(buildRowHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(6).PadX(8).
		HitWith(id, name, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
	if selected {
		row = row.Background(a.colors.Active)
	} else {
		row = row.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	row.Children(func() {
		f.Text(name).Color(a.colors.Text).Ellipsis().Shrink(1).MaxWidth(240)
		if detail != "" {
			f.Text(detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Grow(1)
		}
	})
	return row
}

func (a *App) drawBuildOutput(f *ui.Frame, p *project) ui.Box {
	t := a.text.Build
	return f.Column().FillWidth().Clip().Children(func() {
		f.Row().Height(buildRowHeight).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
			f.Text(t.Output).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
		})
		lines := buildVisibleOutput(p.build.output)
		if len(lines) == 0 {
			f.Row().Grow(1).Items(ui.Center).PadX(shellContentPad).Children(func() {
				f.Text(t.EmptyOutput).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
			return
		}
		f.ScrollArea(buildOutputID).Grow(1).PadX(8).Children(func() {
			a.drawLinkedOutput(f, p, outputScopeRun, buildOutputLinks, lines)
		})
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

// drawRunViews declares the switcher between the build console and the runs
// plugins started. It is empty until the first run.
func (a *App) drawRunViews(f *ui.Frame, p *project) {
	b := &p.build
	if len(b.runs) == 0 {
		return
	}
	choose := func(index int, id, label string) {
		row := f.Row().Height(buildRowHeight).Shrink(0).Items(ui.Center).PadX(8).
			HitWith(runViews.At(index), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
		if b.view == id {
			row = row.Background(a.colors.Active)
		} else {
			row = row.Hover(ui.Look{}.Background(a.colors.Hover))
		}
		row.Children(func() {
			f.Text(label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis().MaxWidth(160)
		})
		if row.Clicked() {
			b.view = id
		}
	}
	choose(0, "", a.text.Run.Build)
	for index, run := range b.runs {
		choose(index+1, run.id, run.label)
	}
}

// drawRunConsole declares one run: its controls, its output with the links the
// plugin's matchers found, and how it ended.
func (a *App) drawRunConsole(f *ui.Frame, p *project, run *runEntry) {
	t := a.text.Build
	f.Column().Fill().Clip().Children(func() {
		f.Row().Height(buildRowHeight + 8).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
			f.Text(run.label).Color(a.colors.Text).Ellipsis().Shrink(1)
			f.Spacer()
			if run.running {
				if f.Button(runStopID, t.Stop).Outline().Clicked() {
					a.stopRun(p, run)
				}
			} else if run.rerun != nil {
				if f.Button(runRerunID, a.text.Run.Rerun).Outline().Clicked() {
					a.rerunRun(p, run)
				}
			}
		})
		f.Divider()
		lines := buildVisibleOutput(run.output)
		if len(lines) == 0 {
			f.Row().Grow(1).Items(ui.Center).PadX(shellContentPad).Children(func() {
				f.Text(t.EmptyOutput).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		} else {
			f.ScrollArea(runOutputID).Grow(1).PadX(8).Children(func() {
				a.drawLinkedOutput(f, p, outputScopeRun, runOutputLinks, lines)
			})
		}
		if run.summary != "" {
			f.Divider()
			f.Row().Height(28).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
				f.Text(run.summary).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			})
		}
	})
}
