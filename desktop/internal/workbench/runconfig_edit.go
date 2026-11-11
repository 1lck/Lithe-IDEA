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
