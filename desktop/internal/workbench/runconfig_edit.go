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

// runConfigEditor is the open editor of one configuration's options. It starts from
// the effective values Core resolved, and saving writes them into the chosen layer
// file, so the next resolve shows what took effect. Every field is bound to a widget
// by address and lives here, not in a paint's locals.
type runConfigEditor struct {
	open bool
	// generation rejects the answer of an editor that was closed or reopened since.
	generation  uint64
	id, name    string
	arguments   string
	directory   string
	environment string
	// scope is "local" or "project": which layer file the edit is saved into.
	scope   string
	loading bool
	saving  bool
	failure string
	// provider says the configuration is a build provider run, whose choices are edited
	// too. runtimeArguments is one argument per line; entrypoint is the provider's entry.
	provider         bool
	runtimeArguments string
	entrypoint       string
	// options are the build option overrides, kept as they were: this editor does not edit them.
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
	// beforeLaunch is the IDs of the process runs that start first, as the editor shows them;
	// savedBeforeLaunch is the list it opened with, so a save that did not change it leaves the
	// layers as they are. beforeLaunchMenu says the menu that adds a step is open.
	beforeLaunch, savedBeforeLaunch []string
	beforeLaunchMenu                bool
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

// openRunConfigEditor opens the editor on configuration id. The argument field fills
// once Core formatted the saved vector as reversible editor text.
func (a *App) openRunConfigEditor(p *project, id string) {
	configuration := p.runConfigs.configuration(id)
	if configuration == nil {
		return
	}
	e := &p.runConfigs.editor
	e.generation++
	generation := e.generation
	*e = runConfigEditor{
		open: true, generation: generation, id: id, name: configuration.Name,
		directory: configuration.Cwd, environment: environmentText(configuration.Env),
		scope: "local", loading: true,
	}
	for _, step := range configuration.BeforeLaunch {
		e.beforeLaunch = append(e.beforeLaunch, step.Configuration)
	}
	e.savedBeforeLaunch = slices.Clone(e.beforeLaunch)
	if provider, ok := providerRunEditorState(*configuration); ok {
		e.provider, e.runtimeArguments, e.entrypoint, e.options, e.tools = true, provider.runtimeArguments, provider.entrypoint, provider.options, provider.tools
		if reference, ok := configuration.BuildReference(); ok {
			e.optionFields = p.runOptionFields(reference, e.options)
		}
		a.loadRunConfigInstalls(p, generation)
	}
	args, kernel := slices.Clone(configuration.Args), a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		texts, err := kernel.RunArgumentText(ctx, [][]string{args})
		if err == nil && len(texts) != 1 {
			err = errors.New("runConfig.argumentText returned no text")
		}
		return func(a *App) {
			e := &p.runConfigs.editor
			if !e.open || e.generation != generation {
				return
			}
			e.loading = false
			if err != nil {
				e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()})
				return
			}
			e.arguments = texts[0]
		}
	})
}

func (a *App) closeRunConfigEditor(p *project) {
	e := &p.runConfigs.editor
	e.generation++
	e.open, e.loading, e.saving = false, false, false
}

// saveRunConfigEditor has Core apply the edit to the chosen layer, applies the file changes it
// returns, then resolves the configurations again.
func (a *App) saveRunConfigEditor(p *project) {
	e := &p.runConfigs.editor
	if !e.open || e.loading || e.saving {
		return
	}
	environment, line := parseEnvironment(e.environment)
	if line > 0 {
		e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.environmentInvalid", map[string]string{"line": strconv.Itoa(line)})
		return
	}
	e.saving, e.failure = true, ""
	generation := e.generation
	edit := core.RunOptionsEdit{
		Root: p.root, Scope: e.scope, ConfigurationID: e.id,
		WorkingDirectory: strings.TrimSpace(e.directory), Arguments: e.arguments, Environment: environment,
	}
	if !slices.Equal(e.beforeLaunch, e.savedBeforeLaunch) {
		steps := slices.Clone(e.beforeLaunch)
		if steps == nil {
			steps = []string{}
		}
		edit.BeforeLaunch = &steps
	}
	if e.provider {
		applyRunOptionFields(e)
		raw, err := providerRunOptionsJSON(e)
		if err != nil {
			e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()})
			return
		}
		edit.ProviderRunOptions = raw
	}
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		err := a.saveRunConfigOptions(ctx, edit)
		return func(a *App) {
			e := &p.runConfigs.editor
			if !e.open || e.generation != generation {
				return
			}
			e.saving = false
			if err != nil {
				e.failure = a.runConfigSaveFailure(err)
				return
			}
			a.closeRunConfigEditor(p)
			a.refreshRunConfigurations(p)
		}
	})
}

// beforeLaunchCandidates is the process runs configuration id can run first: every built-in
// process run that can start, other than itself, as Core allows them.
func (s *runConfigState) beforeLaunchCandidates(id string) []core.RunConfigurationName {
	var candidates []core.RunConfigurationName
	for _, configuration := range s.list {
		if configuration.ID != id && configuration.IsProcess() && !configuration.Unavailable() {
			candidates = append(candidates, core.RunConfigurationName{ID: configuration.ID, Name: configuration.Name})
		}
	}
	return candidates
}

// saveRunConfigOptions has Core compute the file changes of the edit and applies them as one
// transaction, only while every file still holds the bytes Core read.
func (a *App) saveRunConfigOptions(ctx context.Context, edit core.RunOptionsEdit) error {
	edit.Plugins = a.runConfigPlugins(ctx)
	changes, err := a.kernel.UpdateRunConfigurationOptions(ctx, edit)
	if err != nil {
		return err
	}
	return applyRunConfigChanges(ctx, edit.Root, changes)
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
func (a *App) loadRunConfigInstalls(p *project, generation uint64) {
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
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
			e := &p.runConfigs.editor
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
