package workbench

// The Before Launch section of the Run/Debug Configurations dialog, as IntelliJ IDEA's: a title
// that folds it over a framed list of steps with a toolbar on top. Each step runs another
// configuration or a task a plugin declares (API-29, `beforeLaunchTasks`). The toolbar's "+"
// opens the "Add New Task" menu: "Run Another Configuration", which opens the list of
// configurations to run, and every task kind the installed plugins declare. A task opens its
// form in a dialog, and Core checks the values (`runConfig.checkBeforeLaunchTask`) before the
// step joins the list. The list is saved with the configuration, which Core checks again.
//
// Note: 决策见 .agents/notes/implemented/feature/2026-11-18-run-configuration-before-launch-steps.md

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"maps"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// runConfigBeforeLaunchLimit is the most steps a configuration names, as Core allows.
	runConfigBeforeLaunchLimit = 16
	// runConfigBeforeLaunchRows is how many steps the list shows before it scrolls.
	runConfigBeforeLaunchRows = 4
	// runConfigMenuTitleHeight is the row of the centered title over a menu of the section.
	runConfigMenuTitleHeight = 28
)

// runConfigSteps is the edited Before Launch list of one configuration: its steps in order,
// as the `beforeLaunch` editor value holds them, and the state of the section that shows them.
type runConfigSteps struct {
	items []core.RunBeforeLaunchEntry
	// list is the state of the rows; selected is the step the toolbar acts on, -1 for none.
	list     ui.ListState
	selected int
	// collapsed folds the section to its title.
	collapsed bool
	// menu is the open "Add New Task" menu. choose is the open list of configurations to run:
	// the one chosen joins the list at its end, or with replace at a step's index takes that
	// step's place.
	menu, choose bool
	replace      int
}

// newRunConfigSteps is the list of items with no step selected.
func newRunConfigSteps(items []core.RunBeforeLaunchEntry) *runConfigSteps {
	if items == nil {
		items = []core.RunBeforeLaunchEntry{}
	}
	return &runConfigSteps{items: items, selected: -1, replace: -1}
}

// runConfigStepsOf reads a `beforeLaunch` editor value; nil or a value of another shape is an
// empty list.
func runConfigStepsOf(raw json.RawMessage) *runConfigSteps {
	var items []core.RunBeforeLaunchEntry
	if len(raw) == 0 || json.Unmarshal(raw, &items) != nil {
		items = nil
	}
	return newRunConfigSteps(items)
}

// runConfigStepSaved is what a step saves: the configuration it runs, or the task with its
// values. The name and summary Core gave it are not saved.
func runConfigStepSaved(entry core.RunBeforeLaunchEntry) any {
	if entry.Task != nil {
		return entry.Task.Task
	}
	return entry.ConfigurationID
}

// sameRunConfigSteps says two lists save the same steps in the same order.
func sameRunConfigSteps(a, b []core.RunBeforeLaunchEntry) bool {
	saved := func(entries []core.RunBeforeLaunchEntry) []byte {
		values := make([]any, 0, len(entries))
		for _, entry := range entries {
			values = append(values, runConfigStepSaved(entry))
		}
		raw, _ := json.Marshal(values)
		return raw
	}
	return bytes.Equal(saved(a), saved(b))
}

// runConfigTaskKind is the kind of task step key among tasks, nil when no installed plugin
// declares it.
func runConfigTaskKind(tasks []core.RunTaskKind, key core.RunTypeKey) *core.RunTaskKind {
	index := slices.IndexFunc(tasks, func(kind core.RunTaskKind) bool { return kind.RunType == key })
	if index < 0 {
		return nil
	}
	return &tasks[index]
}

// runTaskIcon is the icon of a task kind: the package or host icon the plugin names, else a
// wrench.
func (a *App) runTaskIcon(kind *core.RunTaskKind) gfx.Icon {
	if kind == nil {
		return icons.Wrench
	}
	if icon, ok := runTypePackageIcon(&a.pluginIcons, kind.RunType.PluginID, kind.Icon, a.colors.Dark); ok {
		return icon
	}
	if kind.Icon != nil && kind.Icon.Host != "" {
		if icon := pluginToolIcon(kind.Icon.Host); icon != nil {
			return *icon
		}
	}
	return icons.Wrench
}

// moveRunConfigStep swaps the step at from with the one at to, when both exist.
func moveRunConfigStep[T any](steps []T, from, to int) {
	if from < 0 || to < 0 || from >= len(steps) || to >= len(steps) {
		return
	}
	steps[from], steps[to] = steps[to], steps[from]
}

// runConfigStepRow is a step as its row shows it: the icon and name, what a task runs, the
// kind of a task an installed plugin declares, and whether what the step names is gone.
type runConfigStepRow struct {
	icon    gfx.Icon
	name    string
	summary string
	kind    *core.RunTaskKind
	missing bool
}

// runConfigStepRowOf is how entry shows: a run step as "Run 'name'" with its configuration's
// icon, a task step with its kind's icon and name and what it runs. names holds the name of
// every configuration a step can run by ID.
func (a *App) runConfigStepRowOf(p *project, language i18n.Language, entry core.RunBeforeLaunchEntry, names map[string]string, tasks []core.RunTaskKind) runConfigStepRow {
	if entry.Task != nil {
		kind := runConfigTaskKind(tasks, entry.Task.Task.RunTypeKey)
		row := runConfigStepRow{icon: a.runTaskIcon(kind), name: entry.Task.Name, summary: entry.Task.Summary, kind: kind}
		if entry.Task.Missing || kind == nil {
			row.kind, row.missing = nil, true
			row.name = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunchTaskMissing", map[string]string{"name": entry.Task.Name})
		}
		return row
	}
	row := runConfigStepRow{icon: a.runConfigDraftIcon(p, entry.ConfigurationID)}
	if name, known := names[entry.ConfigurationID]; known {
		row.name = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunchRunStep", map[string]string{"name": name})
	} else {
		row.name = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunchMissing", map[string]string{"id": entry.ConfigurationID})
		row.missing = true
	}
	return row
}

// drawRunConfigBeforeLaunch declares the Before Launch section: the title row, whose arrow and
// name fold it, and under it the framed list. title is the section's name and help the tip of
// its ⓘ; edited, when set, runs after each change, so an editor that tracks its edits by flag
// sees it.
func (a *App) drawRunConfigBeforeLaunch(c ui.C, p *project, steps *runConfigSteps, title, help string, candidates []core.RunConfigurationName, tasks []core.RunTaskKind, ready bool, edited func()) {
	ui.Column(c).FillWidth().Gap(6).Children(func() {
		a.drawRunConfigStepsTitle(c, steps, title, help)
		if !steps.collapsed {
			a.drawRunConfigStepsList(c, p, steps, title, candidates, tasks, ready, edited)
		}
	})
}

// drawRunConfigStepsTitle declares the title row of the section, as IDEA's titled separator:
// the arrow and name that fold the section, the ⓘ with help, and a line to the row's end.
func (a *App) drawRunConfigStepsTitle(c ui.C, steps *runConfigSteps, title, help string) {
	language := a.language()
	open := !steps.collapsed
	name, chevron := i18n.Shared(language, "native.collapseSection"), icons.ChevronDown
	if !open {
		name, chevron = i18n.Shared(language, "native.expandSection"), icons.ChevronRight
	}
	ui.Row(c.Part("title")).FillWidth().Height(24).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
		k := c.Part("fold")
		fold := ui.Row(k).Shrink(0).Items(ui.Center).Gap(4).
			HitWith(ui.ID(k), name+" "+title, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open})
		fold.Children(func() {
			ui.Icon(c, chevron).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
			ui.Text(c, title).Shrink(0)
		})
		if fold.Clicked() {
			c.After(func() { steps.collapsed = !steps.collapsed })
		}
		if help != "" {
			ui.Button(c.Part("help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().
				Size(18, 18).Shrink(0).Tooltip(help).TooltipOn(ui.TooltipRight)
		}
		ui.Row(c.Part("line")).Grow(1).MinWidth(0).Height(1).Background(a.colors.Line)
	})
}

// drawRunConfigStepsList declares the framed list of steps: the toolbar, a line, and the rows,
// four of them before the list scrolls, or the note that there is no step. "+" opens the "Add
// New Task" menu; "−" removes the selected step, the pencil edits it, as Enter and a double
// click on its row do, and the arrows move it. Delete and, on macOS, Backspace remove it too.
// The pencil edits a task an installed plugin declares in its form, and a run step by the list
// of configurations to run. A step whose configuration or plugin is gone shows in red and
// stays until removed. title names the list.
func (a *App) drawRunConfigStepsList(c ui.C, p *project, steps *runConfigSteps, title string, candidates []core.RunConfigurationName, tasks []core.RunTaskKind, ready bool, edited func()) {
	language := a.language()
	changed := func() {
		if edited != nil {
			edited()
		}
	}
	change := func(apply func()) {
		c.After(func() {
			apply()
			changed()
		})
	}
	names := make(map[string]string, len(candidates))
	for _, candidate := range candidates {
		names[candidate.ID] = candidate.Name
	}
	items := steps.items
	rows := make([]runConfigStepRow, len(items))
	for index, entry := range items {
		rows[index] = a.runConfigStepRowOf(p, language, entry, names, tasks)
	}
	selected := steps.selected
	if selected >= len(items) {
		selected = -1
	}
	editable := func(index int) bool {
		return ready && index >= 0 && index < len(items) && (items[index].Task == nil || rows[index].kind != nil)
	}
	remove := func(index int) {
		change(func() {
			a.performed("run.configuration.form.beforeLaunch.remove", surfaceButton)
			steps.items = slices.Delete(slices.Clone(steps.items), index, index+1)
			steps.selected = min(index, len(steps.items)-1)
		})
	}
	move := func(index, to int) {
		change(func() {
			a.performed("run.configuration.form.beforeLaunch.move", surfaceButton)
			moved := slices.Clone(steps.items)
			moveRunConfigStep(moved, index, to)
			steps.items, steps.selected = moved, to
		})
	}
	edit := func(index int) {
		if task := rows[index].kind; items[index].Task != nil && task != nil {
			kind, values := *task, items[index].Task.Values
			c.After(func() {
				a.performed("run.configuration.form.beforeLaunch.edit", surfaceButton)
				a.openRunConfigTask(p, steps, kind, index, values, changed)
			})
			return
		}
		c.After(func() { steps.menu, steps.choose, steps.replace = false, true, index })
	}
	full := len(items) >= runConfigBeforeLaunchLimit
	ui.Column(c.Part("frame")).FillWidth().Border(1, a.colors.Line).Radius(a.theme.Metrics.RadiusItem()).Clip().Children(func() {
		ui.Row(c.Part("toolbar")).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(2).PadX(4).Children(func() {
			add, clicked := a.gitToolButton(c.Part("add"), i18n.Shared(language, "desktop.runConfig.beforeLaunchAdd"), icons.Plus, steps.menu || steps.choose, !ready || full)
			if clicked {
				c.After(func() { steps.menu, steps.choose = !steps.menu && !steps.choose, false })
			}
			a.drawRunConfigStepsMenu(c, p, steps, add, tasks, changed)
			a.drawRunConfigStepsChooser(c, p, steps, add, candidates, change)
			if a.gitIconButton(c.Part("remove"), i18n.Shared(language, "desktop.runConfig.beforeLaunchRemove"), icons.Minus, false, !ready || selected < 0) {
				remove(selected)
			}
			if a.gitIconButton(c.Part("edit"), i18n.Shared(language, "desktop.runConfig.beforeLaunchEdit"), icons.Pencil, false, !editable(selected)) {
				edit(selected)
			}
			if a.gitIconButton(c.Part("up"), i18n.Shared(language, "desktop.runConfig.beforeLaunchUp"), icons.ArrowUp, false, !ready || selected <= 0) {
				move(selected, selected-1)
			}
			if a.gitIconButton(c.Part("down"), i18n.Shared(language, "desktop.runConfig.beforeLaunchDown"), icons.ArrowDown, false, !ready || selected < 0 || selected >= len(items)-1) {
				move(selected, selected+1)
			}
		})
		ui.Row(c.Part("toolbar-line")).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		height := float32(runConfigBeforeLaunchRows*treelist.RowHeight + 2*treelist.PadY)
		ui.Column(c.Part("rows")).FillWidth().Height(height).Shrink(0).Children(func() {
			if len(items) == 0 {
				ui.Column(c.Part("empty")).FillWidth().Grow(1).Center().PadX(12).Children(func() {
					ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.beforeLaunchEmpty"), 2).TextCenter().Color(a.colors.Subtle)
				})
				return
			}
			steps.list.Label = func(index int) string {
				if index >= 0 && index < len(rows) {
					return rows[index].name
				}
				return ""
			}
			if !steps.list.Changed() && steps.list.Selected() != selected {
				steps.list.Select(selected)
			}
			list := ui.List(c.Part("list"), &steps.list, len(items), func(row ui.ListRow) {
				a.drawRunConfigStepRow(row, rows[row.Index], row.Selected())
			}).Scrollbars().Label(title).Grow(1).FillWidth().PadY(treelist.PadY)
			if steps.list.Changed() {
				steps.selected = steps.list.Selected()
			}
			if index, ok := steps.list.Submitted(); ok && editable(index) {
				edit(index)
			}
			for _, key := range runConfigDeleteKeys() {
				if list.Shortcut(0, key) && ready && selected >= 0 {
					remove(selected)
				}
			}
		})
	})
}

// drawRunConfigStepRow declares the row of one step: its icon, its name, red when what it
// names is gone, and what a task runs. The selected row is highlighted across the list.
func (a *App) drawRunConfigStepRow(row ui.ListRow, step runConfigStepRow, selected bool) {
	c := row.C
	box := row.Element.Height(treelist.RowHeight).Items(ui.Center).Gap(6).PadX(8)
	if selected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	box.Children(func() {
		color := a.colors.Text
		if step.missing {
			color = a.theme.Danger
		}
		ui.Icon(c, step.icon).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, step.name).Color(color).Ellipsis().Shrink(1).MinWidth(0)
		if step.summary != "" {
			ui.Text(c, step.summary).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		}
	})
}

// paintRunConfigMenuTitle paints the centered bold title IDEA puts over the menus of the
// section.
func (a *App) paintRunConfigMenuTitle(canvas *gfx.Canvas, bounds gfx.Rect, title string) {
	canvas.LabelCenter(title, bounds, gfx.TextStyle{Size: a.theme.Metrics.FontSizeM, Weight: gfx.WeightSemibold, Color: a.colors.Text})
}

// drawRunConfigStepsMenu declares IDEA's "Add New Task" menu under "+": its title, then "Run
// Another Configuration", which opens the list of configurations to run, and an item per task
// kind the installed plugins declare, which opens the kind's form.
func (a *App) drawRunConfigStepsMenu(c ui.C, p *project, steps *runConfigSteps, anchor ui.Box, tasks []core.RunTaskKind, changed func()) {
	if !steps.menu {
		return
	}
	language := a.language()
	ui.Menu(c, anchor, &steps.menu, func(menu *ui.MenuItems) {
		menu.WidthRange(220, 320)
		title := i18n.Shared(language, "desktop.runConfig.beforeLaunchMenuTitle")
		menu.Content(runConfigMenuTitleHeight, func(canvas *gfx.Canvas, bounds gfx.Rect, _ gfx.Theme) {
			a.paintRunConfigMenuTitle(canvas, bounds, title)
		})
		if menu.Item(i18n.Shared(language, "desktop.runConfig.beforeLaunchRunAnother")).Icon(icons.Play).Clicked() {
			c.After(func() { steps.menu, steps.choose, steps.replace = false, true, -1 })
		}
		for _, kind := range tasks {
			if menu.Item(kind.DisplayName).Icon(a.runTaskIcon(&kind)).Clicked() {
				c.After(func() {
					a.performed("run.configuration.form.beforeLaunch.addTask", surfaceButton)
					a.openRunConfigTask(p, steps, kind, -1, kind.Values, changed)
				})
			}
		}
	})
}

// drawRunConfigStepsChooser declares IDEA's "Choose Configuration to Execute" list under "+":
// its title, then every configuration no step runs yet, or a note that there is none. The one
// chosen joins the list at its end, or takes the place of the step being edited.
func (a *App) drawRunConfigStepsChooser(c ui.C, p *project, steps *runConfigSteps, anchor ui.Box, candidates []core.RunConfigurationName, change func(func())) {
	if !steps.choose {
		return
	}
	language := a.language()
	var left []core.RunConfigurationName
	for _, candidate := range candidates {
		if !slices.ContainsFunc(steps.items, func(entry core.RunBeforeLaunchEntry) bool {
			return entry.Task == nil && entry.ConfigurationID == candidate.ID
		}) {
			left = append(left, candidate)
		}
	}
	ui.Menu(c, anchor, &steps.choose, func(menu *ui.MenuItems) {
		menu.WidthRange(220, 360)
		title := i18n.Shared(language, "desktop.runConfig.beforeLaunchChooseTitle")
		menu.Content(runConfigMenuTitleHeight, func(canvas *gfx.Canvas, bounds gfx.Rect, _ gfx.Theme) {
			a.paintRunConfigMenuTitle(canvas, bounds, title)
		})
		if len(left) == 0 {
			menu.Item(i18n.Shared(language, "desktop.runConfig.beforeLaunchNoCandidates")).Disabled(true)
		}
		for _, candidate := range left {
			if menu.Item(candidate.Name).Icon(a.runConfigDraftIcon(p, candidate.ID)).Clicked() {
				replace := steps.replace
				change(func() {
					entry := core.RunBeforeLaunchEntry{ConfigurationID: candidate.ID}
					items := slices.Clone(steps.items)
					if replace >= 0 && replace < len(items) {
						a.performed("run.configuration.form.beforeLaunch.replace", surfaceButton)
						items[replace] = entry
						steps.selected = replace
					} else {
						a.performed("run.configuration.form.beforeLaunch.add", surfaceButton)
						items = append(items, entry)
						steps.selected = len(items) - 1
					}
					steps.items, steps.choose, steps.replace = items, false, -1
				})
			}
		}
	})
}

// runConfigTaskEdit is the open form of a task step being added to a Before Launch list or
// edited in it. One is open at a time, over the Run/Debug Configurations dialog.
type runConfigTaskEdit struct {
	// steps is the list the step goes into; index is the step the form edits, -1 to add one
	// at the end. edited runs after the list changed.
	steps  *runConfigSteps
	index  int
	edited func()
	kind   core.RunTaskKind
	// form edits the task's values by the fields its kind declares; Core's reasons for wrong
	// values sit under their fields.
	form *runConfigForm
	// checking says the values are with Core; failure is why a check could not answer.
	checking bool
	failure  string
}

// openRunConfigTask opens the form of a task step of kind: a new step at the end with index
// -1, else the step at index. values are the editor values it starts with by field key.
func (a *App) openRunConfigTask(p *project, steps *runConfigSteps, kind core.RunTaskKind, index int, values map[string]json.RawMessage, edited func()) {
	form := &runConfigForm{
		open: true, generation: 1, kind: declaredKind(kind.RunType), task: true,
		fields: kind.Fields, values: maps.Clone(values),
		texts: map[string]*string{}, flags: map[string]*bool{},
	}
	if form.values == nil {
		form.values = map[string]json.RawMessage{}
	}
	form.readValues(kind.Fields, form.values)
	p.runConfigs.task = &runConfigTaskEdit{steps: steps, index: index, edited: edited, kind: kind, form: form}
}

// closeRunConfigTask drops the task form t, if it is still the open one.
func (p *project) closeRunConfigTask(t *runConfigTaskEdit) {
	if p.runConfigs.task == t {
		t.form.close()
		p.runConfigs.task = nil
	}
}

// checkRunConfigTask has Core check the form's values. Right values put the step Core returns
// into the list and close the form; wrong ones stay in it with the reason under each field.
func (a *App) checkRunConfigTask(p *project, t *runConfigTaskEdit) {
	if t.checking {
		return
	}
	t.checking, t.failure, t.form.errors = true, "", nil
	root, kernel, kinds, language := p.root, a.kernel, p.runConfigs.kinds(), a.language().Code()
	key, values := t.kind.RunType, t.form.collect()
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		plugins := a.runTypePlugins(ctx, kernel, kinds, language)
		check, err := kernel.CheckBeforeLaunchTask(ctx, root, key, values, plugins)
		if err == nil && check.Status == "ok" && check.Step == nil {
			err = errors.New("runConfig.checkBeforeLaunchTask returned no step")
		} else if err == nil && check.Status != "ok" && check.Status != "invalid" {
			err = errors.New("runConfig.checkBeforeLaunchTask returned an unknown status")
		}
		return func(a *App) {
			if p.runConfigs.task != t {
				return
			}
			t.checking = false
			switch {
			case err != nil:
				a.operationFailed("run_config_task_check", err)
				t.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.taskCheckFailed", map[string]string{"reason": err.Error()})
			case check.Status == "invalid":
				a.operationRejected("run_config_task_check", "invalid_values")
				t.form.errors = make(map[string]string, len(check.Errors))
				for _, wrong := range check.Errors {
					if _, seen := t.form.errors[wrong.Field]; !seen {
						t.form.errors[wrong.Field] = wrong.Code
					}
				}
			default:
				entry := core.RunBeforeLaunchEntry{Task: check.Step}
				items := slices.Clone(t.steps.items)
				if t.index >= 0 && t.index < len(items) {
					items[t.index] = entry
				} else {
					items = append(items, entry)
				}
				t.steps.items = items
				p.closeRunConfigTask(t)
				if t.edited != nil {
					t.edited()
				}
			}
		}
	})
}

// drawRunConfigTask declares the open task form over the Run/Debug Configurations dialog: the
// kind's fields, and OK, which has Core check the values, and Cancel. It closes with the
// dialog.
func (a *App) drawRunConfigTask(c ui.C, p *project) {
	t := p.runConfigs.task
	if t == nil {
		return
	}
	if !p.runConfigs.dialog.open {
		c.After(func() { p.closeRunConfigTask(t) })
		return
	}
	language := a.language()
	title := i18n.SharedFormat(language, "desktop.runConfig.taskEditTitle", map[string]string{"name": t.kind.DisplayName})
	if t.index < 0 {
		title = i18n.SharedFormat(language, "desktop.runConfig.taskAddTitle", map[string]string{"name": t.kind.DisplayName})
	}
	open := true
	closed := ui.Modal(c, &open, title, ui.ModalSpec{Description: t.kind.Description, Width: 560}, func() {
		k := c.Part("run-config-task")
		ui.Column(k).FillWidth().Gap(10).Children(func() {
			a.drawRunConfigFormFields(k, p, t.form, !t.checking)
			if t.failure != "" {
				ui.Paragraph(c, t.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
		})
	}, func() {
		ui.Row(c.Part("run-config-task-footer")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			ui.Spacer(c)
			if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
				c.After(func() { p.closeRunConfigTask(t) })
			}
			if ui.Button(c, i18n.Shared(language, "desktop.runConfig.ok")).Disabled(t.checking).Clicked() {
				c.After(func() {
					a.performed("run.configuration.form.beforeLaunch.taskOk", surfaceButton)
					a.checkRunConfigTask(p, t)
				})
			}
		})
	})
	if closed {
		c.After(func() { p.closeRunConfigTask(t) })
	}
}
