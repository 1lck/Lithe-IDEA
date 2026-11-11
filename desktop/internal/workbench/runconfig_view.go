package workbench

import (
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// runConfigList declares the run configurations over the build systems: a header with the
// scope picker, the configurations of the scope under the build system that provides them,
// and the splitter that sizes the list against the panes under it. It shows once Core resolved
// at least one configuration; a failure without one is a line of its own.
func (a *App) runConfigList(c ui.C, p *project) {
	s := &p.runConfigs
	b := &s.browser
	language, small := a.language(), a.theme.Metrics.FontSizeS
	if len(s.list) == 0 {
		if s.failure != "" {
			ui.Row(c.Part("run-config")).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).PadX(8).Children(func() {
				ui.Text(c, i18n.SharedFormat(language, "desktop.runConfig.loadFailed", map[string]string{"reason": s.failure})).
					FontSize(small).Color(a.colors.Warning).Ellipsis().Grow(1)
			})
			ui.Divider(c)
		}
		return
	}
	if b.split.Pos == 0 {
		b.split.Pos = runConfigListHeight
	}
	scopes := s.scopes()
	if !slices.Contains(scopes, b.scope) {
		b.scope = ""
	}
	title := i18n.Shared(language, "native.runConfigurations")
	ui.Column(c.Part("run-configs")).FillWidth().Height(b.split.Pos).Shrink(0).Clip().Children(func() {
		ui.Row(c).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
			ui.Text(c, title).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Shrink(0)
			ui.Select(c.Part("scope"), &b.scope, scopes, func(scope string) string { return a.runScopeLabel(s, scope) }).
				Label(title).Shrink(1).MinWidth(0).MaxWidth(240)
			ui.Spacer(c)
		})
		a.drawRunConfigRows(c, p, title)
	})
	ui.Splitter(c, &b.split).Mins(runConfigListMin, runConfigRestMin).Label(a.text.Panel.Resize)
}

// drawRunConfigRows declares the rows of the scope. Selecting a row keeps it selected; Enter
// or a double click runs a configuration, when nothing runs and its build model has loaded,
// and on a group opens or closes it.
func (a *App) drawRunConfigRows(c ui.C, p *project, title string) {
	s := &p.runConfigs
	b := &s.browser
	p.collectRunConfigRows()
	if len(b.rows) == 0 {
		a.gitEmpty(c, i18n.Shared(a.language(), "native.noConfigurationsInThisScope"))
		return
	}
	if b.view.Key == nil {
		// A configuration keeps its row's state by its index in the resolved list, and a
		// group by its place among the groups.
		b.view.Key = func(i int) int {
			if row := b.rows[i]; row.configuration >= 0 {
				return 2 * row.configuration
			}
			return 2*b.rows[i].group + 1
		}
		b.view.Label = func(i int) string {
			if row := b.rows[i]; row.configuration >= 0 {
				return s.list[row.configuration].Name
			}
			return b.groups[b.rows[i].group].title
		}
	}
	selected := p.selectedRunConfigRow()
	if !b.view.Changed() && b.view.Selected() != selected {
		b.view.Select(selected)
	}
	ui.List(c, &b.view, len(b.rows), func(row ui.ListRow) { a.drawRunConfigRow(p, row, row.Index == selected) }).Label(title).Grow(1).FillWidth()
	if b.view.Changed() {
		if i := b.view.Selected(); i >= 0 && i < len(b.rows) {
			if row := b.rows[i]; row.configuration >= 0 {
				s.selected, b.group = s.list[row.configuration].ID, ""
			} else {
				b.group = b.groups[row.group].key
			}
		}
	}
	if i, ok := b.view.Submitted(); ok && i >= 0 && i < len(b.rows) {
		row := b.rows[i]
		if row.configuration < 0 {
			key := b.groups[row.group].key
			c.After(func() { s.toggleRunConfigGroup(key) })
		} else if configuration := s.list[row.configuration]; p.build.operation == nil && p.runConfigurationReady(configuration) {
			c.After(func() { a.runConfiguration(p, configuration.ID) })
		}
	}
}

// drawRunConfigRow declares one row: a group's arrow, title and count, or a configuration's
// kind, name and pin with the button that runs it or stops its run, and the context menu of
// its actions.
func (a *App) drawRunConfigRow(p *project, row ui.ListRow, selected bool) {
	s := &p.runConfigs
	b := &s.browser
	c, r, small := row.C, b.rows[row.Index], a.theme.Metrics.FontSizeS
	box := row.Element.Height(buildRowHeight).Items(ui.Center).Gap(6).PadX(6).Radius(a.theme.Metrics.RadiusItem())
	if selected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	if r.configuration < 0 {
		group := b.groups[r.group]
		box.Children(func() {
			a.drawRunConfigGroupArrow(c, s, group)
			ui.Text(c, group.title).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			ui.Text(c, strconv.Itoa(len(group.configurations))).FontSize(small).Color(a.colors.Subtle).Shrink(0)
		})
		return
	}
	configuration := s.list[r.configuration]
	running := p.runningConfiguration() == configuration.ID
	a.runConfigMenu(c, box, p, configuration, running)
	box.Children(func() {
		ui.Row(c.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
		ui.Icon(c, runExecutionIcon(configuration.Execution)).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, configuration.Name).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		if b.pins[configuration.ID] {
			ui.Icon(c, icons.Pin).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
		}
		ui.Spacer(c)
		language := a.language()
		if running {
			ui.Text(c, i18n.Shared(language, "native.running")).FontSize(small).Color(a.colors.Subtle).Shrink(0)
			if a.gitIconButton(c.Part("stop"), i18n.Shared(language, "native.stopRun.variant2"), icons.Square, false, false) {
				c.After(func() { a.stopBuildOperation(p) })
			}
			return
		}
		disabled := p.build.operation != nil || !p.runConfigurationReady(configuration)
		if a.gitIconButton(c.Part("run"), i18n.Shared(language, "desktop.runConfig.run"), icons.Play, false, disabled) {
			c.After(func() { a.runConfiguration(p, configuration.ID) })
		}
	})
}

// drawRunConfigGroupArrow declares the arrow that opens or closes a group of the list.
func (a *App) drawRunConfigGroupArrow(c ui.C, s *runConfigState, group runConfigGroup) {
	open := !s.browser.closed[group.key]
	name, chevron := i18n.Shared(a.language(), "native.collapseSection"), icons.ChevronDown
	if !open {
		name, chevron = i18n.Shared(a.language(), "native.expandSection"), icons.ChevronRight
	}
	k := c.Part("arrow")
	slot := ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center().
		HitWith(ui.ID(k), name+" "+group.title, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(k, chevron).Size(12, 12).Color(a.colors.Subtle)
	})
	if slot.Clicked() {
		key := group.key
		c.After(func() { s.toggleRunConfigGroup(key) })
	}
}

// runConfigMenu declares the context menu of a configuration's row: run it or stop its run,
// edit its saved options, and pin or unpin it.
func (a *App) runConfigMenu(c ui.C, row ui.Box, p *project, configuration core.RunConfiguration, running bool) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		language, id := a.language(), configuration.ID
		menu.WidthRange(180, 280)
		if running {
			if menu.Item(i18n.Shared(language, "native.stopRun.variant2")).Clicked() {
				c.After(func() { a.stopBuildOperation(p) })
			}
		} else if menu.Item(i18n.Shared(language, "desktop.runConfig.run")).Disabled(p.build.operation != nil || !p.runConfigurationReady(configuration)).Clicked() {
			c.After(func() { a.runConfiguration(p, id) })
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "native.editConfiguration")).Clicked() {
			c.After(func() {
				a.performed("run.configuration.edit", surfaceMenu)
				a.openRunConfigEditor(p, id)
			})
		}
		pin, action := i18n.Shared(language, "native.pinConfiguration"), "run.configuration.pin"
		if p.runConfigs.browser.pins[id] {
			pin, action = i18n.Shared(language, "native.unpinConfiguration"), "run.configuration.unpin"
		}
		if menu.Item(pin).Clicked() {
			c.After(func() {
				a.performed(action, surfaceMenu)
				a.toggleRunConfigPin(p, id)
			})
		}
	})
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
				for index := range e.optionFields {
					a.drawRunOptionField(c.Part("option-"+strconv.Itoa(index)), language, &e.optionFields[index], ready)
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

// drawRunOptionField declares one declared option: a checkbox, a picker, a text field or a list of
// checkboxes by its kind. A kind the editor cannot edit shows its stored JSON read-only.
func (a *App) drawRunOptionField(c ui.C, language i18n.Language, field *runOptionField, ready bool) {
	switch field.kind {
	case "boolean":
		ui.Checkbox(c, &field.flag, field.title).Disabled(!ready)
	case "singleSelect":
		values, labels := runOptionChoiceIDs(*field)
		ui.Select(c, &field.text, values, func(value string) string {
			if value == "" {
				return i18n.Shared(language, "desktop.runConfig.optionDefault")
			}
			return labels[value]
		}).Label(field.title).FillWidth().Disabled(!ready)
	case "text", "file", "directory":
		ui.TextField(c, &field.text, field.title, "").FillWidth().Disabled(!ready)
	case "multiSelect":
		ui.Text(c, field.title).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		for index := range field.choices {
			ui.Checkbox(c.KeyInt(index), &field.picks[index], field.choices[index].title).Disabled(!ready)
		}
	default:
		text := field.title + ": " + i18n.Shared(language, "desktop.runConfig.optionReadOnly")
		if field.raw != nil {
			text = field.title + ": " + string(field.raw)
		}
		ui.Wrap(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	}
}
