package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// runConfigBar declares the row above the build systems that picks a run configuration
// and runs it. It shows only once Core resolved at least one, or failed to.
func (a *App) runConfigBar(c ui.C, p *project) {
	s := &p.runConfigs
	if len(s.list) == 0 && s.failure == "" {
		return
	}
	language := a.language()
	label := i18n.Shared(language, "desktop.runConfig.label")
	ui.Row(c.Part("run-config")).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		if s.failure != "" && len(s.list) == 0 {
			ui.Text(c, i18n.SharedFormat(language, "desktop.runConfig.loadFailed", map[string]string{"reason": s.failure})).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis().Grow(1)
			return
		}
		ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		ids := make([]string, len(s.list))
		for i := range s.list {
			ids[i] = s.list[i].ID
		}
		ui.Select(c.Part("choice"), &s.selected, ids, func(id string) string {
			if configuration := s.configuration(id); configuration != nil {
				return configuration.Name
			}
			return id
		}).Label(label).Grow(1).Shrink(1).MinWidth(0).MaxWidth(360)
		run := ui.Button(c.Part("run"), i18n.Shared(language, "desktop.runConfig.run")).Icon(icons.Play).Small()
		if p.build.operation != nil || s.selected == "" {
			run.Disabled(true)
		}
		if run.Clicked() {
			id := s.selected
			c.After(func() { a.runConfiguration(p, id) })
		}
		edit := ui.Button(c.Part("edit"), i18n.Shared(language, "desktop.runConfig.edit")).Icon(icons.Pencil).Small().Outline()
		if s.selected == "" {
			edit.Disabled(true)
		}
		if edit.Clicked() {
			id := s.selected
			c.After(func() { a.openRunConfigEditor(p, id) })
		}
		ui.Spacer(c)
	})
	ui.Divider(c)
}

// drawRunConfigEditor declares the open run configuration editor: arguments, working
// directory, environment and the layer file the edit is saved into.
func (a *App) drawRunConfigEditor(c ui.C, p *project) {
	e := &p.runConfigs.editor
	if !e.open {
		return
	}
	language := a.language()
	ready := !e.loading && !e.saving
	open := true
	title := i18n.SharedFormat(language, "desktop.runConfig.editTitle", map[string]string{"name": e.name})
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 460}, func() {
		ui.Column(c.Part("run-config-editor")).FillWidth().Gap(10).Children(func() {
			ui.TextField(c.Part("arguments"), &e.arguments, i18n.Shared(language, "desktop.runConfig.arguments"), i18n.Shared(language, "desktop.runConfig.argumentsPlaceholder")).
				FillWidth().Disabled(!ready)
			ui.TextField(c.Part("directory"), &e.directory, i18n.Shared(language, "desktop.runConfig.workingDirectory"), i18n.Shared(language, "desktop.runConfig.workingDirectoryPlaceholder")).
				FillWidth().Disabled(!ready)
			ui.TextArea(c.Part("environment"), &e.environment, i18n.Shared(language, "desktop.runConfig.environment"), i18n.Shared(language, "desktop.runConfig.environmentPlaceholder")).
				FillWidth().Height(96).Disabled(!ready)
			if e.provider {
				ui.TextArea(c.Part("runtime-arguments"), &e.runtimeArguments, i18n.Shared(language, "desktop.runConfig.runtimeArguments"), i18n.Shared(language, "desktop.runConfig.runtimeArgumentsPlaceholder")).
					FillWidth().Height(72).Disabled(!ready)
				ui.TextField(c.Part("entrypoint"), &e.entrypoint, i18n.Shared(language, "desktop.runConfig.entrypoint"), i18n.Shared(language, "desktop.runConfig.entrypointPlaceholder")).
					FillWidth().Disabled(!ready)
				if len(e.installs) > 0 {
					labels := []string{i18n.Shared(language, "desktop.runConfig.toolPickNone")}
					for _, install := range e.installs {
						labels = append(labels, install.toolName+": "+install.path+" "+install.version)
					}
					ui.Select(c.Part("tool-pick"), &e.pick, indexRange(len(labels)), func(index int) string { return labels[index] }).
						Label(i18n.Shared(language, "desktop.runConfig.toolPick")).FillWidth().Disabled(!ready)
					if e.pick > 0 && e.pick <= len(e.installs) {
						e.pickRunConfigInstall(e.installs[e.pick-1])
					}
					e.pick = 0
				}
				for index := range e.tools {
					tool := &e.tools[index]
					label := i18n.SharedFormat(language, "desktop.runConfig.toolPath", map[string]string{"arg1": tool.id, "arg2": tool.kind})
					ui.TextField(c.Part("tool-"+strconv.Itoa(index)), &tool.path, label, i18n.Shared(language, "desktop.runConfig.toolPathPlaceholder")).
						FillWidth().Disabled(!ready)
				}
			}
			labels := map[string]string{"local": i18n.Shared(language, "desktop.runConfig.scopeLocal"), "project": i18n.Shared(language, "desktop.runConfig.scopeProject")}
			ui.Select(c.Part("scope"), &e.scope, []string{"local", "project"}, func(scope string) string { return labels[scope] }).
				Label(i18n.Shared(language, "desktop.runConfig.scope")).FillWidth()
			if e.failure != "" {
				ui.Paragraph(c, e.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
			c.After(func() { a.closeRunConfigEditor(p) })
		}
		if ui.Button(c, i18n.Shared(language, "ui.save")).Disabled(!ready).Clicked() {
			c.After(func() { a.saveRunConfigEditor(p) })
		}
	})
	if closed {
		c.After(func() { a.closeRunConfigEditor(p) })
	}
}

// indexRange is the list 0..n-1, the options of an index picker.
func indexRange(n int) []int {
	values := make([]int, n)
	for i := range values {
		values[i] = i
	}
	return values
}
