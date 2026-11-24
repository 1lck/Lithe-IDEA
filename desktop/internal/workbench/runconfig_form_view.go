package workbench

import (
	"encoding/json"
	"reflect"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// runConfigFormLabelWidth is the column of field titles.
	runConfigFormLabelWidth = 150
	// runConfigFormTextRows is how many rows a multiline text field, such as a script saved
	// as text, grows to with its text before it scrolls.
	runConfigFormTextRows = 4
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

// runConfigTypeIcon is the icon of a built-in kind: the colored project tree icon of the files
// it runs (.sh, .ps1, .cmd, .exe), so a kind looks like its files everywhere.
func runConfigTypeIcon(provider string, dark bool) gfx.Icon {
	switch provider {
	case runProviderShell:
		return fileicons.ForFile("run.sh", dark)
	case runProviderPowerShell:
		return fileicons.ForFile("run.ps1", dark)
	case runProviderBatch:
		return fileicons.ForFile("run.cmd", dark)
	case runProviderExecutable:
		return fileicons.ForFile("run.exe", dark)
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
	case "allowMultipleInstances":
		return i18n.Shared(language, "desktop.runConfig.fieldAllowMultipleInstances"), true
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
	case "beforeLaunch":
		return i18n.Shared(language, "desktop.runConfig.fieldBeforeLaunch"), true
	}
	return "", false
}

// runConfigFieldTitle is the title of field: the host's for a field it knows, else the
// translated label a plugin gives a field of its kind; ok is false for a field with neither,
// which the host then leaves out.
func runConfigFieldTitle(language i18n.Language, field core.RunEditorField) (string, bool) {
	if title, ok := runConfigFieldLabel(language, field.ID); ok {
		return title, true
	}
	return field.Label, field.Label != ""
}

// runConfigFieldHelp is the ⓘ tip of a field of a provider's editor: what its note means, what
// the field does, or the description a plugin gives a field of its kind. The script's
// arguments say how the script of that kind reads them.
func runConfigFieldHelp(language i18n.Language, provider string, field core.RunEditorField) string {
	switch {
	case field.Note == "windowsOnly":
		return i18n.Shared(language, "desktop.runConfig.noteWindowsOnly")
	case field.ID == "storeAsProjectFile":
		return i18n.Shared(language, "desktop.runConfig.storeAsProjectFileHelp")
	case field.ID == "allowMultipleInstances":
		return i18n.Shared(language, "desktop.runConfig.allowMultipleInstancesHelp")
	case field.Description != "":
		return field.Description
	case field.ID == "interpreter":
		return i18n.Shared(language, "desktop.runConfig.interpreterHelp")
	case field.ID == "beforeLaunch":
		return i18n.Shared(language, "desktop.runConfig.beforeLaunchHelp")
	case field.ID == "interpreterArguments":
		return i18n.Shared(language, "desktop.runConfig.interpreterArgumentsHelp")
	case field.ID == "programArguments":
		return i18n.Shared(language, "desktop.runConfig.programArgumentsHelp")
	case field.ID == "scriptOptions" && provider == runProviderPowerShell:
		return i18n.Shared(language, "desktop.runConfig.scriptOptionsHelpPowerShell")
	case field.ID == "scriptOptions" && provider == runProviderBatch:
		return i18n.Shared(language, "desktop.runConfig.scriptOptionsHelpBatch")
	case field.ID == "scriptOptions":
		return i18n.Shared(language, "desktop.runConfig.scriptOptionsHelpShell")
	}
	return ""
}

// runConfigFieldPlaceholder is what an empty field shows: the automatic value that applies
// while it is empty, the placeholder a plugin gives a field of its kind, or an example of what
// goes into an argument field.
func runConfigFieldPlaceholder(language i18n.Language, field core.RunEditorField) string {
	if field.Automatic != nil && *field.Automatic != "" {
		return i18n.SharedFormat(language, "desktop.runConfig.automaticValue", map[string]string{"value": *field.Automatic})
	}
	if field.Placeholder != "" {
		return field.Placeholder
	}
	switch field.ID {
	case "scriptOptions":
		return i18n.Shared(language, "desktop.runConfig.scriptOptionsPlaceholder")
	case "interpreterArguments":
		return i18n.Shared(language, "desktop.runConfig.interpreterArgumentsPlaceholder")
	case "programArguments":
		return i18n.Shared(language, "desktop.runConfig.programArgumentsPlaceholder")
	}
	if field.Automatic != nil {
		return i18n.SharedFormat(language, "desktop.runConfig.automaticValue", map[string]string{"value": *field.Automatic})
	}
	return ""
}

// runConfigOptionTitle names an option of a choice field: the host's name for an option it
// knows, else the translated label a plugin gives it; ok is false for one with neither, and
// the field is then left out.
func runConfigOptionTitle(language i18n.Language, field core.RunEditorField, option string) (string, bool) {
	if title, ok := runConfigChoiceLabel(language, field.ID, option); ok {
		return title, true
	}
	title := field.OptionLabels[option]
	return title, title != ""
}

// runConfigChoiceLabel names an option of a built-in choice field; ok is false for one this
// host has no name for.
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
	case "unavailable":
		return i18n.Shared(language, "desktop.runConfig.errorUnavailable")
	case "invalidValue":
		return i18n.Shared(language, "desktop.runConfig.errorInvalidValue")
	case "taskNotDeclared":
		return i18n.Shared(language, "desktop.runConfig.errorTaskNotDeclared")
	case "invalidTaskValues":
		return i18n.Shared(language, "desktop.runConfig.errorInvalidTaskValues")
	}
	return i18n.SharedFormat(language, "desktop.runConfig.errorOther", map[string]string{"code": code})
}

// drawable reports whether this host draws field: a kind it knows, a title it has, and for a
// choice a name for every option.
func (f *runConfigForm) drawable(language i18n.Language, field core.RunEditorField) bool {
	if _, ok := runConfigFieldTitle(language, field); !ok {
		return false
	}
	switch field.Kind {
	case runFieldCheckbox:
		return f.flags[field.ID] != nil
	case runFieldEnvironment:
		return f.environment != nil
	case runFieldBeforeLaunch:
		return f.beforeLaunch != nil
	case runFieldChoice:
		for _, option := range field.Options {
			if _, ok := runConfigOptionTitle(language, field, option); !ok {
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

// drawRunConfigFormFields declares the header row, then every other field that shows for the
// edited values, and last the Before Launch section, which spans the form as IDEA's does. A
// wrong value's reason sits under its field; one for a field not drawn sits at the end.
func (a *App) drawRunConfigFormFields(c ui.C, p *project, f *runConfigForm, ready bool) {
	if f.fields == nil {
		return
	}
	language := a.language()
	values := f.collect()
	drawn := map[string]bool{}
	var header, body, sections []core.RunEditorField
	for _, field := range f.fields {
		if !f.drawable(language, field) || !visibleRunConfigField(field, values) {
			continue
		}
		drawn[field.ID] = true
		switch {
		case field.Kind == runFieldBeforeLaunch:
			sections = append(sections, field)
		case field.Placement == "header":
			header = append(header, field)
		default:
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
			a.drawRunConfigFormError(c, f, field.ID, 0)
		}
		ui.Divider(c)
	}
	for _, field := range body {
		a.drawRunConfigFormField(c.Key(field.ID), p, f, field, ready)
	}
	for _, field := range sections {
		k := c.Key(field.ID)
		title, _ := runConfigFieldTitle(language, field)
		ui.Column(k).FillWidth().Gap(4).Children(func() {
			a.drawRunConfigBeforeLaunch(k, p, f.beforeLaunch, title, runConfigFieldHelp(language, f.kind.provider, field), field.Candidates, field.Tasks, ready, func() { a.runConfigFormEdited(p, f) })
			a.drawRunConfigFormError(c, f, field.ID, 0)
		})
	}
	for _, wrong := range f.fields {
		if !drawn[wrong.ID] {
			a.drawRunConfigFormError(c, f, wrong.ID, 0)
		}
	}
}

// drawRunConfigFormHeaderField declares a field of the top row: the name grows, a checkbox
// keeps its size.
func (a *App) drawRunConfigFormHeaderField(c ui.C, p *project, f *runConfigForm, field core.RunEditorField, ready bool) {
	language := a.language()
	label, _ := runConfigFieldTitle(language, field)
	if field.Kind == runFieldCheckbox {
		ui.Row(c).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
			if ui.Checkbox(c, f.flags[field.ID], label).Disabled(!ready).Changed() {
				c.After(func() { a.runConfigFormEdited(p, f) })
			}
			a.runConfigFormHelp(c, language, f.kind.provider, field)
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
	label, _ := runConfigFieldTitle(language, field)
	tall := field.Kind == runFieldMultilineText || field.Kind == runFieldEnvironment
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		row := ui.Row(c).FillWidth().Gap(12)
		if tall {
			row = row.Items(ui.Start)
		} else {
			row = row.Items(ui.Center)
		}
		// The title sits level with the first row of a multiline text field, whose rows start at
		// its top.
		titleHeight := float32(28)
		if field.Kind == runFieldMultilineText {
			titleHeight = runConfigTextAreaHeight(c.Theme(), 1)
		}
		row.Children(func() {
			ui.Row(c.Part("title")).Width(runConfigFormLabelWidth).MinHeight(titleHeight).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
				if field.Kind != runFieldCheckbox {
					ui.Text(c, label).Ellipsis().Shrink(1).MinWidth(0)
					a.runConfigFormHelp(c, language, f.kind.provider, field)
				}
			})
			if field.Kind == runFieldCheckbox {
				ui.Row(c).Grow(1).Items(ui.Center).Gap(4).Children(func() {
					if ui.Checkbox(c, f.flags[field.ID], label).Disabled(!ready).Changed() {
						c.After(func() { a.runConfigFormEdited(p, f) })
					}
					a.runConfigFormHelp(c, language, f.kind.provider, field)
				})
				return
			}
			a.drawRunConfigFormControl(c, p, f, field, label, ready)
		})
		a.drawRunConfigFormError(c, f, field.ID, runConfigFormLabelWidth+12)
	})
}

// drawRunConfigFormControl declares the control of a field by its kind, with the placeholder
// runConfigFieldPlaceholder gives it.
func (a *App) drawRunConfigFormControl(c ui.C, p *project, f *runConfigForm, field core.RunEditorField, label string, ready bool) {
	language := a.language()
	placeholder := runConfigFieldPlaceholder(language, field)
	edited := func() { c.After(func() { a.runConfigFormEdited(p, f) }) }
	switch field.Kind {
	case runFieldEnvironment:
		a.drawRunConfigVariables(c, p, f, ready)
	case runFieldChoice:
		options := field.Options
		if ui.Choice(c, f.texts[field.ID], options, func(option string) string {
			name, _ := runConfigOptionTitle(language, field, option)
			return name
		}).Disabled(!ready).Changed() {
			edited()
		}
	case runFieldMultilineText:
		// The field is declared first: that brings the text up to what was just typed, and the
		// field is sized by it in the same paint. MinHeight replaces the textarea's own minimum
		// of several rows, so one row is one row.
		box := ui.TextArea(c, f.texts[field.ID], label, placeholder)
		area := f.textArea(field.ID)
		height := runConfigTextAreaHeight(c.Theme(), area.rows(c, *f.texts[field.ID]))
		if box.Grow(1).MinWidth(0).MinHeight(height).Height(height).Draw(area.hook).Disabled(!ready).Changed() {
			edited()
		}
	case runFieldFile, runFieldExecutable, runFieldDirectory:
		// A program Core names a shell family for is chosen from the installed shells.
		if field.Kind == runFieldExecutable && a.drawRunConfigShellPicker(c, p, f, field, label, ready) {
			return
		}
		box := ui.TextField(c, f.texts[field.ID], label, placeholder).Grow(1).MinWidth(0).Disabled(!ready).
			Action(icons.FolderOpen, i18n.Shared(language, "desktop.runConfig.browse"))
		if box.Changed() {
			edited()
		}
		if box.ActionClicked() {
			c.After(func() { a.browseRunConfigField(p, f, field, label) })
		}
	default:
		if ui.TextField(c, f.texts[field.ID], label, placeholder).Grow(1).MinWidth(0).Disabled(!ready).Changed() {
			edited()
		}
	}
}

// runConfigTextArea sizes a multiline text field to its text, from one row up to
// runConfigFormTextRows, after which the field scrolls. The rows wrap at the width the field
// was laid out at, which only its paint knows: hook keeps that width, and asks for another
// paint when it changes so the field is sized afresh. layout counts the rows as the field's
// own layout wraps them; that one is the field's and not readable here.
type runConfigTextArea struct {
	width  float32
	layout components.TextareaLayout
	hook   func(*ui.DrawContext)
}

// textArea is the sizing of the multiline text field id, made on first use.
func (f *runConfigForm) textArea(id string) *runConfigTextArea {
	if f.areas == nil {
		f.areas = map[string]*runConfigTextArea{}
	}
	area := f.areas[id]
	if area == nil {
		area = &runConfigTextArea{}
		area.hook = func(d *ui.DrawContext) {
			if d.Rect.Width != area.width {
				area.width = d.Rect.Width
				d.Canvas.RequestFrame()
			}
		}
		f.areas[id] = area
	}
	return area
}

// rows is how many rows value takes in the field, between one and runConfigFormTextRows. A
// final newline starts a row of its own. Before the field's first paint the lines are counted
// without wrapping.
func (area *runConfigTextArea) rows(c ui.C, value string) int {
	rows := strings.Count(value, "\n") + 1
	if canvas := c.Canvas(); canvas != nil && area.width > 0 {
		rows = area.layout.RowCount(canvas, *c.Theme(), value, area.width, false)
	}
	return min(max(rows, 1), runConfigFormTextRows)
}

// runConfigTextAreaHeight is the height of a multiline text field showing rows rows: the rows
// at the line height Viva's textarea paints them with (the font size plus 7, its text-sm
// leading) and the margin it keeps above and below them.
func runConfigTextAreaHeight(theme *ui.Theme, rows int) float32 {
	return float32(rows)*(theme.Metrics.FontSizeM+7) + 2*components.TextareaPadY
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
					c.After(func() { a.runConfigFormEdited(p, f) })
				}
				if ui.TextField(k.Part("value"), &variable.value, valueLabel, valueLabel).Grow(1).MinWidth(0).Disabled(!ready).Changed() {
					c.After(func() { a.runConfigFormEdited(p, f) })
				}
				if a.gitIconButton(k.Part("remove"), i18n.Shared(language, "desktop.runConfig.variableRemove"), icons.Trash2, false, !ready) {
					c.After(func() {
						f.environment = removeRunConfigVariable(f.environment, variable)
						a.runConfigFormEdited(p, f)
					})
				}
			})
		}
		if ui.Button(c.Part("add"), i18n.Shared(language, "desktop.runConfig.variableAdd")).Icon(icons.Plus).Ghost().Disabled(!ready).Clicked() {
			c.After(func() {
				f.environment = append(f.environment, &runConfigVariable{})
				f.dirty = true
			})
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
func (a *App) runConfigFormHelp(c ui.C, language i18n.Language, provider string, field core.RunEditorField) {
	if help := runConfigFieldHelp(language, provider, field); help != "" {
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
	ui.Row(c.Key("error:"+field)).FillWidth().PadSides(0, 0, 0, indent).Children(func() {
		ui.Paragraph(c, runConfigFieldError(a.language(), code), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
	})
}
