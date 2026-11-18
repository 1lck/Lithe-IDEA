package workbench

import (
	"encoding/json"
	"reflect"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// runConfigFormWidth is the editor dialog's width, wide enough for a path and its options.
	runConfigFormWidth = 640
	// runConfigFormBodyMaxHeight bounds the fields, which scroll beyond it.
	runConfigFormBodyMaxHeight = 520
	// runConfigFormLabelWidth is the column of field titles.
	runConfigFormLabelWidth = 150
	// runConfigFormTextHeight is the height of a script saved as text.
	runConfigFormTextHeight = 140
	// runConfigFormVariableNameWidth is the name column of an environment variable row.
	runConfigFormVariableNameWidth = 170
)

// Built-in process run providers, as Core names them.
const (
	runProviderShell      = "process.shell"
	runProviderPowerShell = "process.powershell"
	runProviderBatch      = "process.batch"
	runProviderExecutable = "process.executable"
)

// runConfigTypeLabel names a built-in kind; ok is false for one this host has no name for.
func runConfigTypeLabel(language i18n.Language, provider string) (string, bool) {
	switch provider {
	case runProviderShell:
		return i18n.Shared(language, "desktop.runConfig.typeShell"), true
	case runProviderPowerShell:
		return i18n.Shared(language, "desktop.runConfig.typePowerShell"), true
	case runProviderBatch:
		return i18n.Shared(language, "desktop.runConfig.typeBatch"), true
	case runProviderExecutable:
		return i18n.Shared(language, "desktop.runConfig.typeExecutable"), true
	}
	return "", false
}

// runConfigTypeIcon is the icon of a built-in kind: a script or a program.
func runConfigTypeIcon(provider string) gfx.Icon {
	if provider == runProviderExecutable {
		return icons.Cpu
	}
	return icons.FileCode
}

// runConfigFieldLabel is the title of an editor field; ok is false for a field this host has
// no title for, which it then leaves out.
func runConfigFieldLabel(language i18n.Language, id string) (string, bool) {
	switch id {
	case "name":
		return i18n.Shared(language, "desktop.runConfig.fieldName"), true
	case "storeAsProjectFile":
		return i18n.Shared(language, "desktop.runConfig.fieldStoreAsProjectFile"), true
	case "source":
		return i18n.Shared(language, "desktop.runConfig.fieldSource"), true
	case "script":
		return i18n.Shared(language, "desktop.runConfig.fieldScript"), true
	case "text":
		return i18n.Shared(language, "desktop.runConfig.fieldText"), true
	case "scriptOptions":
		return i18n.Shared(language, "desktop.runConfig.fieldScriptOptions"), true
	case "programArguments":
		return i18n.Shared(language, "desktop.runConfig.arguments"), true
	case "workingDirectory":
		return i18n.Shared(language, "desktop.runConfig.workingDirectory"), true
	case "environment":
		return i18n.Shared(language, "desktop.runConfig.environment"), true
	case "interpreter":
		return i18n.Shared(language, "desktop.runConfig.fieldInterpreter"), true
	case "interpreterArguments":
		return i18n.Shared(language, "desktop.runConfig.fieldInterpreterArguments"), true
	case "executionPolicyBypass":
		return i18n.Shared(language, "desktop.runConfig.fieldExecutionPolicyBypass"), true
	case "program":
		return i18n.Shared(language, "desktop.runConfig.fieldProgram"), true
	}
	return "", false
}

// runConfigFieldHelp is the ⓘ tip of a field: what its note means, or what the field does.
func runConfigFieldHelp(language i18n.Language, field core.RunEditorField) string {
	switch {
	case field.Note == "windowsOnly":
		return i18n.Shared(language, "desktop.runConfig.noteWindowsOnly")
	case field.ID == "storeAsProjectFile":
		return i18n.Shared(language, "desktop.runConfig.storeAsProjectFileHelp")
	case field.ID == "interpreter":
		return i18n.Shared(language, "desktop.runConfig.interpreterHelp")
	}
	return ""
}

// runConfigChoiceLabel names an option of a choice field; ok is false for one this host has
// no name for, and the field is then left out.
func runConfigChoiceLabel(language i18n.Language, field, option string) (string, bool) {
	switch field + "/" + option {
	case "source/file":
		return i18n.Shared(language, "desktop.runConfig.sourceFile"), true
	case "source/text":
		return i18n.Shared(language, "desktop.runConfig.sourceText"), true
	}
	return "", false
}

// runConfigFieldError words the code of a wrong value. An unknown code shows as itself.
func runConfigFieldError(language i18n.Language, code string) string {
	switch code {
	case "required":
		return i18n.Shared(language, "desktop.runConfig.errorRequired")
	case "conflict":
		return i18n.Shared(language, "desktop.runConfig.errorConflict")
	case "notAllowed":
		return i18n.Shared(language, "desktop.runConfig.errorNotAllowed")
	case "tooLong":
		return i18n.Shared(language, "desktop.runConfig.errorTooLong")
	case "invalidCharacter":
		return i18n.Shared(language, "desktop.runConfig.errorInvalidCharacter")
	case "invalidPath":
		return i18n.Shared(language, "desktop.runConfig.errorInvalidPath")
	case "notFound":
		return i18n.Shared(language, "desktop.runConfig.errorNotFound")
	case "outsideProject":
		return i18n.Shared(language, "desktop.runConfig.errorOutsideProject")
	case "invalidName":
		return i18n.Shared(language, "desktop.runConfig.errorInvalidName")
	case "duplicate":
		return i18n.Shared(language, "desktop.runConfig.errorDuplicate")
	}
	return i18n.SharedFormat(language, "desktop.runConfig.errorOther", map[string]string{"code": code})
}

// drawable reports whether this host draws field: a kind it knows, a title it has, and for a
// choice a name for every option.
func (f *runConfigForm) drawable(language i18n.Language, field core.RunEditorField) bool {
	if _, ok := runConfigFieldLabel(language, field.ID); !ok {
		return false
	}
	switch field.Kind {
	case runFieldCheckbox:
		return f.flags[field.ID] != nil
	case runFieldEnvironment:
		return f.environment != nil
	case runFieldChoice:
		for _, option := range field.Options {
			if _, ok := runConfigChoiceLabel(language, field.ID, option); !ok {
				return false
			}
		}
	}
	return runFieldTextual(field.Kind) && f.texts[field.ID] != nil
}

// visible reports whether field shows for the edited values: always, or while the field its
// condition names has the value the condition wants.
func visibleRunConfigField(field core.RunEditorField, values map[string]json.RawMessage) bool {
	condition := field.VisibleWhen
	if condition == nil {
		return true
	}
	var current any
	if raw, ok := values[condition.Field]; !ok || json.Unmarshal(raw, &current) != nil {
		return false
	}
	return reflect.DeepEqual(current, condition.Equals)
}

// runConfigFormTitle is the dialog's title: the kind of a new configuration, or the name of
// the one edited.
func (a *App) runConfigFormTitle(f *runConfigForm) string {
	language := a.language()
	kind, _ := runConfigTypeLabel(language, f.provider)
	if f.id == "" || f.name == "" {
		return i18n.SharedFormat(language, "desktop.runConfig.newTitle", map[string]string{"type": kind})
	}
	return i18n.SharedFormat(language, "desktop.runConfig.editTitle", map[string]string{"name": f.name})
}

// drawRunConfigForm declares the open editor of a built-in process run: the name and where it
// is stored on top, then the fields Core described in order, and Run, Cancel, Apply and OK.
func (a *App) drawRunConfigForm(c ui.C, p *project) {
	f := &p.runConfigs.form
	if !f.open {
		return
	}
	language := a.language()
	ready := !f.loading && !f.saving && f.fields != nil
	open := true
	closed := ui.ModalWith(c, &open, a.runConfigFormTitle(f), ui.ModalSpec{Width: runConfigFormWidth}, func() {
		k := c.Part("run-config-form")
		ui.Scroll(k).Scrollbars().FillWidth().MaxHeight(runConfigFormBodyMaxHeight).Children(func() {
			ui.Column(k).FillWidth().Gap(10).PadSides(0, 12, 0, 0).Children(func() {
				if f.loading {
					ui.Text(k, i18n.Shared(language, "native.loading")).Color(a.colors.Subtle)
				}
				a.drawRunConfigFormFields(k, p, f, ready)
				if f.failure != "" {
					ui.Paragraph(k, f.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			})
		})
	}, func() {
		ui.Row(c.Part("run-config-form-footer")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			if ui.Button(c, i18n.Shared(language, "desktop.runConfig.run")).Icon(icons.Play).Outline().Disabled(!ready).Clicked() {
				c.After(func() {
					a.performed("run.configuration.form.run", surfaceButton)
					a.saveRunConfigForm(p, runConfigFormRun)
				})
			}
			ui.Spacer(c)
			if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
				c.After(func() { a.closeRunConfigForm(p) })
			}
			if ui.Button(c, i18n.Shared(language, "desktop.runConfig.apply")).Outline().Disabled(!ready).Clicked() {
				c.After(func() {
					a.performed("run.configuration.form.apply", surfaceButton)
					a.saveRunConfigForm(p, runConfigFormApply)
				})
			}
			if ui.Button(c, i18n.Shared(language, "desktop.runConfig.ok")).Disabled(!ready).Clicked() {
				c.After(func() {
					a.performed("run.configuration.form.save", surfaceButton)
					a.saveRunConfigForm(p, runConfigFormClose)
				})
			}
		})
	})
	if closed {
		c.After(func() { a.closeRunConfigForm(p) })
	}
}

// drawRunConfigFormFields declares the header row, then every other field that shows for the
// edited values. A wrong value's reason sits under its field; one for a field not drawn sits
// at the end.
func (a *App) drawRunConfigFormFields(c ui.C, p *project, f *runConfigForm, ready bool) {
	if f.fields == nil {
		return
	}
	language := a.language()
	values := f.collect()
	drawn := map[string]bool{}
	var header, body []core.RunEditorField
	for _, field := range f.fields {
		if !f.drawable(language, field) || !visibleRunConfigField(field, values) {
			continue
		}
		drawn[field.ID] = true
		if field.Placement == "header" {
			header = append(header, field)
		} else {
			body = append(body, field)
		}
	}
	if len(header) > 0 {
		ui.Row(c.Part("header")).FillWidth().Items(ui.Center).Gap(12).Children(func() {
			for _, field := range header {
				a.drawRunConfigFormHeaderField(c.Key(field.ID), p, f, field, ready)
			}
		})
		for _, field := range header {
			a.drawRunConfigFormError(c.Key(field.ID), f, field.ID, 0)
		}
		ui.Divider(c)
	}
	for _, field := range body {
		a.drawRunConfigFormField(c.Key(field.ID), p, f, field, ready)
	}
	for _, wrong := range f.fields {
		if !drawn[wrong.ID] {
			a.drawRunConfigFormError(c.Key(wrong.ID), f, wrong.ID, 0)
		}
	}
}

// drawRunConfigFormHeaderField declares a field of the top row: the name grows, a checkbox
// keeps its size.
func (a *App) drawRunConfigFormHeaderField(c ui.C, p *project, f *runConfigForm, field core.RunEditorField, ready bool) {
	language := a.language()
	label, _ := runConfigFieldLabel(language, field.ID)
	if field.Kind == runFieldCheckbox {
		ui.Row(c).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
			if ui.Checkbox(c, f.flags[field.ID], label).Disabled(!ready).Changed() {
				c.After(func() { a.runConfigFormEdited(p) })
			}
			a.runConfigFormHelp(c, language, field)
		})
		return
	}
	ui.Row(c).Grow(1).MinWidth(0).Items(ui.Center).Gap(8).Children(func() {
		ui.Text(c, label).Shrink(0)
		a.drawRunConfigFormControl(c, p, f, field, label, ready)
	})
}

// drawRunConfigFormField declares one field as a row: its title and ⓘ in the title column,
// its control beside them, and the reason a saved value was wrong under it. A checkbox
// carries its own title in the control column.
func (a *App) drawRunConfigFormField(c ui.C, p *project, f *runConfigForm, field core.RunEditorField, ready bool) {
	language := a.language()
	label, _ := runConfigFieldLabel(language, field.ID)
	tall := field.Kind == runFieldMultilineText || field.Kind == runFieldEnvironment
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		row := ui.Row(c).FillWidth().Gap(12)
		if tall {
			row = row.Items(ui.Start)
		} else {
			row = row.Items(ui.Center)
		}
		row.Children(func() {
			ui.Row(c.Part("title")).Width(runConfigFormLabelWidth).MinHeight(28).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
				if field.Kind != runFieldCheckbox {
					ui.Text(c, label).Ellipsis().Shrink(1).MinWidth(0)
					a.runConfigFormHelp(c, language, field)
				}
			})
			if field.Kind == runFieldCheckbox {
				ui.Row(c).Grow(1).Items(ui.Center).Gap(4).Children(func() {
					if ui.Checkbox(c, f.flags[field.ID], label).Disabled(!ready).Changed() {
						c.After(func() { a.runConfigFormEdited(p) })
					}
					a.runConfigFormHelp(c, language, field)
				})
				return
			}
			a.drawRunConfigFormControl(c, p, f, field, label, ready)
		})
		a.drawRunConfigFormError(c, f, field.ID, runConfigFormLabelWidth+12)
	})
}

// drawRunConfigFormControl declares the control of a field by its kind. A field whose
// automatic value applies while it is empty shows that value as its placeholder.
func (a *App) drawRunConfigFormControl(c ui.C, p *project, f *runConfigForm, field core.RunEditorField, label string, ready bool) {
	language := a.language()
	placeholder := ""
	switch {
	case field.Automatic != nil:
		placeholder = i18n.SharedFormat(language, "desktop.runConfig.automaticValue", map[string]string{"value": *field.Automatic})
	case field.Kind == runFieldArguments:
		placeholder = i18n.Shared(language, "desktop.runConfig.argumentsPlaceholder")
	}
	edited := func() { c.After(func() { a.runConfigFormEdited(p) }) }
	switch field.Kind {
	case runFieldEnvironment:
		a.drawRunConfigVariables(c, p, f, ready)
	case runFieldChoice:
		options := field.Options
		if ui.Choice(c, f.texts[field.ID], options, func(option string) string {
			name, _ := runConfigChoiceLabel(language, field.ID, option)
			return name
		}).Disabled(!ready).Changed() {
			edited()
		}
	case runFieldMultilineText:
		if ui.TextArea(c, f.texts[field.ID], label, placeholder).Mono().Grow(1).Height(runConfigFormTextHeight).Disabled(!ready).Changed() {
			edited()
		}
	case runFieldFile, runFieldExecutable, runFieldDirectory:
		box := ui.TextField(c, f.texts[field.ID], label, placeholder).Grow(1).MinWidth(0).Disabled(!ready).
			Action(icons.FolderOpen, i18n.Shared(language, "desktop.runConfig.browse"))
		if box.Changed() {
			edited()
		}
		if box.ActionClicked() {
			c.After(func() { a.browseRunConfigField(p, field, label) })
		}
	default:
		if ui.TextField(c, f.texts[field.ID], label, placeholder).Grow(1).MinWidth(0).Disabled(!ready).Changed() {
			edited()
		}
	}
}

// drawRunConfigVariables declares the environment variable rows, each a name, a value and its
// remove button, and the button that adds a row.
func (a *App) drawRunConfigVariables(c ui.C, p *project, f *runConfigForm, ready bool) {
	language := a.language()
	nameLabel, valueLabel := i18n.Shared(language, "desktop.runConfig.variableName"), i18n.Shared(language, "desktop.runConfig.variableValue")
	ui.Column(c.Part("variables")).Grow(1).MinWidth(0).Gap(6).Children(func() {
		for index, variable := range f.environment {
			k := c.KeyInt(index)
			ui.Row(k).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				if ui.TextField(k.Part("name"), &variable.name, nameLabel, nameLabel).Width(runConfigFormVariableNameWidth).Shrink(0).Disabled(!ready).Changed() {
					c.After(func() { a.runConfigFormEdited(p) })
				}
				if ui.TextField(k.Part("value"), &variable.value, valueLabel, valueLabel).Grow(1).MinWidth(0).Disabled(!ready).Changed() {
					c.After(func() { a.runConfigFormEdited(p) })
				}
				if a.gitIconButton(k.Part("remove"), i18n.Shared(language, "desktop.runConfig.variableRemove"), icons.Trash2, false, !ready) {
					c.After(func() {
						f.environment = removeRunConfigVariable(f.environment, variable)
						a.runConfigFormEdited(p)
					})
				}
			})
		}
		if ui.Button(c.Part("add"), i18n.Shared(language, "desktop.runConfig.variableAdd")).Icon(icons.Plus).Ghost().Disabled(!ready).Clicked() {
			c.After(func() { f.environment = append(f.environment, &runConfigVariable{}) })
		}
	})
}

// removeRunConfigVariable is rows without row.
func removeRunConfigVariable(rows []*runConfigVariable, row *runConfigVariable) []*runConfigVariable {
	kept := make([]*runConfigVariable, 0, len(rows))
	for _, other := range rows {
		if other != row {
			kept = append(kept, other)
		}
	}
	return kept
}

// runConfigFormHelp declares the ⓘ of a field that has a tip.
func (a *App) runConfigFormHelp(c ui.C, language i18n.Language, field core.RunEditorField) {
	if help := runConfigFieldHelp(language, field); help != "" {
		ui.Button(c.Part("help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().
			Size(18, 18).Shrink(0).Tooltip(help).TooltipOn(ui.TooltipRight)
	}
}

// drawRunConfigFormError declares the reason the last save found field's value wrong, indented
// under its control.
func (a *App) drawRunConfigFormError(c ui.C, f *runConfigForm, field string, indent float32) {
	code, ok := f.errors[field]
	if !ok {
		return
	}
	ui.Row(c.Part("error")).FillWidth().PadSides(0, 0, 0, indent).Children(func() {
		ui.Paragraph(c, runConfigFieldError(a.language(), code), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
	})
}
