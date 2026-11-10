package workbench

import (
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// sidebarRow is one row of the generator list: a section heading or an entry.
type sidebarRow struct {
	header bool
	title  string
	key    string
	id     int
}

// sidebarRows lists the entries the search shows, under their section headings.
func (n *newProjectState) sidebarRows(language i18n.Language) []sidebarRow {
	var rows []sidebarRow
	for _, section := range []string{"project", "generator"} {
		start := len(rows)
		for index, choice := range n.choices {
			if choice.section != section || (n.visible != nil && !n.visible[choice.key]) {
				continue
			}
			rows = append(rows, sidebarRow{title: choice.name, key: choice.key, id: index + 1})
		}
		if len(rows) > start {
			title := i18n.Shared(language, "desktop.newProject.section")
			if section == "generator" {
				title = i18n.Shared(language, "desktop.newProject.generators")
			}
			rows = slices.Insert(rows, start, sidebarRow{header: true, title: title, id: -len(rows) - 1})
		}
	}
	return rows
}

// collectNewProject declares the page's background work and applies what it
// finished. It runs at the start of every paint of the page.
func (a *App) collectNewProject(c ui.C) {
	n := &a.newProject
	if n.busy {
		return
	}
	revision := strconv.Itoa(n.revision)
	n.catalogFx.declare(c, revision, struct{}{})
	if result, err, ok := n.catalogFx.take(); ok {
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_catalog", documentLogError(err)))
		}
		if result.plugins != nil {
			n.applyCatalog(a, result)
		} else {
			n.catalogFailed = true
		}
	}
	a.collectNewProjectSearch(c)
	if n.created == "" {
		key := n.parent + "\x00" + n.name
		n.checkFx.declare(c, key, checkRequest{key: key, parent: n.parent, name: n.name})
		if result, err, ok := n.checkFx.take(); ok && err == nil {
			n.check, n.checked = result, true
		}
	}
	form := n.form()
	if form == nil {
		return
	}
	if ids := form.toolIDs(); len(ids) == 0 {
		if !form.toolsLoaded {
			form.setTools(nil, false)
		}
	} else {
		n.toolsFx.declare(c, form.key+"#"+revision, ids)
		if tools, err, ok := n.toolsFx.take(); ok {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_tools", documentLogError(err)))
			}
			form.setTools(tools, err != nil)
		}
	}
	if !form.toolsLoaded {
		return
	}
	input := form.input(n.name)
	key := requestKey(form.key, input)
	form.currentKey = key
	n.formFx.declare(c, key, formRequest{manifest: form.plugin.Manifest, generatorID: form.entry.Generator.ID, input: input})
	if result, err, ok := n.formFx.take(); ok {
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_form", documentLogError(err)))
		} else {
			form.apply(result)
			form.formKey = key
		}
	}
}

// collectNewProjectSearch ranks the entries by the search text in Core.
func (a *App) collectNewProjectSearch(c ui.C) {
	n := &a.newProject
	query := strings.TrimSpace(n.search)
	if query == "" {
		n.visible = nil
		return
	}
	if len(query) > 4096 {
		n.visible = map[string]bool{}
		return
	}
	candidates := make([]core.RankCandidate, len(n.choices))
	keys := make([]string, len(n.choices))
	for index, choice := range n.choices {
		candidates[index] = core.RankCandidate{Name: choice.name}
		keys[index] = choice.key
	}
	key := query + "\x00" + strings.Join(keys, "\x01")
	n.searchFx.declare(c, key, searchRequest{query: query, candidates: candidates})
	if indices, err, ok := n.searchFx.take(); ok {
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_search", documentLogError(err)))
			n.visible = nil
			return
		}
		n.visible = make(map[string]bool, len(indices))
		for _, index := range indices {
			if index >= 0 && index < len(keys) {
				n.visible[keys[index]] = true
			}
		}
	}
}

// newProjectModal declares the New Project dialog while it is open: the generator list on
// the left, the selected entry's form on the right and the actions below.
func (a *App) newProjectModal(c ui.C) {
	n := &a.newProject
	if !n.open {
		return
	}
	a.collectNewProject(c)
	language := a.language()
	divider, sidebar := gfx.RGB24(0xD9DADF), gfx.RGB24(0xECECEE)
	if a.colors.Dark {
		divider, sidebar = gfx.RGB24(0x333438), gfx.RGB24(0x232427)
	}
	open := true
	ui.ModalWith(c, &open, i18n.Shared(language, "desktop.newProject.title"), ui.ModalSpec{Width: 880, Height: 660}, func() {
		ui.Row(c).Fill().Children(func() {
			a.newProjectSidebar(c, language, sidebar, divider)
			ui.Column(c).Width(1).FillHeight().Shrink(0).Background(divider)
			a.newProjectContent(c, language)
		})
	}, func() {
		a.newProjectFooter(c, language)
	})
	if !open {
		// Escape, the scrim and the close button end the dialog like Cancel: a running
		// creation is asked to stop first.
		c.After(a.cancelNewProject)
	}
}

func (a *App) newProjectSidebar(c ui.C, language i18n.Language, background, divider gfx.Color) {
	n := &a.newProject
	ui.Column(c).Width(240).FillHeight().Shrink(0).
		Background(background).Children(func() {
		ui.Column(c).FillWidth().Grow(1).PadSides(10, 12, 0, 12).Gap(12).Children(func() {
			search := i18n.Shared(language, "search.search")
			field := ui.TextField(c, &n.search, search, search).Icon(icons.Search).Action(icons.X, i18n.Shared(language, "native.clearSearch")).AutoFocus()
			if field.ActionClicked() {
				n.search = ""
				a.performed("workspace.search.clear", surfaceButton)
			}
			rows := n.sidebarRows(language)
			n.list.Key = func(i int) int { return rows[i].id }
			n.list.Label = func(i int) string { return rows[i].title }
			n.list.Header = func(i int) bool { return rows[i].header }
			ui.List(c, &n.list, len(rows), func(row ui.ListRow) {
				entry := rows[row.Index]
				if entry.header {
					row.Element.FillWidth().Height(24).Items(ui.Center).PadX(10).Children(func() {
						ui.Text(row.C, entry.title).FontSize(12).Muted()
					})
					return
				}
				selected := entry.key == n.choice
				element := row.Element.FillWidth().Height(26).Items(ui.Center).Gap(8).PadX(10).Radius(4)
				if selected {
					background := gfx.RGB24(0xE4E6EA)
					if a.colors.Dark {
						background = gfx.RGB24(0x303137)
					}
					element.Background(background)
				}
				element.Children(func() {
					ui.Icon(row.C, icons.Folder).Size(15, 15).Color(a.colors.Subtle)
					ui.Text(row.C, entry.title)
				})
			}).Label(i18n.Shared(language, "desktop.newProject.title")).Grow(1).FillWidth()
			if n.list.Changed() {
				if i := n.list.Selected(); i >= 0 && i < len(rows) && !rows[i].header && rows[i].key != n.choice {
					n.choice, n.err = rows[i].key, ""
				}
			} else if i := slices.IndexFunc(rows, func(row sidebarRow) bool { return !row.header && row.key == n.choice }); i >= 0 && n.list.Selected() != i {
				n.list.Select(i)
			}
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(divider)
		ui.Row(c).FillWidth().Height(40).Shrink(0).Items(ui.Center).PadX(14).Children(func() {
			label := i18n.Shared(language, "native.getMoreLanguagesAndFrameworksFromPlugins")
			if ui.Button(c, label).Ghost().FontSize(12).Color(a.colors.Accent).Clicked() {
				a.openPluginSettings(surfaceButton)
			}
		})
	})
}

func (a *App) newProjectContent(c ui.C, language i18n.Language) {
	n := &a.newProject
	choice := n.current()
	ui.Column(c).Grow(1).FillHeight().PadSides(20, 24, 0, 24).Gap(12).Children(func() {
		description := i18n.Shared(language, "desktop.newProject.description")
		if choice != nil && choice.entry != nil {
			// The generator's own words, as its plugin declared them.
			description = choice.entry.Generator.Description
		}
		if description != "" {
			ui.Text(c, description).FontSize(12.5).Muted()
		}
		if n.busy {
			a.newProjectProgress(c, language)
			return
		}
		ui.Scroll(c).FillWidth().Grow(1).Gap(12).Children(func() {
			a.newProjectFields(c, language, choice)
		})
	})
}

func (a *App) newProjectFields(c ui.C, language i18n.Language, choice *projectChoice) {
	n := &a.newProject
	locked := n.created != ""
	labelled := func(label string, control func()) {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(12).Children(func() {
			ui.Text(c, label).Width(120).Shrink(0)
			control()
		})
	}
	nameLabel := i18n.Shared(language, "desktop.newProject.name")
	locationLabel := i18n.Shared(language, "desktop.newProject.location")
	labelled(nameLabel, func() {
		name := ui.TextField(c, &n.name, nameLabel, "").Grow(1).MaxWidth(360)
		if locked {
			name.Disabled(true)
		}
		if name.Submitted() {
			a.submitNewProject()
		}
	})
	labelled(locationLabel, func() {
		field := ui.TextField(c, &n.parent, locationLabel, "").Grow(1)
		if locked {
			field.Disabled(true)
		}
		if ui.Button(c, i18n.Shared(language, "desktop.newProject.choose")).Icon(icons.Folder).IconOnly().Ghost().Disabled(locked).Clicked() {
			a.chooseNewProjectParent()
		}
	})
	ui.Row(c).FillWidth().PadSides(0, 0, 0, 132).Children(func() {
		ui.Text(c, i18n.SharedFormat(language, "desktop.newProject.pathPreview", map[string]string{"path": filepath.Join(n.parent, n.name)})).Muted()
	})
	if n.checked && n.check.key == n.parent+"\x00"+n.name && n.check.problem != "" && !locked {
		ui.Row(c).FillWidth().PadSides(0, 0, 0, 132).Children(func() {
			ui.Paragraph(c, a.checkProblemMessage(language, n.check.problem), 3).Color(a.theme.Danger)
		})
	}
	if choice != nil && choice.entry != nil {
		if form := n.form(); form != nil {
			a.generatorFields(c, language, form, locked)
		}
	}
	ui.Row(c).FillWidth().Items(ui.Center).PadSides(0, 0, 0, 132).Children(func() {
		git := ui.Checkbox(c, &n.git, i18n.Shared(language, "desktop.newProject.git"))
		if locked {
			git.Disabled(true)
		}
	})
	if n.err != "" {
		ui.Paragraph(c, n.err, 6).FillWidth().Color(a.theme.Danger)
	}
	if n.progress != nil {
		if _, _, lines := n.progress.snapshot(); len(lines) > 0 {
			a.projectOutput(c, language, lines)
		}
	}
}

// generatorFields draws the fields a generator declared, in order. Core decides
// which are visible and what is wrong with each value; the window only draws.
func (a *App) generatorFields(c ui.C, language i18n.Language, form *generatorForm, locked bool) {
	n := &a.newProject
	if form.form == nil {
		ui.Text(c, i18n.Shared(language, "native.loading")).Muted()
		return
	}
	if form.toolsFailed {
		ui.Paragraph(c, i18n.Shared(language, "desktop.newProject.toolsFailed"), 3).Color(a.theme.Danger)
	}
	a.requirementNotices(c, language, form)
	advanced := 0
	for _, field := range form.fields {
		if field.state.Visible && field.decl.Advanced {
			advanced++
		}
	}
	for _, field := range form.fields {
		if field.state.Visible && !field.decl.Advanced {
			a.generatorField(c, language, form, field, locked)
		}
	}
	if advanced > 0 {
		title := i18n.Shared(language, "desktop.newProject.advanced")
		if ui.Button(c, title).Ghost().Icon(icons.ChevronRight).Clicked() {
			n.advancedOpen = !n.advancedOpen
		}
		if n.advancedOpen {
			for _, field := range form.fields {
				if field.state.Visible && field.decl.Advanced {
					a.generatorField(c, language, form, field, locked)
				}
			}
		}
	}
	if form.entry.UsesNetwork {
		ui.Text(c, i18n.Shared(language, "desktop.newProject.usesNetwork")).FontSize(12).Muted()
	}
}

// generatorField draws one field by its declared type.
func (a *App) generatorField(c ui.C, language i18n.Language, form *generatorForm, field *formField, locked bool) {
	decl := field.decl
	ui.Column(c.Part("field")).FillWidth().Gap(4).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(12).Children(func() {
			if decl.Type == fieldBoolean {
				// A checkbox carries its own label; keep it in the controls' column.
				ui.Row(c).Width(120).Shrink(0)
			} else {
				label := ui.Text(c, decl.Title).Width(120).Shrink(0)
				if decl.Description != "" {
					label.Tooltip(decl.Description)
				}
			}
			if locked {
				ui.Text(c, field.canonical()).Muted()
				return
			}
			switch decl.Type {
			case fieldText:
				ui.TextField(c, &field.text, decl.Title, decl.Placeholder).Grow(1).MaxWidth(360)
			case fieldEnum:
				titleOf := func(value string) string { return field.titles[value] }
				if decl.Presentation == "segmented" {
					ui.Choice(c, &field.text, field.values, titleOf)
				} else {
					ui.Select(c, &field.text, field.values, titleOf).Width(240)
				}
			case fieldBoolean:
				ui.Checkbox(c, &field.flag, decl.Title)
			case fieldMultiSelect:
				a.multiSelectField(c, field)
			case fieldRuntime, fieldTool:
				a.installationField(c, language, form, field)
			}
		})
		if problem := field.state.Problem; problem != "" && field.state.Visible {
			ui.Row(c).FillWidth().PadSides(0, 0, 0, 132).Children(func() {
				ui.Paragraph(c, fieldProblemMessage(language, problem), 3).Color(a.theme.Danger).FontSize(12)
			})
		}
	})
}

// multiSelectField lists the options as checkboxes under their group headings.
func (a *App) multiSelectField(c ui.C, field *formField) {
	ui.Column(c).Grow(1).Gap(4).Children(func() {
		group := ""
		for _, option := range field.decl.Options {
			if option.Group != "" && option.Group != group {
				group = option.Group
				ui.Text(c, group).FontSize(12).Muted()
			}
			ui.Checkbox(c, field.chosen[option.Value], option.Title)
		}
	})
}

// installationField is the picker of a tool or runtime field. A tool field's
// choices and their version verdicts come from Core; a runtime field lists what
// discovery found.
func (a *App) installationField(c ui.C, language i18n.Language, form *generatorForm, field *formField) {
	type choice struct{ home, label string }
	var choices []choice
	switch field.decl.Type {
	case fieldTool:
		for _, installation := range field.state.Installations {
			label := installation.Version + "  " + installation.Home
			if !installation.MeetsMinimum {
				label += "  (" + i18n.Shared(language, "desktop.newProject.tooOld") + ")"
			}
			choices = append(choices, choice{installation.Home, label})
		}
	default:
		for _, installation := range form.tools[field.toolID()].Installations {
			choices = append(choices, choice{installation.Home, installation.Version + "  " + installation.Home})
		}
	}
	if len(choices) == 0 {
		ui.Text(c, i18n.Shared(language, "desktop.newProject.noInstallation")).Muted()
		return
	}
	homes := make([]string, 0, len(choices)+1)
	labels := make(map[string]string, len(choices)+1)
	if field.decl.Optional {
		homes = append(homes, "")
		labels[""] = i18n.Shared(language, "desktop.newProject.none")
	}
	for _, option := range choices {
		homes = append(homes, option.home)
		labels[option.home] = option.label
	}
	ui.Select(c, &field.text, homes, func(home string) string { return labels[home] }).Grow(1).MaxWidth(360)
}

// requirementNotices says which plugins the generator needs and offers to turn
// one on or look for it. A requirement never blocks creating the project.
func (a *App) requirementNotices(c ui.C, language i18n.Language, form *generatorForm) {
	var missing []core.ProjectGeneratorRequirement
	for _, index := range form.form.ActiveRequirements {
		if index < 0 || index >= len(form.entry.Requirements) {
			continue
		}
		requirement := form.entry.Requirements[index]
		if !slices.ContainsFunc(requirement.Providers, func(p core.ProjectGeneratorProvider) bool { return p.Enabled }) {
			missing = append(missing, requirement)
		}
	}
	for _, requirement := range missing {
		name := requirement.LanguageID + requirement.BuildSystemID
		var disabled *core.ProjectGeneratorProvider
		for index := range requirement.Providers {
			if !requirement.Providers[index].Enabled {
				disabled = &requirement.Providers[index]
				break
			}
		}
		ui.Row(c.Key(name)).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			if disabled != nil {
				ui.Text(c, i18n.SharedFormat(language, "desktop.newProject.requiresPlugin", map[string]string{"name": disabled.PluginName})).Grow(1)
				if ui.Button(c, i18n.Shared(language, "desktop.marketplace.enable")).Outline().Clicked() {
					a.setPluginEnabled(disabled.PluginID, true)
					a.newProject.revision++
				}
				return
			}
			ui.Text(c, i18n.SharedFormat(language, "desktop.newProject.requiresPlugin", map[string]string{"name": name})).Grow(1)
			if ui.Button(c, i18n.Shared(language, "desktop.newProject.findPlugin")).Outline().Clicked() {
				a.openPluginSettings(surfaceButton)
			}
		})
	}
}

// newProjectProgress shows a running generation: its step, its output, and a way to stop it.
func (a *App) newProjectProgress(c ui.C, language i18n.Language) {
	n := &a.newProject
	step, steps, lines := 0, 0, []string(nil)
	if n.progress != nil {
		step, steps, lines = n.progress.snapshot()
	}
	fraction := float32(0)
	if steps > 0 {
		fraction = float32(step-1) / float32(steps)
	}
	ui.Text(c, i18n.Shared(language, "desktop.newProject.creating")).Bold()
	if steps > 0 {
		ui.Text(c, i18n.SharedFormat(language, "desktop.newProject.stepProgress", map[string]string{"step": strconv.Itoa(step), "total": strconv.Itoa(steps)})).Muted()
	}
	ui.Progress(c, fraction).FillWidth()
	a.projectOutput(c, language, lines)
}

// projectOutput shows the last lines a command wrote.
func (a *App) projectOutput(c ui.C, language i18n.Language, lines []string) {
	const shown = 12
	if len(lines) > shown {
		lines = lines[len(lines)-shown:]
	}
	ui.Text(c, i18n.Shared(language, "desktop.newProject.output")).FontSize(12).Muted()
	ui.Column(c).FillWidth().Gap(2).Children(func() {
		for index, line := range lines {
			ui.Text(c.KeyInt(index), line).Mono().FontSize(11).Color(a.colors.Subtle)
		}
	})
}

func (a *App) newProjectFooter(c ui.C, language i18n.Language) {
	n := &a.newProject
	if ui.Button(c, i18n.Shared(language, "desktop.newProject.cancel")).Outline().Disabled(n.cancelling).Clicked() {
		a.cancelNewProject()
	}
	label := i18n.Shared(language, "desktop.newProject.create")
	disabled := n.busy
	switch {
	case n.busy:
		label = i18n.Shared(language, "desktop.newProject.creating")
	case n.created != "":
		label = i18n.Shared(language, "desktop.newProject.openCreated")
	default:
		if form := n.form(); form != nil && !form.ready() {
			disabled = true
		}
		if n.checked && n.check.key == n.parent+"\x00"+n.name && n.check.problem != "" {
			disabled = true
		}
	}
	if ui.Button(c, label).Disabled(disabled).Clicked() {
		a.submitNewProject()
	}
}

// checkProblemMessage is the sentence for a name or location problem.
func (a *App) checkProblemMessage(language i18n.Language, problem string) string {
	switch problem {
	case "invalidName":
		return i18n.Shared(language, "desktop.newProject.invalidName")
	case "exists":
		return i18n.Shared(language, "desktop.newProject.exists")
	}
	return i18n.Shared(language, "desktop.newProject.invalidLocation")
}

// fieldProblemMessage is the sentence for a problem code Core reported for a
// field; hosts localize by code.
func fieldProblemMessage(language i18n.Language, problem string) string {
	switch problem {
	case "required":
		return i18n.Shared(language, "desktop.newProject.problem.required")
	case "tooLong":
		return i18n.Shared(language, "desktop.newProject.problem.tooLong")
	case "invalidFormat":
		return i18n.Shared(language, "desktop.newProject.problem.invalidFormat")
	case "runtimeTooOld":
		return i18n.Shared(language, "desktop.newProject.problem.runtimeTooOld")
	case "toolTooOld":
		return i18n.Shared(language, "desktop.newProject.problem.toolTooOld")
	case "versionTooHigh":
		return i18n.Shared(language, "desktop.newProject.problem.versionTooHigh")
	}
	return i18n.Shared(language, "desktop.newProject.problem.unsupportedValue")
}
