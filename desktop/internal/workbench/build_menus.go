package workbench

import (
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The context menus of the Build tool window, with the items the earlier client's build tool
// window had: a task runs; a target runs each of the build system's runs that applies to it; a
// project opens its build file and has the model loaded again; a project or target whose
// build system declares that test scope runs its tests in the Tests tool window; the
// dependency tree is loaded again and opens the build file it came from. Each item acts
// through the action the window's own controls run, so a menu item and its button are refused
// in the same states. An item of a row of another build system's group selects that build
// system first, as a click on the row does, and what a task or a run prints shows in the Run
// window's build console.

// buildRowMenu is the menu of one project, target or task row of the build tree.
func (a *App) buildRowMenu(c ui.C, row ui.Box, p *project, instance *buildInstance, spec buildRow) {
	node := spec.node
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		b, lang := &p.build, a.language()
		menu.WidthRange(180, 280)
		index := spec.instance
		// choose selects what the row stands for, as a click on it does.
		choose := func() {
			a.chooseBuildInstance(p, index)
			b.projectID, b.targetID, b.taskID = node.ProjectID, node.TargetID, node.TaskID
		}
		switch spec.kind {
		case buildRowTask:
			if menu.Item(i18n.Shared(lang, "desktop.runConfig.run")).Disabled(b.operation != nil).Clicked() {
				c.After(func() {
					a.performed("build.task.run", surfaceContextMenu)
					choose()
					a.runSelectedBuildTask(p)
					a.showBuildConsole(p)
				})
			}
		case buildRowTarget:
			if spec.target == nil {
				return
			}
			targetID := node.TargetID
			for _, run := range instance.System.Runs {
				if !buildRunApplies(run, *spec.target) {
					continue
				}
				runID := run.ID
				if menu.Item(a.text.Build.RunTarget(run.ActionName(spec.target.Name))).Disabled(instance.modelLoading).Clicked() {
					c.After(func() {
						a.performed("build.target.run", surfaceContextMenu)
						choose()
						a.runBuildTarget(p, targetID, runID)
						a.showBuildConsole(p)
					})
				}
				// The same target under the debugger, when the run declares how: an adapter of its
				// own plugin starts the program the provider prepares, or the registered adapter of
				// its public type attaches to the service the provider starts.
				if run.Debuggable() && menu.Item(i18n.Shared(lang, "desktop.build.debugTarget")).Disabled(instance.modelLoading || p.debug.preparing).Clicked() {
					c.After(func() {
						a.performed("build.target.debug", surfaceContextMenu)
						choose()
						a.debugBuildTarget(p, targetID, runID)
					})
				}
			}
			for _, entry := range buildTargetRunEntries(instance, targetID) {
				entryID := entry.ID
				if menu.Item(a.text.Build.RunTarget(entry.Name)).Disabled(instance.modelLoading).Clicked() {
					c.After(func() {
						a.performed("build.target.run", surfaceContextMenu)
						choose()
						a.runBuildEntry(p, entryID)
						a.showBuildConsole(p)
					})
				}
			}
			if buildTargetTestable(instance, *spec.target) {
				if menu.Item(i18n.Shared(lang, "native.runTests")).Disabled(p.tests.running || instance.modelLoading).Clicked() {
					c.After(func() {
						a.performed("build.target.test", surfaceContextMenu)
						choose()
						a.runBuildTargetTests(p, instance, targetID)
					})
				}
			}
		case buildRowProject:
			a.buildProjectMenuItems(c, menu, p, instance, index, node.ProjectID)
			if menu.Item(i18n.Shared(lang, "native.reload")).Disabled(instance.modelLoading || b.operation != nil).Clicked() {
				c.After(func() {
					a.performed("build.model.reload", surfaceContextMenu)
					a.reloadBuildModel(p, index)
				})
			}
		}
	})
}

// buildProjectMenuItems are the items of a project's menu, on its row or on the group row that
// stands for it: run its tests, when its build system declares the project test scope, and open
// its build file.
func (a *App) buildProjectMenuItems(c ui.C, menu *ui.MenuItems, p *project, instance *buildInstance, index int, projectID string) {
	lang := a.language()
	if buildTestDeclares(instance, "project") {
		if menu.Item(i18n.Shared(lang, "native.runTests")).Disabled(p.tests.running || instance.modelLoading).Clicked() {
			c.After(func() {
				a.performed("build.project.test", surfaceContextMenu)
				a.chooseBuildInstance(p, index)
				a.runBuildProjectTests(p, instance, projectID)
			})
		}
	}
	if path := buildFileOf(p, instance, projectID); path != "" {
		label := i18n.SharedFormat(lang, "native.open", map[string]string{"arg1": filepath.Base(path)})
		if menu.Item(label).Clicked() {
			c.After(func() {
				a.performed("build.project.openBuildFile", surfaceContextMenu)
				a.openFile(p, path)
			})
		}
	}
}

// buildDependencyMenu is the menu of the dependency tree of the chosen project: of one of its
// rows, or of the line that stands for it while it loads, after it failed or when it is empty.
func (a *App) buildDependencyMenu(c ui.C, row ui.Box, p *project, instance *buildInstance, projectID string) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		lang := a.language()
		menu.WidthRange(180, 280)
		deps := a.dependenciesOf(p, instance, projectID)
		if menu.Item(i18n.Shared(lang, "native.reload")).Disabled(deps.loading).Clicked() {
			c.After(func() {
				a.performed("build.dependencies.reload", surfaceContextMenu)
				a.loadBuildDependencies(p, instance, projectID, deps, true)
			})
		}
		if path := buildFileOf(p, instance, projectID); path != "" {
			label := i18n.SharedFormat(lang, "native.open", map[string]string{"arg1": filepath.Base(path)})
			if menu.Item(label).Clicked() {
				c.After(func() {
					a.performed("build.dependencies.openBuildFile", surfaceContextMenu)
					a.openFile(p, path)
				})
			}
		}
	})
}
