package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// This file holds the editor of built-in process runs: shell, PowerShell and batch scripts
// and programs. Core describes the editor as data (`runConfig.editorForm`): the fields in
// order, their kinds and current values, and the automatic value of each empty field. Core
// also checks the values and returns the file changes that save them
// (`runConfig.saveConfiguration`); the host draws the fields, applies the changes and
// resolves the configurations again. A field this host cannot draw (a kind it does not
// know, or an ID it has no label for) is left out and its value goes back as it came, so a
// later Core can add fields, options and buttons' inputs without breaking this host. A new
// field shows here once it has a label in runConfigFieldLabel and a widget for its kind.

// runConfigForm is the open editor of a built-in process run.
type runConfigForm struct {
	open bool
	// generation rejects the answer of an editor that was closed or reopened since.
	generation uint64
	provider   string
	// id is the saved configuration edited; empty for a new one until a save names it.
	id string
	// name is the configuration's name as it was saved, for the dialog's title.
	name            string
	loading, saving bool
	failure         string
	fields          []core.RunEditorField
	// values are the values by field ID as Core returned them. A save sends them with the
	// drawn fields' edits over them, so keys this host does not show go back unchanged.
	values map[string]json.RawMessage
	// texts and flags are the edited text and checkbox values by field ID. They are
	// pointers, so each widget keeps the address it is bound by while the maps grow.
	texts map[string]*string
	flags map[string]*bool
	// environment is the variable rows in order; each row keeps its address while rows
	// are added or removed.
	environment []*runConfigVariable
	// errors are the wrong values the last save reported: a code such as required by field ID.
	errors map[string]string
	// refreshing says an editorForm request for the edited values is out, so the automatic
	// values follow the edit; stale says a value changed since it was sent.
	refreshing, stale bool
}

// runConfigVariable is one environment variable row of the editor.
type runConfigVariable struct {
	name, value string
}

// runConfigFormStep is what follows a save that succeeded.
type runConfigFormStep int

const (
	// runConfigFormApply keeps the editor open on the saved configuration.
	runConfigFormApply runConfigFormStep = iota
	// runConfigFormClose closes the editor.
	runConfigFormClose
	// runConfigFormRun closes the editor and runs the configuration once it is listed.
	runConfigFormRun
)

// Field kinds of `runConfig.editorForm` this host draws.
const (
	runFieldText          = "text"
	runFieldCheckbox      = "checkbox"
	runFieldChoice        = "choice"
	runFieldFile          = "file"
	runFieldMultilineText = "multilineText"
	runFieldArguments     = "arguments"
	runFieldDirectory     = "directory"
	runFieldEnvironment   = "environment"
	runFieldExecutable    = "executable"
)

// runFieldTextual reports a kind whose value is one string.
func runFieldTextual(kind string) bool {
	switch kind {
	case runFieldText, runFieldChoice, runFieldFile, runFieldMultilineText, runFieldArguments, runFieldDirectory, runFieldExecutable:
		return true
	}
	return false
}

// loadRunConfigTypes reads once per project which built-in kinds a user can create here.
// A failure leaves them unread, so the next refresh asks again.
func (a *App) loadRunConfigTypes(p *project) {
	s := &p.runConfigs
	if s.types != nil || s.typesLoading {
		return
	}
	s.typesLoading = true
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		types, err := kernel.RunConfigurationTypes(ctx)
		return func(a *App) {
			s := &p.runConfigs
			s.typesLoading = false
			if err != nil {
				a.backgroundFailed("run_config_types", err)
				return
			}
			// Only kinds this host can name are offered; the list is never nil once read.
			s.types = make([]core.RunConfigurationType, 0, len(types))
			for _, kind := range types {
				if _, ok := runConfigTypeLabel(a.language(), kind.Provider); ok {
					s.types = append(s.types, kind)
				}
			}
		}
	})
}

// openRunConfigForm opens the editor on a new configuration of provider, or on the saved
// configuration id when it is set.
func (a *App) openRunConfigForm(p *project, provider, id string) {
	f := &p.runConfigs.form
	generation := f.generation + 1
	*f = runConfigForm{open: true, generation: generation, provider: provider, id: id, loading: true}
	if configuration := p.runConfigs.configuration(id); configuration != nil {
		f.name = configuration.Name
	}
	a.requestRunConfigForm(p, generation, core.RunEditorFormRequest{Root: p.root, Provider: provider, ConfigurationID: id}, true)
}

// closeRunConfigForm closes the editor; answers still out are dropped.
func (a *App) closeRunConfigForm(p *project) {
	f := &p.runConfigs.form
	f.generation++
	f.open, f.loading, f.saving, f.refreshing, f.stale = false, false, false, false, false
}

// requestRunConfigForm asks Core for the editor. The first answer fills the fields and
// values; a later one, for the values being edited, only replaces the field descriptions,
// so the automatic values follow the edit and nothing the user typed since is lost.
func (a *App) requestRunConfigForm(p *project, generation uint64, request core.RunEditorFormRequest, initial bool) {
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		form, err := kernel.RunEditorForm(ctx, request)
		return func(a *App) {
			f := &p.runConfigs.form
			if !f.open || f.generation != generation {
				return
			}
			if !initial {
				a.finishRunConfigFormRefresh(p, form, err)
				return
			}
			f.loading = false
			language := a.language()
			if err != nil {
				a.operationFailed("run_config_form", err)
				f.failure = i18n.SharedFormat(language, "desktop.runConfig.loadFailed", map[string]string{"reason": err.Error()})
				return
			}
			if form.FormVersion > core.RunFormVersion {
				a.operationRejected("run_config_form", "form_version")
				f.failure = i18n.Shared(language, "desktop.runConfig.formTooNew")
				return
			}
			f.provider, f.fields, f.values = form.Provider, form.Fields, form.Values
			if f.values == nil {
				f.values = map[string]json.RawMessage{}
			}
			f.texts, f.flags = map[string]*string{}, map[string]*bool{}
			f.readValues(form.Fields, form.Values)
		}
	})
}

// finishRunConfigFormRefresh takes the field descriptions for the edited values. A field
// that appears only now takes its value from the answer.
func (a *App) finishRunConfigFormRefresh(p *project, form core.RunEditorForm, err error) {
	f := &p.runConfigs.form
	f.refreshing = false
	switch {
	case err != nil:
		// The descriptions in hand stay; only their automatic values may be out of date.
		a.backgroundFailed("run_config_form_refresh", err)
	case form.FormVersion > core.RunFormVersion || form.Provider != f.provider:
		a.operationRejected("run_config_form_refresh", "form_mismatch")
	default:
		f.fields = form.Fields
		f.readValues(form.Fields, form.Values)
	}
	if f.stale {
		a.runConfigFormEdited(p)
	}
}

// readValues takes the value of each drawn field that has no edited value yet.
func (f *runConfigForm) readValues(fields []core.RunEditorField, values map[string]json.RawMessage) {
	for _, field := range fields {
		raw, known := values[field.ID]
		if known {
			if _, ok := f.values[field.ID]; !ok {
				f.values[field.ID] = raw
			}
		}
		switch {
		case field.Kind == runFieldCheckbox:
			if f.flags[field.ID] == nil {
				flag := false
				if known {
					_ = json.Unmarshal(raw, &flag)
				}
				f.flags[field.ID] = &flag
			}
		case field.Kind == runFieldEnvironment:
			if f.environment == nil {
				f.environment = []*runConfigVariable{}
				var rows []struct {
					Name  string `json:"name"`
					Value string `json:"value"`
				}
				if known {
					_ = json.Unmarshal(raw, &rows)
				}
				for _, row := range rows {
					f.environment = append(f.environment, &runConfigVariable{name: row.Name, value: row.Value})
				}
			}
		case runFieldTextual(field.Kind):
			if f.texts[field.ID] == nil {
				text := ""
				if known {
					_ = json.Unmarshal(raw, &text)
				}
				f.texts[field.ID] = &text
			}
		}
	}
}

// collect is the values a save or a refresh sends: Core's values with every edited value
// over them. A value of a field this host does not draw goes back as it came.
func (f *runConfigForm) collect() map[string]json.RawMessage {
	values := maps.Clone(f.values)
	if values == nil {
		values = map[string]json.RawMessage{}
	}
	for _, field := range f.fields {
		var value any
		switch {
		case field.Kind == runFieldCheckbox && f.flags[field.ID] != nil:
			value = *f.flags[field.ID]
		case field.Kind == runFieldEnvironment && f.environment != nil:
			rows := make([]map[string]string, 0, len(f.environment))
			for _, row := range f.environment {
				rows = append(rows, map[string]string{"name": row.name, "value": row.value})
			}
			value = rows
		case runFieldTextual(field.Kind) && f.texts[field.ID] != nil:
			value = *f.texts[field.ID]
		default:
			continue
		}
		if raw, err := json.Marshal(value); err == nil {
			values[field.ID] = raw
		}
	}
	return values
}

// runConfigFormEdited asks for the editor of the edited values, so automatic values such as
// the interpreter a script's first line names follow the edit. One request is out at a
// time; an edit made while it is out sends one more when it answers.
func (a *App) runConfigFormEdited(p *project) {
	f := &p.runConfigs.form
	if !f.open || f.loading || f.fields == nil {
		return
	}
	if f.refreshing {
		f.stale = true
		return
	}
	f.refreshing, f.stale = true, false
	request := core.RunEditorFormRequest{Root: p.root, Provider: f.provider, ConfigurationID: f.id, Values: f.collect()}
	a.requestRunConfigForm(p, f.generation, request, false)
}

// saveRunConfigForm has Core check the values and compute the file changes, applies them as
// one transaction and resolves the configurations again. Wrong values stay in the editor
// with the reason beside each field.
func (a *App) saveRunConfigForm(p *project, step runConfigFormStep) {
	f := &p.runConfigs.form
	if !f.open || f.loading || f.saving || f.fields == nil {
		return
	}
	f.saving, f.failure = true, ""
	generation := f.generation
	request := core.RunConfigurationSave{Root: p.root, Provider: f.provider, ConfigurationID: f.id, Values: f.collect()}
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		request.Plugins = a.runConfigPlugins(ctx)
		saved, err := kernel.SaveRunConfiguration(ctx, request)
		if err == nil && saved.Status == "saved" {
			err = applyRunConfigChanges(ctx, request.Root, saved.Changes)
		} else if err == nil && saved.Status != "invalid" {
			err = errors.New("runConfig.saveConfiguration returned an unknown status")
		}
		return func(a *App) {
			f := &p.runConfigs.form
			current := f.open && f.generation == generation
			if current {
				f.saving = false
			}
			if err != nil {
				a.operationFailed("run_config_save", err)
				if current {
					f.failure = a.runConfigSaveFailure(err)
				}
				return
			}
			if saved.Status == "invalid" {
				a.operationRejected("run_config_save", "invalid_values")
				if current {
					f.errors = make(map[string]string, len(saved.Errors))
					for _, wrong := range saved.Errors {
						if _, seen := f.errors[wrong.Field]; !seen {
							f.errors[wrong.Field] = wrong.Code
						}
					}
				}
				return
			}
			s := &p.runConfigs
			s.reveal = saved.ID
			if current {
				f.errors, f.id = nil, saved.ID
				if name := f.texts["name"]; name != nil && strings.TrimSpace(*name) != "" {
					f.name = strings.TrimSpace(*name)
				}
				if step == runConfigFormRun {
					s.start = saved.ID
				}
				if step != runConfigFormApply {
					a.closeRunConfigForm(p)
				}
			}
			a.refreshRunConfigurations(p)
		}
	})
}

// deleteRunConfiguration removes a saved `user:` configuration from every layer file.
func (a *App) deleteRunConfiguration(p *project, id string) {
	root, kernel := p.root, a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		changes, err := kernel.DeleteRunConfiguration(ctx, root, id, a.runConfigPlugins(ctx))
		if err == nil {
			err = applyRunConfigChanges(ctx, root, changes)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("run_config_delete", err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.runConfig.deleteFailed", map[string]string{"reason": err.Error()}))
				return
			}
			if f := &p.runConfigs.form; f.open && f.id == id {
				a.closeRunConfigForm(p)
			}
			a.refreshRunConfigurations(p)
		}
	})
}

// browseRunConfigField asks for a file or a directory and puts its path in the field. A
// path inside the project is shown project-relative, as Core saves it; a program there
// keeps a leading "./", so it does not read as a name looked up on PATH.
func (a *App) browseRunConfigField(p *project, field core.RunEditorField, title string) {
	generation, root := p.runConfigs.form.generation, p.root
	a.background(nil, 0, func(context.Context) func(*App) {
		var path string
		var err error
		if field.Kind == runFieldDirectory {
			path, err = app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		} else {
			var paths []string
			paths, err = app.OpenFiles(app.OpenFileOptions{Title: title})
			if err == nil && len(paths) == 0 {
				err = app.ErrCanceled
			}
			if err == nil {
				path = paths[0]
			}
		}
		return func(a *App) {
			if errors.Is(err, app.ErrCanceled) {
				// log-exempt: 用户取消：未选择文件或目录，字段保持不变。
				return
			}
			if err != nil {
				a.operationFailed("run_config_browse", documentLogError(err))
				a.notifyError(i18n.Shared(a.language(), "desktop.runConfig.chooseFailed"))
				return
			}
			f := &p.runConfigs.form
			text := f.texts[field.ID]
			if !f.open || f.generation != generation || text == nil {
				return
			}
			*text = runConfigFieldPath(root, path, field.Kind)
			a.runConfigFormEdited(p)
		}
	})
}

// runConfigFieldPath is the text a browsed path shows in a field of kind.
func runConfigFieldPath(root, path, kind string) string {
	relative, err := filepath.Rel(root, path)
	if err != nil || !filepath.IsLocal(relative) && relative != "." {
		return path
	}
	relative = filepath.ToSlash(relative)
	if kind == runFieldExecutable && !strings.Contains(relative, "/") {
		return "./" + relative
	}
	return relative
}
