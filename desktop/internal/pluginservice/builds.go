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
	// Provider is true when this system answers model and task requests through
	// a plugin process instead of a command line.
	Provider bool
	Tasks    []BuildTaskDeclaration
	Runs     []BuildRunDeclaration
	// Test is the presentation part of the optional test declaration. Core
	// still owns whether a selection can run; the window only needs to know
	// that the system offers tests and on which scopes.
	Test *BuildTestDeclaration
}

// BuildTestDeclaration is one build system's declared test entry.
type BuildTestDeclaration struct {
	Scopes []string
	// Source is "command" or "provider"; the window does not interpret it
	// beyond choosing how to present the run.
	Source    string
	Discovery bool
}

// BuildTaskDeclaration is one task the Build window may offer.
type BuildTaskDeclaration struct {
	ID                    string
	DisplayName           string
	Group                 string
	Scopes                []string
	RequiresUserArguments bool
	FromModel             bool
	Source                string
}

// BuildRunDeclaration is one provider-owned application, service, or task run.
type BuildRunDeclaration struct {
	ID        string
	Name      string
	Execution string
	Tags      []string
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
			Group                 string   `json:"group"`
			Scopes                []string `json:"scopes"`
			RequiresUserArguments bool     `json:"requiresUserArguments"`
			FromModel             bool     `json:"fromModel"`
			Source                string   `json:"source"`
		} `json:"tasks"`
		Run []struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			Source      string `json:"source"`
			Execution   string `json:"execution"`
			FromTargets *struct {
				Tags []string `json:"tags"`
			} `json:"fromTargets"`
		} `json:"run"`
		Test *struct {
			Scopes    []string `json:"scopes"`
			Source    string   `json:"source"`
			Discovery bool     `json:"discovery"`
		} `json:"test"`
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
				Group:                 task.Group,
				Scopes:                append([]string(nil), task.Scopes...),
				RequiresUserArguments: task.RequiresUserArguments,
				FromModel:             task.FromModel,
				Source:                task.Source,
			})
		}
		for _, run := range raw.Run {
			if run.ID == "" || run.Source != "provider" || run.FromTargets == nil {
				continue
			}
			name := run.Name
			if name == "" {
				name = run.ID
			}
			system.Runs = append(system.Runs, BuildRunDeclaration{
				ID:        run.ID,
				Name:      name,
				Execution: run.Execution,
				Tags:      append([]string(nil), run.FromTargets.Tags...),
			})
		}
		if raw.Test != nil {
			system.Test = &BuildTestDeclaration{
				Scopes:    append([]string(nil), raw.Test.Scopes...),
				Source:    raw.Test.Source,
				Discovery: raw.Test.Discovery,
			}
		}
		systems[raw.ID] = system
	}
	return systems, nil
}
