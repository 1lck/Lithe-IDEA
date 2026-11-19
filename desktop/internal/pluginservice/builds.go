package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// BuildPlugin is one enabled plugin's build declaration. Core still validates
// and plans every command; this is only the catalog the Build window presents.
type BuildPlugin struct {
	PluginID  string
	Version   string
	Directory string
	Manifest  json.RawMessage
	// Systems maps a build-system ID to its provider-owned tasks and runs.
	Systems map[string]BuildSystemDeclaration
}

// BuildSystemDeclaration is the presentation part of one validated build
// system. The fields are generic; no host decision depends on an ID.
type BuildSystemDeclaration struct {
	ID          string
	DisplayName string
	// Provider is true when this system declares a plugin process. Each request still names
	// its own source: a provider system may read its model or dependencies with a command, so
	// the model's source (BuildInstance.ModelSource) and Dependencies.Source decide how a
	// request runs, not this.
	Provider bool
	Tasks    []BuildTaskDeclaration
	Runs     []BuildRunDeclaration
	// EntrypointRuns are the runs declared with entrypoints (buildProviders 1): the provider
	// names the entrypoints a source file holds, and each starts in its project without a
	// target. They never appear among Runs, which apply to targets.
	EntrypointRuns []BuildRunDeclaration
	// Test is the presentation part of the optional test declaration. Core
	// still owns whether a selection can run; the window only needs to know
	// that the system offers tests and on which scopes.
	Test *BuildTestDeclaration
	// Dependencies is the declared dependency request, nil when the system declares no
	// dependency scopes.
	Dependencies *BuildDependenciesDeclaration
}

// BuildDependenciesDeclaration is the presentation part of a dependency declaration: the
// scopes Core plans a request for. Core refuses any other scope
// (plugin.build.invalidSelection), so the window offers the tree only where it is declared.
type BuildDependenciesDeclaration struct {
	Scopes []string
	// Source is "command" or "provider": where the tree comes from. A system with a provider
	// process may still read its tree with a command, so this, not Provider, picks the path.
	Source string
}

// BuildTestDeclaration is one build system's declared test entry.
type BuildTestDeclaration struct {
	Scopes []string
	// TargetTags are the tags a target must carry for a target-scope test run; none accept
	// every target. Core refuses a target without them; the window only hides the entry.
	TargetTags []string
	// Source is "command" or "provider"; the window does not interpret it
	// beyond choosing how to present the run.
	Source    string
	Discovery bool
	// DiscoveryCommand selects the command path for an enabled discovery action.
	DiscoveryCommand bool
}

// BuildTaskDeclaration is one task the Build window may offer.
type BuildTaskDeclaration struct {
	ID          string
	DisplayName string
	Description string
	Group       string
	// Category lists the headings, outermost first, the window files the task under; empty
	// files it by Group. On a fromModel template it is the default of the tasks the model lists.
	Category []string
	Scopes   []string
	// TargetTags are the tags a target must carry for a target-scope run; none accept every
	// target.
	TargetTags            []string
	RequiresUserArguments bool
	FromModel             bool
	Source                string
}

// EntryName is the run configuration of the run on target: the run's declared name before the
// target's, or the target's name alone when the run declares none, as the contract's run.name
// says.
func (r BuildRunDeclaration) EntryName(target string) string {
	if r.Name == "" {
		return target
	}
	return r.Name + " " + target
}

// ActionName is what a menu entry that runs the run on target says: the run's declared name, or
// the target's name when the run declares none.
func (r BuildRunDeclaration) ActionName(target string) string {
	if r.Name == "" {
		return target
	}
	return r.Name
}

// BuildRunDeclaration is one provider-owned application, service, or task run.
type BuildRunDeclaration struct {
	ID string
	// Name is the entry name the run declares, empty when it declares none: the contract then
	// names each entry after its target (EntryName, ActionName).
	Name      string
	Execution string
	Tags      []string
	// DebugAdapter is the local ID of the plugin's own adapter the run declares for native
	// debug preparation (`debug.adapter`), empty when the run does not debug that way.
	DebugAdapter string
	// DebugConfigurationType is the public debug adapter type a service run declares for
	// registry connection debugging (`debug.configurationType`): the run listens on a port the
	// host chooses, and the one enabled adapter of that type attaches to it. Empty when the
	// run does not debug that way.
	DebugConfigurationType string
}

// Debuggable reports whether the run declares a way to debug it.
func (r BuildRunDeclaration) Debuggable() bool {
	return r.DebugAdapter != "" || r.DebugConfigurationType != ""
}

// BuildPlugins reads the newest enabled version of every plugin that declares
// build systems. A broken manifest is reported without hiding the others.
func (s *Service) BuildPlugins(ctx context.Context, entries []pluginmanager.Entry) ([]BuildPlugin, error) {
	var plugins []BuildPlugin
	var failures []error
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	if selectionErr != nil {
		failures = append(failures, selectionErr)
	}
	for _, entry := range selected {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		systems, err := parseBuildSystems(manifest)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		if len(systems) == 0 {
			continue
		}
		plugins = append(plugins, BuildPlugin{
			PluginID:  entry.Installed.ID,
			Version:   entry.Installed.Version,
			Directory: entry.Installed.Path,
			Manifest:  manifest,
			Systems:   systems,
		})
	}
	return plugins, errors.Join(failures...)
}

type rawBuildManifest struct {
	BuildSystems []struct {
		ID          string          `json:"id"`
		DisplayName string          `json:"displayName"`
		Provider    json.RawMessage `json:"provider"`
		Tasks       []struct {
			ID                    string   `json:"id"`
			DisplayName           string   `json:"displayName"`
			Description           string   `json:"description"`
			Group                 string   `json:"group"`
			Category              []string `json:"category"`
			Scopes                []string `json:"scopes"`
			TargetTags            []string `json:"targetTags"`
			RequiresUserArguments bool     `json:"requiresUserArguments"`
			FromModel             bool     `json:"fromModel"`
			Source                string   `json:"source"`
		} `json:"tasks"`
		Run []struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			Source      string `json:"source"`
			Execution   string `json:"execution"`
			Entrypoints bool   `json:"entrypoints"`
			FromTargets *struct {
				Tags []string `json:"tags"`
			} `json:"fromTargets"`
			Debug *struct {
				Adapter           string `json:"adapter"`
				ConfigurationType string `json:"configurationType"`
			} `json:"debug"`
		} `json:"run"`
		Test *struct {
			Scopes           []string  `json:"scopes"`
			TargetTags       []string  `json:"targetTags"`
			Source           string    `json:"source"`
			Discovery        bool      `json:"discovery"`
			DiscoveryCommand *struct{} `json:"discoveryCommand"`
		} `json:"test"`
		Dependencies *struct {
			Scopes []string `json:"scopes"`
			Source string   `json:"source"`
		} `json:"dependencies"`
	} `json:"buildSystems"`
}

func parseBuildSystems(manifest json.RawMessage) (map[string]BuildSystemDeclaration, error) {
	var decoded rawBuildManifest
	if err := json.Unmarshal(manifest, &decoded); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrPackageRead, err)
	}
	systems := make(map[string]BuildSystemDeclaration, len(decoded.BuildSystems))
	for _, raw := range decoded.BuildSystems {
		if raw.ID == "" {
			continue
		}
		system := BuildSystemDeclaration{
			ID:          raw.ID,
			DisplayName: raw.DisplayName,
			Provider:    len(raw.Provider) != 0 && string(raw.Provider) != "null",
		}
		for _, task := range raw.Tasks {
			if task.ID == "" {
				continue
			}
			system.Tasks = append(system.Tasks, BuildTaskDeclaration{
				ID:                    task.ID,
				DisplayName:           task.DisplayName,
				Description:           task.Description,
				Group:                 task.Group,
				Category:              append([]string(nil), task.Category...),
				Scopes:                append([]string(nil), task.Scopes...),
				TargetTags:            append([]string(nil), task.TargetTags...),
				RequiresUserArguments: task.RequiresUserArguments,
				FromModel:             task.FromModel,
				Source:                task.Source,
			})
		}
		for _, run := range raw.Run {
			if run.ID != "" && run.Source == "provider" && run.Entrypoints {
				system.EntrypointRuns = append(system.EntrypointRuns, BuildRunDeclaration{ID: run.ID, Name: run.Name, Execution: "application"})
				continue
			}
			if run.ID == "" || run.Source != "provider" || run.FromTargets == nil {
				continue
			}
			declaration := BuildRunDeclaration{
				ID:        run.ID,
				Name:      run.Name,
				Execution: run.Execution,
				Tags:      append([]string(nil), run.FromTargets.Tags...),
			}
			if run.Debug != nil {
				declaration.DebugAdapter = run.Debug.Adapter
				declaration.DebugConfigurationType = run.Debug.ConfigurationType
			}
			system.Runs = append(system.Runs, declaration)
		}
		if raw.Test != nil {
			system.Test = &BuildTestDeclaration{
				Scopes:           append([]string(nil), raw.Test.Scopes...),
				TargetTags:       append([]string(nil), raw.Test.TargetTags...),
				Source:           raw.Test.Source,
				Discovery:        raw.Test.Discovery || raw.Test.DiscoveryCommand != nil,
				DiscoveryCommand: raw.Test.DiscoveryCommand != nil,
			}
		}
		if deps := raw.Dependencies; deps != nil && len(deps.Scopes) > 0 {
			system.Dependencies = &BuildDependenciesDeclaration{Scopes: append([]string(nil), deps.Scopes...), Source: deps.Source}
		}
		systems[raw.ID] = system
	}
	return systems, nil
}
