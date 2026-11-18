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

// This file holds the editor of built-in process runs, shown in the Run/Debug Configurations
// dialog: shell, PowerShell and batch scripts and programs, and of the kinds plugins declare
// for their build systems, such as a Go build. Core describes the editor as data (`runConfig.editorForm`): the fields in
// order, their kinds and current values, and the automatic value of each empty field. Core
// also checks the values and returns the file changes that save them
// (`runConfig.saveConfiguration`); the host draws the fields, applies the changes and
// resolves the configurations again. A field this host cannot draw (a kind it does not
// know, or an ID it has no label for) is left out and its value goes back as it came, so a
// later Core can add fields, options and buttons' inputs without breaking this host. A new
// field shows here once it has a label in runConfigFieldLabel and a widget for its kind; a
// field a plugin declares brings its own translated label.

// runConfigKind is a kind of configuration a form edits: a built-in process run by its
// provider, or, with provider `build.run-type`, the kind runType a plugin declares.
type runConfigKind struct {
	provider string
	runType  core.RunTypeKey
}

// builtInKind is the built-in kind of provider.
func builtInKind(provider string) runConfigKind { return runConfigKind{provider: provider} }

// declaredKind is the kind a plugin declares, named by key.
func declaredKind(key core.RunTypeKey) runConfigKind {
	return runConfigKind{provider: core.RunTypeProvider, runType: key}
}

// declared says a plugin declares the kind.
func (k runConfigKind) declared() bool { return k.runType != core.RunTypeKey{} }

// key is the declared kind's key as a request names it, nil for a built-in kind.
func (k runConfigKind) key() *core.RunTypeKey {
	if !k.declared() {
		return nil
	}
	key := k.runType
	return &key
}

// runConfigKindOf is the kind a form edits configuration as: a built-in process run, or a
// kind a plugin declares; ok is false for a configuration no form edits.
func runConfigKindOf(configuration core.RunConfiguration) (runConfigKind, bool) {
	if configuration.IsProcess() {
		return builtInKind(configuration.Provider), true
	}
	if key, ok := configuration.RunTypeReference(); ok {
		return declaredKind(key), true
	}
	return runConfigKind{}, false
}

// groupKey is the dialog group of the configurations of kind k: one per built-in kind, and one
// per declared kind, apart from the build system's other runs.
func (k runConfigKind) groupKey() string {
	if !k.declared() {
		return runProcessKindKey(k.provider)
	}
	return runProcessKindKey(k.provider) + ":" + k.runType.PluginID + "\x00" + k.runType.BuildSystemID + "\x00" + k.runType.Type
}

// runConfigKindOfType is the kind of a kind Core lists.
func runConfigKindOfType(kind core.RunConfigurationType) runConfigKind {
	if kind.RunType != nil {
		return declaredKind(*kind.RunType)
	}
	return builtInKind(kind.Provider)
}

// runConfigForm is the editor of one built-in process run, or of a configuration of a kind a
// plugin declares, in the Run/Debug Configurations dialog (runconfig_dialog.go). Each configuration the dialog shows has its own, so edits to
// several configurations wait together for Apply or OK.
type runConfigForm struct {
	// open is cleared when the dialog drops the form; answers still out are then ignored.
	open bool
	// generation rejects the answer of a form that was dropped or reopened since.
	generation uint64
	kind       runConfigKind
	// id is the saved configuration edited; empty for a new one until a save names it.
	id string
	// name is the configuration's name as it was saved.
	name            string
	loading, saving bool
	failure         string
	// dirty says a value changed since the form was read or last saved.
	dirty bool
	// availability says why this platform cannot run the kind, such as a batch script
	// outside Windows; the form still edits and saves it.
	availability *core.RunAvailability
	fields       []core.RunEditorField
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
	// beforeLaunch is the IDs of the process runs that start before this one, in order; nil
	// until the form names the field. beforeLaunchMenu says the menu that adds one is open.
	beforeLaunch     []string
	beforeLaunchMenu bool
	// errors are the wrong values the last save reported: a code such as required by field ID.
	errors map[string]string
	// refreshing says an editorForm request for the edited values is out, so the automatic
	// values follow the edit; stale says a value changed since it was sent.
	refreshing, stale bool
	// shellPicks are the interpreter lists by field ID; shellsAsked says the installed shells
	// were looked for since the form opened.
	shellPicks  map[string]*runConfigShellPick
	shellsAsked bool
}

// runConfigVariable is one environment variable row of the editor.
type runConfigVariable struct {
	name, value string
}

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
	runFieldBeforeLaunch  = "beforeLaunch"
)

// runFieldTextual reports a kind whose value is one string.
func runFieldTextual(kind string) bool {
	switch kind {
	case runFieldText, runFieldChoice, runFieldFile, runFieldMultilineText, runFieldArguments, runFieldDirectory, runFieldExecutable:
		return true
	}
	return false
}

// loadRunConfigTypes reads which kinds a user can create: the built-in ones, which every
// platform lists, one it cannot run with the reason, and the ones enabled plugins declare. The
// first refresh of the project reads them; reload reads them again, as opening the dialog
// does, so a plugin installed or removed since, or another interface language, shows. The
// kinds in hand stay while a read is out, and a reload asked for meanwhile reads once more
// after it. A failure keeps them, or leaves them unread, so the next refresh asks again.
func (a *App) loadRunConfigTypes(p *project, reload bool) {
	s := &p.runConfigs
	if s.typesLoading {
		s.typesStale = s.typesStale || reload
		return
	}
	if s.types != nil && !reload {
		return
	}
	s.typesLoading, s.typesStale = true, false
	kernel, language := a.kernel, a.language()
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		kinds, err := a.readRunConfigKinds(ctx, kernel, language.Code())
		return func(a *App) {
			s := &p.runConfigs
			s.typesLoading = false
			if err != nil {
				a.backgroundFailed("run_config_types", err)
			} else {
				// Only kinds this host can name are offered: the built-in ones it has a title
				// for, and declared ones that bring theirs. The list is never nil once read.
				s.types = make([]core.RunConfigurationType, 0, len(kinds.types))
				for _, kind := range kinds.types {
					_, named := runConfigTypeLabel(language, kind.Provider)
					if named || kind.RunType != nil && kind.DisplayName != "" {
						s.types = append(s.types, kind)
					}
				}
				s.typePlugins = kinds.plugins
			}
			if s.typesStale {
				a.loadRunConfigTypes(p, true)
			}
		}
	})
}

// openRunConfigForm reads the editor of a new configuration of kind, or of the saved
// configuration id when it is set. values seed a new configuration, such as a copy of
// another; nil starts from Core's defaults.
func (a *App) openRunConfigForm(p *project, kind runConfigKind, id string, values map[string]json.RawMessage) *runConfigForm {
	f := &runConfigForm{open: true, generation: 1, kind: kind, id: id, loading: true}
	if configuration := p.runConfigs.configuration(id); configuration != nil {
		f.name = configuration.Name
	}
	request := core.RunEditorFormRequest{Root: p.root, Provider: kind.provider, RunType: kind.key(), ConfigurationID: id, Values: values}
	a.requestRunConfigForm(p, f, f.generation, request, true)
	return f
}

// close drops the form; answers still out are ignored.
func (f *runConfigForm) close() {
	f.generation++
	f.open, f.loading, f.saving, f.refreshing, f.stale = false, false, false, false, false
}

// ready says the form is read and not being saved, so its values can be edited and saved.
func (f *runConfigForm) ready() bool {
	return f.open && !f.loading && !f.saving && f.fields != nil
}

// requestRunConfigForm asks Core for the editor. The first answer fills the fields and
// values; a later one, for the values being edited, only replaces the field descriptions,
// so the automatic values follow the edit and nothing the user typed since is lost.
// A declared kind's request carries the plugins that declare kinds, so its fields read in
// the interface language.
func (a *App) requestRunConfigForm(p *project, f *runConfigForm, generation uint64, request core.RunEditorFormRequest, initial bool) {
	kernel, kinds, language := a.kernel, p.runConfigs.kinds(), a.language().Code()
	declared := f.kind.declared()
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		if declared {
			request.RunTypePlugins = a.runTypePlugins(ctx, kernel, kinds, language)
		}
		form, err := kernel.RunEditorForm(ctx, request)
		return func(a *App) {
			if !f.open || f.generation != generation {
				return
			}
			if !initial {
				a.finishRunConfigFormRefresh(p, f, form, err)
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
			if !f.kind.answeredBy(form) {
				a.operationRejected("run_config_form", "form_mismatch")
				f.failure = i18n.Shared(language, "desktop.runConfig.formTooNew")
				return
			}
			f.fields, f.values, f.availability = form.Fields, form.Values, form.Availability
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
func (a *App) finishRunConfigFormRefresh(p *project, f *runConfigForm, form core.RunEditorForm, err error) {
	f.refreshing = false
	switch {
	case err != nil:
		// The descriptions in hand stay; only their automatic values may be out of date.
		a.backgroundFailed("run_config_form_refresh", err)
	case form.FormVersion > core.RunFormVersion || !f.kind.answeredBy(form):
		a.operationRejected("run_config_form_refresh", "form_mismatch")
	default:
		f.fields, f.availability = form.Fields, form.Availability
		f.readValues(form.Fields, form.Values)
	}
	if f.stale {
		a.refreshRunConfigForm(p, f)
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
		case field.Kind == runFieldBeforeLaunch:
			if f.beforeLaunch == nil {
				f.beforeLaunch = []string{}
				if known {
					_ = json.Unmarshal(raw, &f.beforeLaunch)
				}
				if f.beforeLaunch == nil {
					f.beforeLaunch = []string{}
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
		case field.Kind == runFieldBeforeLaunch && f.beforeLaunch != nil:
			value = f.beforeLaunch
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

// answeredBy says form is the editor of the kind: the provider, and for a declared kind its
// key, are the ones asked for.
func (k runConfigKind) answeredBy(form core.RunEditorForm) bool {
	if form.Provider != k.provider {
		return false
	}
	if !k.declared() {
		return form.RunType == nil
	}
	return form.RunType != nil && *form.RunType == k.runType
}

// runConfigFormEdited marks the form changed and asks for the editor of the edited values.
func (a *App) runConfigFormEdited(p *project, f *runConfigForm) {
	if !f.open || f.loading || f.fields == nil {
		return
	}
	f.dirty = true
	a.refreshRunConfigForm(p, f)
}

// refreshRunConfigForm asks for the editor of the edited values, so automatic values such as
// the interpreter a script's first line names follow the edit. One request is out at a
// time; an edit made while it is out sends one more when it answers.
func (a *App) refreshRunConfigForm(p *project, f *runConfigForm) {
	if !f.open || f.loading || f.fields == nil {
		return
	}
	if f.refreshing {
		f.stale = true
		return
	}
	f.refreshing, f.stale = true, false
	request := core.RunEditorFormRequest{Root: p.root, Provider: f.kind.provider, RunType: f.kind.key(), ConfigurationID: f.id, Values: f.collect()}
	a.requestRunConfigForm(p, f, f.generation, request, false)
}

// saveRunConfigForm has Core check the values and compute the file changes and applies them
// as one transaction; done gets the saved configuration's ID, or ok false. Wrong values stay
// in the form with the reason beside each field, and any other failure under the fields.
// The caller resolves the configurations again.
func (a *App) saveRunConfigForm(p *project, f *runConfigForm, done func(id string, ok bool)) {
	if !f.ready() {
		done("", false)
		return
	}
	f.saving, f.failure = true, ""
	generation := f.generation
	request := core.RunConfigurationSave{Root: p.root, Provider: f.kind.provider, RunType: f.kind.key(), ConfigurationID: f.id, Values: f.collect()}
	kernel, kinds, language := a.kernel, p.runConfigs.kinds(), a.language().Code()
	declared := f.kind.declared()
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		request.Plugins = a.runConfigPlugins(ctx)
		if declared {
			request.RunTypePlugins = a.runTypePlugins(ctx, kernel, kinds, language)
		}
		saved, err := kernel.SaveRunConfiguration(ctx, request)
		if err == nil && saved.Status == "saved" {
			err = applyRunConfigChanges(ctx, request.Root, saved.Changes)
		} else if err == nil && saved.Status != "invalid" {
			err = errors.New("runConfig.saveConfiguration returned an unknown status")
		}
		return func(a *App) {
			current := f.open && f.generation == generation
			if current {
				f.saving = false
			}
			if err != nil {
				a.operationFailed("run_config_save", err)
				if current {
					f.failure = a.runConfigSaveFailure(err)
				}
				done("", false)
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
				done("", false)
				return
			}
			if current {
				f.errors, f.id, f.dirty = nil, saved.ID, false
				if name := f.texts["name"]; name != nil && strings.TrimSpace(*name) != "" {
					f.name = strings.TrimSpace(*name)
				}
			}
			done(saved.ID, true)
		}
	})
}

// deleteRunConfiguration removes a saved `user:` configuration from every layer file, for
// the Build window's Delete, and resolves the configurations again.
func (a *App) deleteRunConfiguration(p *project, id string) {
	a.removeRunConfiguration(p, id, func(err error) {
		if err != nil {
			a.notifyError(i18n.SharedFormat(a.language(), "desktop.runConfig.deleteFailed", map[string]string{"reason": err.Error()}))
		}
		a.refreshRunConfigurations(p)
	})
}

// removeRunConfiguration has Core compute the file changes that remove a saved `user:`
// configuration from every layer and applies them; done gets the failure, logged already.
func (a *App) removeRunConfiguration(p *project, id string, done func(error)) {
	root, kernel := p.root, a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		changes, err := kernel.DeleteRunConfiguration(ctx, root, id, a.runConfigPlugins(ctx))
		if err == nil {
			err = applyRunConfigChanges(ctx, root, changes)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("run_config_delete", err)
			}
			done(err)
		}
	})
}

// browseRunConfigField asks for a file or a directory and puts its path in the field. A
// path inside the project is shown project-relative, as Core saves it; a program there
// keeps a leading "./", so it does not read as a name looked up on PATH.
func (a *App) browseRunConfigField(p *project, f *runConfigForm, field core.RunEditorField, title string) {
	generation, root := f.generation, p.root
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
			text := f.texts[field.ID]
			if !f.open || f.generation != generation || text == nil {
				return
			}
			*text = runConfigFieldPath(root, path, field.Kind)
			a.runConfigFormEdited(p, f)
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
