package workbench

import (
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The context menus of the Build tool window, with the items the earlier client's build tool
// window had: a task runs; a target runs each of the build system's runs that applies to it; a
// project opens its build file and has the model loaded again; the dependency tree is loaded
// again and opens the build file it came from. Each item acts through the action the window's
// own controls run, so a menu item and its button are refused in the same states.

// buildRowMenu is the menu of one project, target or task row of the choices list.
func (a *App) buildRowMenu(c ui.C, row ui.Box, p *project, instance *buildInstance, spec buildRow) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		b, lang := &p.build, a.language()
		menu.WidthRange(180, 280)
		switch spec.kind {
		case buildRowTask:
			if menu.Item(i18n.Shared(lang, "desktop.runConfig.run")).Disabled(b.operation != nil).Clicked() {
				c.After(func() {
					a.performed("build.task.run", surfaceMenu)
					b.taskID = spec.id
					a.runSelectedBuildTask(p)
				})
			}
		case buildRowTarget:
			for _, run := range instance.System.Runs {
				if !buildRunApplies(run, *spec.target) {
					continue
				}
				runID := run.ID
				if menu.Item(a.text.Build.RunTarget(run.Name)).Disabled(b.operation != nil || instance.modelLoading).Clicked() {
					c.After(func() {
						a.performed("build.target.run", surfaceMenu)
						b.projectID, b.targetID = spec.project, spec.id
						a.runBuildTarget(p, spec.id, runID)
					})
				}
			}
		case buildRowProject:
			if path := buildFileOf(p, instance, spec.id); path != "" {
				label := i18n.SharedFormat(lang, "native.open", map[string]string{"arg1": filepath.Base(path)})
				if menu.Item(label).Clicked() {
					c.After(func() {
						a.performed("build.project.openBuildFile", surfaceMenu)
						a.openFile(p, path)
					})
				}
			}
			index := b.selected
			if menu.Item(i18n.Shared(lang, "native.reload")).Disabled(instance.modelLoading || b.operation != nil).Clicked() {
				c.After(func() {
					a.performed("build.model.reload", surfaceMenu)
					a.reloadBuildModel(p, index)
				})
			}
		}
	})
}

// buildDependencyMenu is the menu of the dependency tree of the chosen project: of one of its
// rows, or of the line that stands for it while it loads, after it failed or when it is empty.
func (a *App) buildDependencyMenu(c ui.C, row ui.Box, p *project, instance *buildInstance) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		lang := a.language()
		menu.WidthRange(180, 280)
		deps := a.dependenciesOf(p, instance)
		projectID := p.build.projectID
		if menu.Item(i18n.Shared(lang, "native.reload")).Disabled(deps.loading).Clicked() {
			c.After(func() {
				a.performed("build.dependencies.reload", surfaceMenu)
				a.loadBuildDependencies(p, instance, projectID, deps, true)
			})
		}
		if path := buildFileOf(p, instance, projectID); path != "" {
			label := i18n.SharedFormat(lang, "native.open", map[string]string{"arg1": filepath.Base(path)})
			if menu.Item(label).Clicked() {
				c.After(func() {
					a.performed("build.dependencies.openBuildFile", surfaceMenu)
					a.openFile(p, path)
				})
			}
		}
	})
}
