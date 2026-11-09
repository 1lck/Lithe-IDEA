package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// buildExecution is the executable and environment Core's candidate order
// selected for one Build or Run action. A toolchain candidate contributes its
// declared exports and PATH entries; a bare command contributes neither.
type buildExecution struct {
	Executable  string
	Environment map[string]string
	PathPrepend []string
}

// toolchainManifests reads the enabled plugins' manifests off the window
// thread. It is the only host-owned input the shared registry receives.
func (a *App) toolchainManifests() ([]json.RawMessage, error) {
	if a.plugins == nil {
		return nil, errors.New("the plugin host is not available")
	}
	entries, err := a.plugins.Manager.Installed()
	if err != nil {
		return nil, err
	}
	plugins, err := a.plugins.ToolchainPlugins(entries)
	manifests := make([]json.RawMessage, 0, len(plugins))
	for _, plugin := range plugins {
		manifests = append(manifests, plugin.Manifest)
	}
	return manifests, err
}

// resolveToolchainSelection resolves one tool for one operation. A caller may
// replace the selector in tests through toolchainResolve.
func (a *App) resolveToolchainSelection(ctx context.Context, root, directory, tool, minimumVersion string) (core.ToolchainSelection, error) {
	if a.toolchainResolve != nil {
		return a.toolchainResolve(ctx, root, directory, tool, minimumVersion)
	}
	return a.defaultToolchainSelection(ctx, root, directory, tool, minimumVersion)
}

func (a *App) defaultToolchainSelection(ctx context.Context, root, directory, tool, minimumVersion string) (core.ToolchainSelection, error) {
	manifests, err := a.toolchainManifests()
	if err != nil {
		return core.ToolchainSelection{}, err
	}
	if directory == "" {
		directory = "."
	}
	return toolchain.Resolve(ctx, a.kernel, root, directory, tool, minimumVersion, nil, manifests, toolchain.Options{
		Platform: buildPlatform(),
	})
}

// applyToolchainSelection adds the selected installation's declarations to a
// Build or Run environment. Explicit environment from the build plan or provider
// wins; the tool only supplies what the consumer left unset.
func applyToolchainSelection(environment map[string]string, selection core.ToolchainSelection) map[string]string {
	if selection.Environment == nil && len(selection.PathPrepend) == 0 {
		return environment
	}
	merged := make(map[string]string, len(environment)+len(selection.Environment)+1)
	for key, value := range environment {
		merged[key] = value
	}
	for key, value := range selection.Environment {
		if _, set := merged[key]; !set {
			merged[key] = value
		}
	}
	if len(selection.PathPrepend) > 0 {
		current, set := merged["PATH"]
		if !set {
			current = os.Getenv("PATH")
		}
		parts := append([]string(nil), selection.PathPrepend...)
		if current != "" {
			parts = append(parts, current)
		}
		merged["PATH"] = joinPathEntries(parts)
	}
	return merged
}

// selection is the Core selection shape this execution carries, so callers that
// only need its environment can reuse the same merge helper.
func (e buildExecution) selection() core.ToolchainSelection {
	return core.ToolchainSelection{Environment: e.Environment, PathPrepend: e.PathPrepend}
}

func joinPathEntries(entries []string) string {
	result := ""
	for _, entry := range entries {
		if entry == "" {
			continue
		}
		if result == "" {
			result = entry
			continue
		}
		result += string(filepath.ListSeparator) + entry
	}
	return result
}
