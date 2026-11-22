package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// runConfigEditor is the editor of one build provider run's options in the Run/Debug
// Configurations dialog (runconfig_dialog.go). It starts from the effective values Core
// resolved, and saving writes them into the chosen layer file, so the next resolve shows what
// took effect. Every field is bound to a widget by address and lives here, not in a paint's
// locals.
type runConfigEditor struct {
	// open is cleared when the dialog drops the editor; answers still out are then ignored.
	open bool
	// generation rejects the answer of an editor that was dropped since.
	generation uint64
	// baseline is the editor's fingerprint when it was read or last saved; see dirty.
	baseline    string
	id, name    string
	arguments   string
	directory   string
	environment string
	// scope is "local" or "project": which layer file the edit is saved into.
	// generated says the configuration is an unsaved generated entry, so explicitly
	// picking its Save-to scope marks the editor dirty even if it keeps "local".
	scope        string
	generated    bool
	explicitSave bool
	loading      bool
	saving       bool
	failure      string
	// provider says the configuration is a build provider run, whose choices are edited
	// too. runtimeArguments is one argument per line; entrypoint is the provider's entry.
	provider         bool
	runtimeArguments string
	entrypoint       string
	// options are the build option overrides saved for this configuration.
	options map[string]json.RawMessage
	// tools are the tool choices by qualified tool ID, with the kind of each choice ("home" or
	// "executable") and the path the editor shows. A cleared path sends null for that tool.
	tools []runConfigTool
	// optionFields are the build options the provider declares, shown for this run (runconfig_options.go).
	optionFields []runOptionField
	// installs are the installations the toolchain discovery found, offered by the picker; pick is
	// the picker's selection, 0 for none.
	installs []runConfigInstall
	pick     int
	// beforeLaunch is the steps that start first, as the editor shows them (runconfig_steps.go),
	// nil until Core read the list (`runConfig.beforeLaunchField`); savedBeforeLaunch is the
	// list it opened with, so a save that did not change it leaves the layers as they are.
	// beforeLaunchCandidates and beforeLaunchTasks are what a step may run.
	beforeLaunch           *runConfigSteps
	savedBeforeLaunch      []core.RunBeforeLaunchEntry
	beforeLaunchCandidates []core.RunConfigurationName
	beforeLaunchTasks      []core.RunTaskKind
}

// runConfigInstall is one discovered installation a tool choice can be set to.
type runConfigInstall struct {
	tool, toolName, kind, path, version string
}

// runConfigTool is one tool choice of a build provider run.
type runConfigTool struct {
	id, kind, path, initial string
}

// providerRunChoices is the build-run namespace of a configuration as Core resolved it.
type providerRunChoices struct {
	RuntimeArguments []string                     `json:"runtimeArguments"`
	Entrypoint       string                       `json:"entrypoint"`
	Options          map[string]json.RawMessage   `json:"options"`
	Tools            map[string]map[string]string `json:"tools"`
}

// runConfigProviderNamespace is the extension namespace of a build provider run's choices.
const runConfigProviderNamespace = "build-run"

// providerRunEditorState reads the provider choices of a configuration into the editor.
func providerRunEditorState(configuration core.RunConfiguration) (runConfigEditor, bool) {
	var state runConfigEditor
	if _, ok := configuration.BuildReference(); !ok {
		return state, false
	}
	var choices providerRunChoices
	if raw, ok := configuration.Extensions[runConfigProviderNamespace]; ok && len(raw) > 0 {
		if err := json.Unmarshal(raw, &choices); err != nil {
			choices = providerRunChoices{}
		}
	}
	state.provider = true
	state.runtimeArguments = strings.Join(choices.RuntimeArguments, "\n")
	state.entrypoint = choices.Entrypoint
	state.options = choices.Options
	ids := slices.Sorted(maps.Keys(choices.Tools))
	for _, id := range ids {
		for kind, path := range choices.Tools[id] {
			state.tools = append(state.tools, runConfigTool{id: id, kind: kind, path: path, initial: path})
		}
	}
	return state, true
}

// openRunConfigEditor reads the editor of configuration id, nil when it is not listed. The
// argument field fills once Core formatted the saved vector as reversible editor text.
func (a *App) openRunConfigEditor(p *project, id string) *runConfigEditor {
	configuration := p.runConfigs.configuration(id)
	if configuration == nil {
		return nil
	}
	e := &runConfigEditor{
		open: true, generation: 1, id: id, name: configuration.Name,
		directory: configuration.Cwd, environment: environmentText(configuration.Env),
		scope: "local", generated: configuration.Source == "generated", loading: true,
	}
	var buildInstance *buildInstance
	var optionSnapshot map[string]json.RawMessage
	if provider, ok := providerRunEditorState(*configuration); ok {
		e.provider, e.runtimeArguments, e.entrypoint, e.options, e.tools = true, provider.runtimeArguments, provider.entrypoint, provider.options, provider.tools
		if reference, ok := configuration.BuildReference(); ok {
			e.optionFields = p.runOptionFields(reference, e.options)
			if index := p.buildInstanceIndex(reference); index >= 0 {
				captured := p.build.instances[index]
				buildInstance = &captured
				optionSnapshot = make(map[string]json.RawMessage, len(e.options))
				for key, value := range e.options {
					optionSnapshot[key] = slices.Clone(value)
				}
			}
		}
		a.loadRunConfigInstalls(p, e, e.generation)
	}
	generation := e.generation
	args, kernel, root := slices.Clone(configuration.Args), a.kernel, p.root
	kinds, language := p.runConfigs.kinds(), a.language().Code()
	a.backgroundRunConfig(p, func(ctx context.Context) func(*App) {
		texts, err := kernel.RunArgumentText(ctx, [][]string{args})
		if err == nil && len(texts) != 1 {
			err = errors.New("runConfig.argumentText returned no text")
		}
		var steps core.RunBeforeLaunchField
		if err == nil {
			read := a.runTypeRead(ctx, kernel, kinds, language)
			steps, err = kernel.BeforeLaunchField(ctx, root, id, read.plugins)
			if err == nil {
				a.readRunTaskIcons(ctx, read, steps.Tasks)
			}
		}
		var resolvedFields []runOptionField
		if err == nil && buildInstance != nil {
			fields, resolveErr := resolveInstanceOptionFields(ctx, kernel, *buildInstance, optionSnapshot)
			if resolveErr != nil {
				a.backgroundFailedIn(ctx, "build_options_resolve", resolveErr)
			} else {
				resolvedFields = fields
			}
		}
		return func(a *App) {
			if !e.open || e.generation != generation {
				return
			}
			e.loading = false
			if err == nil {
				e.arguments = texts[0]
				e.beforeLaunch = newRunConfigSteps(slices.Clone(steps.Value))
				if e.beforeLaunch.items == nil {
					e.beforeLaunch.items = []core.RunBeforeLaunchEntry{}
				}
				e.savedBeforeLaunch = slices.Clone(e.beforeLaunch.items)
				e.beforeLaunchCandidates, e.beforeLaunchTasks = steps.Candidates, steps.Tasks
			} else {
				e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()})
			}
			if len(resolvedFields) != 0 {
				e.optionFields = resolvedFields
			}
			e.baseline = e.fingerprint()
		}
	})
	return e
}

// close drops the editor; answers still out are ignored.
func (e *runConfigEditor) close() {
	e.generation++
	e.open, e.loading, e.saving = false, false, false
}

// ready says the editor is read and not being saved.
func (e *runConfigEditor) ready() bool {
	return e.open && !e.loading && !e.saving
}

// fingerprint is every value the editor saves, so a change shows as a different one.
func (e *runConfigEditor) fingerprint() string {
	var steps []any
	if e.beforeLaunch != nil {
		for _, entry := range e.beforeLaunch.items {
			steps = append(steps, runConfigStepSaved(entry))
		}
	}
	values := []any{e.arguments, e.directory, e.environment, e.scope, e.runtimeArguments, e.entrypoint, steps}
	for _, tool := range e.tools {
		values = append(values, tool.id, tool.kind, tool.path)
	}
	for _, field := range e.optionFields {
		values = append(values, field.flag, field.text, field.picks)
	}
	raw, _ := json.Marshal(values)
	return string(raw)
}

// dirty says a value changed since the editor was read or last saved, or an
// unsaved generated configuration had its save scope explicitly chosen.
func (e *runConfigEditor) dirty() bool {
	return e.ready() && (e.explicitSave || e.fingerprint() != e.baseline)
}

// saveRunConfigEditor has Core apply the edit to the chosen layer and applies the file changes
// it returns; done gets whether it saved. A failure stays in the editor. The caller resolves
// the configurations again.
func (a *App) saveRunConfigEditor(p *project, e *runConfigEditor, done func(ok bool)) {
	if !e.ready() {
		done(false)
		return
	}
	environment, line := parseEnvironment(e.environment)
	if line > 0 {
		e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.environmentInvalid", map[string]string{"line": strconv.Itoa(line)})
		done(false)
		return
	}
	edit := core.RunOptionsEdit{
		Root: p.root, Scope: e.scope, ConfigurationID: e.id,
		WorkingDirectory: strings.TrimSpace(e.directory), Arguments: e.arguments, Environment: environment,
	}
	steps := e.savedBeforeLaunch
	if e.beforeLaunch != nil && !sameRunConfigSteps(e.beforeLaunch.items, e.savedBeforeLaunch) {
		steps = slices.Clone(e.beforeLaunch.items)
		edit.BeforeLaunch = &steps
	}
	kinds, language := p.runConfigs.kinds(), a.language().Code()
	var multiSelectEdits map[string][]string
	var multiSelectInstance *buildInstance
	var editorSnapshot runConfigEditor
	if e.provider {
		for _, field := range e.optionFields {
			if selected, changed := changedSelectedChoices(field); changed {
				if multiSelectEdits == nil {
					multiSelectEdits = map[string][]string{}
				}
				multiSelectEdits[field.id] = selected
			}
		}
		if len(multiSelectEdits) != 0 {
			if configuration := p.runConfigs.configuration(e.id); configuration != nil {
				if reference, ok := configuration.BuildReference(); ok {
					if index := p.buildInstanceIndex(reference); index >= 0 {
						captured := p.build.instances[index]
						multiSelectInstance = &captured
					}
				}
			}
		}
		editorSnapshot = *e
		editorSnapshot.options = maps.Clone(e.options)
		editorSnapshot.tools = slices.Clone(e.tools)
		applyRunOptionFields(&editorSnapshot)
	}
	e.saving, e.failure = true, ""
	generation, kernel := e.generation, a.kernel
	finish := func(err error) func(*App) {
		return func(a *App) {
			current := e.open && e.generation == generation
			if current {
				e.saving = false
			}
			if err != nil {
				if current {
					e.failure = a.runConfigSaveFailure(err)
				}
				done(false)
				return
			}
			if current {
				e.options = editorSnapshot.options
				for i := range e.optionFields {
					field := &e.optionFields[i]
					field.initFlag, field.initText, field.initPick = field.flag, field.text, slices.Clone(field.picks)
				}
				e.generated, e.explicitSave = false, false
				e.baseline, e.savedBeforeLaunch = e.fingerprint(), slices.Clone(steps)
			}
			done(true)
		}
	}
	a.backgroundRunConfig(p, func(ctx context.Context) func(*App) {
		if len(multiSelectEdits) != 0 && multiSelectInstance != nil {
			request := core.BuildResolveOptionsRequest{
				Options:          editorSnapshot.options,
				SelectedChoices:  multiSelectEdits,
				InheritedOptions: multiSelectInstance.Options,
			}
			if multiSelectInstance.modelLoaded {
				request.ModelValues = multiSelectInstance.Model.OptionValues
				request.ModelDefaults = multiSelectInstance.Model.OptionDefaults
				request.ModelExcludePrefixes = multiSelectInstance.Model.OptionExcludePrefixes
				request.ModelSelection = multiSelectInstance.Model.OptionSelection
			}
			resolved, err := kernel.ResolveBuildOptions(ctx, multiSelectInstance.Manifest, multiSelectInstance.BuildSystemID, request)
			if err != nil {
				return finish(err)
			}
			if editorSnapshot.options == nil {
				editorSnapshot.options = map[string]json.RawMessage{}
			}
			for _, option := range resolved.Options {
				if _, edited := multiSelectEdits[option.ID]; !edited {
					continue
				}
				if option.Source == "user" {
					editorSnapshot.options[option.ID] = option.Value
				} else {
					delete(editorSnapshot.options, option.ID)
				}
			}
		}
		if editorSnapshot.provider {
			raw, err := providerRunOptionsJSON(&editorSnapshot)
			if err != nil {
				return finish(err)
			}
			edit.ProviderRunOptions = raw
		}
		if edit.BeforeLaunch != nil {
			edit.RunTypePlugins = a.runTypePlugins(ctx, kernel, kinds, language)
		}
		return finish(a.saveRunConfigOptions(ctx, edit))
	})
}

// saveRunConfigOptions has Core compute the file changes of the edit and applies them as one
// transaction, only while every file still holds the bytes Core read.
func (a *App) saveRunConfigOptions(ctx context.Context, edit core.RunOptionsEdit) error {
	edit.Plugins = a.runConfigPlugins(ctx)
	changes, err := a.kernel.UpdateRunConfigurationOptions(ctx, edit)
	if err != nil {
		return err
	}
	return a.applyRunConfigChanges(ctx, edit.Root, changes)
}

// runConfigSaveFailure words a failed save: another edit that came first, or the reason.
func (a *App) runConfigSaveFailure(err error) string {
	if errors.Is(err, configfile.ErrConflict) {
		return i18n.Shared(a.language(), "desktop.runConfig.conflict")
	}
	return i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()})
}

// environmentText is the editor text of an environment: one KEY=VALUE line per
// variable, by name.
func environmentText(environment map[string]string) string {
	lines := make([]string, 0, len(environment))
	for _, key := range slices.Sorted(maps.Keys(environment)) {
		lines = append(lines, key+"="+environment[key])
	}
	return strings.Join(lines, "\n")
}

// parseEnvironment reads the editor text back. Blank lines are skipped; line is the
// 1-based number of the first other line without a name before "=", or 0.
func parseEnvironment(text string) (environment map[string]string, line int) {
	environment = map[string]string{}
	for index, raw := range strings.Split(text, "\n") {
		entry := strings.TrimRight(raw, "\r")
		if strings.TrimSpace(entry) == "" {
			continue
		}
		key, value, ok := strings.Cut(entry, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			return nil, index + 1
		}
		environment[key] = value
	}
	return environment, 0
}

// providerRunOptionsJSON is the typed snapshot the editor saves: the arguments and entrypoint
// the user sees, the option overrides carried over, and each tool path the user set. A tool whose
// path was emptied sends null, which clears the inherited choice.
func providerRunOptionsJSON(e *runConfigEditor) (json.RawMessage, error) {
	snapshot := core.ProviderRunOptionsSnapshot{
		RuntimeArguments: []string{},
		Entrypoint:       strings.TrimSpace(e.entrypoint),
		Options:          map[string]json.RawMessage{},
		Tools:            map[string]map[string]string{},
	}
	if e.runtimeArguments != "" {
		snapshot.RuntimeArguments = strings.Split(e.runtimeArguments, "\n")
	}
	maps.Copy(snapshot.Options, e.options)
	for _, tool := range e.tools {
		path := strings.TrimSpace(tool.path)
		switch {
		case path != "":
			snapshot.Tools[tool.id] = map[string]string{tool.kind: path}
		case strings.TrimSpace(tool.initial) != "":
			snapshot.Tools[tool.id] = nil
		}
	}
	return json.Marshal(snapshot)
}

// loadRunConfigInstalls reads the toolchain discovery the settings page reads, so the editor can offer
// the discovered installations. The answer is applied only while the same editor is open.
func (a *App) loadRunConfigInstalls(p *project, e *runConfigEditor, generation uint64) {
	a.backgroundRunConfig(p, func(ctx context.Context) func(*App) {
		snapshot, err := settingsToolchains{app: a}.Load(ctx)
		var installs []runConfigInstall
		for _, tool := range snapshot.Tools {
			for _, installation := range tool.Installations {
				install := runConfigInstall{tool: tool.ID, toolName: tool.DisplayName, path: installation.Home, kind: "home", version: installation.Version}
				if installation.Home == "" {
					install.path, install.kind = installation.Executable, "executable"
				}
				if install.path != "" {
					installs = append(installs, install)
				}
			}
		}
		return func(a *App) {
			if !e.open || e.generation != generation || err != nil {
				return
			}
			e.installs = installs
		}
	})
}

// pickRunConfigInstall sets the tool choice to the picked installation, replacing the tool's entry.
func (e *runConfigEditor) pickRunConfigInstall(install runConfigInstall) {
	for index := range e.tools {
		if e.tools[index].id == install.tool {
			e.tools[index] = runConfigTool{id: install.tool, kind: install.kind, path: install.path, initial: e.tools[index].initial}
			return
		}
	}
	e.tools = append(e.tools, runConfigTool{id: install.tool, kind: install.kind, path: install.path})
}
