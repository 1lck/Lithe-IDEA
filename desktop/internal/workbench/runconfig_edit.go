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

// The run configuration layers the editor writes, relative to the workspace root. Core
// reads the same files when it resolves; it never writes them.
const (
	runConfigLocalFile   = ".lithe/run/local.json"
	runConfigProjectFile = ".lithe/run/configurations.json"
	// runConfigMaximumBytes bounds the layer document the host captures and publishes.
	runConfigMaximumBytes = 4 << 20
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
	if provider, ok := providerRunEditorState(*configuration); ok {
		e.provider, e.runtimeArguments, e.entrypoint, e.options, e.tools = true, provider.runtimeArguments, provider.entrypoint, provider.options, provider.tools
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

// saveRunConfigEditor has Core apply the edit to the chosen layer and publishes the
// document it returns, then resolves the configurations again.
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
	if e.provider {
		raw, err := providerRunOptionsJSON(e)
		if err != nil {
			e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()})
			return
		}
		edit.ProviderRunOptions = raw
	}
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		err := saveRunConfigOptions(ctx, kernel, edit)
		return func(a *App) {
			e := &p.runConfigs.editor
			if !e.open || e.generation != generation {
				return
			}
			e.saving = false
			if err != nil {
				reason := err.Error()
				if errors.Is(err, configfile.ErrConflict) {
					e.failure = i18n.Shared(a.language(), "desktop.runConfig.conflict")
					return
				}
				e.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": reason})
				return
			}
			a.closeRunConfigEditor(p)
			a.refreshRunConfigurations(p)
		}
	})
}

// saveRunConfigOptions captures the scope's layer file, has Core edit it and publishes
// the result only if the file still holds the captured bytes. The local layer is
// handed to Core as captured, so the edit applies to exactly what is replaced.
func saveRunConfigOptions(ctx context.Context, kernel Kernel, edit core.RunOptionsEdit) error {
	name := runConfigProjectFile
	if edit.Scope == "local" {
		name = runConfigLocalFile
	}
	file, err := configfile.Capture(ctx, edit.Root, name, runConfigMaximumBytes)
	if err != nil {
		return err
	}
	if edit.Scope == "local" && file.Exists() {
		local := file.Bytes()
		if !json.Valid(local) {
			return errors.New(name + ": invalid JSON")
		}
		edit.LocalDocument = local
	}
	document, err := kernel.UpdateRunConfigurationOptions(ctx, edit)
	if err != nil {
		return err
	}
	_, err = file.Replace(ctx, []byte(document), nil)
	return err
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
