package workbench

// The Before Launch list of the Run/Debug Configurations dialog, as IntelliJ IDEA's: each step
// runs another configuration or a task a plugin declares (API-29, `beforeLaunchTasks`). The
// "+" button's "Add New Task" menu lists "Run Another Configuration" and every task kind the
// installed plugins declare; a task opens its form in a dialog, and Core checks the values
// (`runConfig.checkBeforeLaunchTask`) before the step joins the list. The list is saved with
// the configuration, which Core checks again.
//
// Note: 决策见 .agents/notes/implemented/feature/2026-11-18-run-configuration-before-launch-steps.md

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// runConfigBeforeLaunchLimit is the most steps a configuration names, as Core allows.
const runConfigBeforeLaunchLimit = 16

// runConfigSteps is the edited Before Launch list of one configuration: its steps in order,
// as the `beforeLaunch` editor value holds them, and whether the menu that adds one is open.
type runConfigSteps struct {
	items []core.RunBeforeLaunchEntry
	menu  bool
}

// runConfigStepsOf reads a `beforeLaunch` editor value; nil or a value of another shape is an
// empty list.
func runConfigStepsOf(raw json.RawMessage) *runConfigSteps {
	steps := &runConfigSteps{items: []core.RunBeforeLaunchEntry{}}
	var items []core.RunBeforeLaunchEntry
	if len(raw) > 0 && json.Unmarshal(raw, &items) == nil && items != nil {
		steps.items = items
	}
	return steps
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

// drawRunConfigBeforeLaunch declares the steps that run before the configuration and the
// button whose "Add New Task" menu adds one. A run step shows its configuration's name, a
// task step its kind's name and what it runs; each has buttons that move it up or down or
// remove it, and a task an installed plugin declares one that edits it. "Run Another
// Configuration" lists the configurations not chosen yet, and says so when there is none;
// each task kind opens its form. A step whose configuration or plugin is gone shows in red and
// stays until removed. edited, when set, runs after each change, so an editor that tracks its
// edits by flag sees it.
func (a *App) drawRunConfigBeforeLaunch(c ui.C, p *project, steps *runConfigSteps, candidates []core.RunConfigurationName, tasks []core.RunTaskKind, ready bool, edited func()) {
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
	ui.Column(c.Part("before-launch")).Grow(1).MinWidth(0).Gap(4).Children(func() {
		if len(items) == 0 {
			ui.Text(c, i18n.Shared(language, "desktop.runConfig.beforeLaunchEmpty")).Color(a.colors.Subtle).LineHeight(28)
		}
		for index, entry := range items {
			k := c.KeyInt(index)
			icon, name, summary, known := icons.Play, "", "", true
			var kind *core.RunTaskKind
			if entry.Task != nil {
				kind = runConfigTaskKind(tasks, entry.Task.Task.RunTypeKey)
				icon, name, summary = a.runTaskIcon(kind), entry.Task.Name, entry.Task.Summary
				if entry.Task.Missing || kind == nil {
					known, kind = false, nil
					name = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunchTaskMissing", map[string]string{"name": name})
				}
			} else if name, known = names[entry.ConfigurationID]; !known {
				name = i18n.SharedFormat(language, "desktop.runConfig.beforeLaunchMissing", map[string]string{"id": entry.ConfigurationID})
			}
			ui.Row(k).FillWidth().MinHeight(28).Items(ui.Center).Gap(4).Children(func() {
				ui.Icon(k, icon).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
				color := a.colors.Text
				if !known {
					color = a.theme.Danger
				}
				ui.Text(k, fmt.Sprintf("%d. %s", index+1, name)).Color(color).Ellipsis().Shrink(1).MinWidth(0)
				if summary != "" {
					ui.Text(k.Part("summary"), summary).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				}
				ui.Spacer(k)
				if kind != nil && a.gitIconButton(k.Part("edit"), i18n.Shared(language, "desktop.runConfig.beforeLaunchEdit"), icons.Pencil, false, !ready) {
					values, task := entry.Task.Values, *kind
					c.After(func() { a.openRunConfigTask(p, steps, task, index, values, changed) })
				}
				if a.gitIconButton(k.Part("up"), i18n.Shared(language, "desktop.runConfig.beforeLaunchUp"), icons.ArrowUp, false, !ready || index == 0) {
					change(func() { moveRunConfigStep(steps.items, index, index-1) })
				}
				if a.gitIconButton(k.Part("down"), i18n.Shared(language, "desktop.runConfig.beforeLaunchDown"), icons.ArrowDown, false, !ready || index == len(items)-1) {
					change(func() { moveRunConfigStep(steps.items, index, index+1) })
				}
				if a.gitIconButton(k.Part("remove"), i18n.Shared(language, "desktop.runConfig.beforeLaunchRemove"), icons.Trash2, false, !ready) {
					change(func() { steps.items = slices.Delete(slices.Clone(steps.items), index, index+1) })
				}
			})
		}
		var left []core.RunConfigurationName
		for _, candidate := range candidates {
			if !slices.ContainsFunc(items, func(entry core.RunBeforeLaunchEntry) bool {
				return entry.Task == nil && entry.ConfigurationID == candidate.ID
			}) {
				left = append(left, candidate)
			}
		}
		full := len(items) >= runConfigBeforeLaunchLimit
		add := ui.Button(c.Part("add"), i18n.Shared(language, "desktop.runConfig.beforeLaunchAdd")).Icon(icons.Plus).Ghost().
			Disabled(!ready || full)
		if add.Clicked() {
			c.After(func() { steps.menu = !steps.menu })
		}
		if !steps.menu {
			return
		}
		// IDEA's "Add New Task" popup: one item per kind of task, each opening what it needs.
		ui.Menu(c.Part("add-menu"), add, &steps.menu, func(menu *ui.MenuItems) {
			menu.WidthRange(200, 320)
			menu.Label(i18n.Shared(language, "desktop.runConfig.beforeLaunchMenuTitle"))
			menu.Sub(i18n.Shared(language, "desktop.runConfig.beforeLaunchRunAnother"), func(runs *ui.MenuItems) {
				runs.WidthRange(160, 320)
				if len(left) == 0 {
					runs.Item(i18n.Shared(language, "desktop.runConfig.beforeLaunchNoCandidates")).Disabled(true)
				}
				for _, candidate := range left {
					if runs.Item(candidate.Name).Icon(icons.Play).Clicked() {
						change(func() {
							a.performed("run.configuration.form.beforeLaunch.add", surfaceButton)
							steps.items = append(slices.Clone(steps.items), core.RunBeforeLaunchEntry{ConfigurationID: candidate.ID})
						})
					}
				}
			}).Icon(icons.Play)
			for _, kind := range tasks {
				if menu.Item(kind.DisplayName).Icon(a.runTaskIcon(&kind)).Clicked() {
					c.After(func() {
						a.performed("run.configuration.form.beforeLaunch.addTask", surfaceButton)
						a.openRunConfigTask(p, steps, kind, -1, kind.Values, changed)
					})
				}
			}
		})
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
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Description: t.kind.Description, Width: 560}, func() {
		k := c.Part("run-config-task")
		ui.Column(k).FillWidth().Gap(10).Children(func() {
			a.drawRunConfigFormFields(k, p, t.form, !t.checking)
			if t.failure != "" {
				ui.Paragraph(k.Part("failure"), t.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
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
