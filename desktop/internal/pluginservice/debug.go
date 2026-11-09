package pluginservice

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// DebugPlugin is one enabled plugin's debug-adapter declaration catalog.
// Core validates the manifest; this is only the presentation and launch data
// the host needs to start the declared adapter process.
type DebugPlugin struct {
	PluginID  string
	Version   string
	Directory string
	Manifest  json.RawMessage
	Adapters  []DebugAdapterDeclaration
}

// DebugAdapterDeclaration is the subset of one `debugAdapters` entry the host
// uses to start a stdio adapter and present it. Adapter behaviour stays in
// Core; the host never interprets DAP payloads.
type DebugAdapterDeclaration struct {
	ID          string
	DisplayName string
	AdapterID   string
	Transport   string
	// LaunchKind is the process launch form: packaged or systemCommand.
	LaunchKind string
	// Path is the packaged executable, relative to the package root.
	Path string
	// Commands are bare command names for a systemCommand launch.
	Commands []string
	// Arguments are the adapter process arguments declared by the plugin.
	Arguments []string
}

// DebugPlugins reads the newest enabled version of every plugin that declares
// debug adapters.
func (s *Service) DebugPlugins(entries []pluginmanager.Entry) ([]DebugPlugin, error) {
	var plugins []DebugPlugin
	var failures []error
	for _, entry := range newestVersions(entries) {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		adapters, err := parseDebugAdapters(manifest)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		if len(adapters) == 0 {
			continue
		}
		plugins = append(plugins, DebugPlugin{
			PluginID:  entry.Installed.ID,
			Version:   entry.Installed.Version,
			Directory: entry.Installed.Path,
			Manifest:  manifest,
			Adapters:  adapters,
		})
	}
	return plugins, errors.Join(failures...)
}

type rawDebugManifest struct {
	DebugAdapters []struct {
		ID          string   `json:"id"`
		DisplayName string   `json:"displayName"`
		AdapterID   string   `json:"adapterID"`
		Requests    []string `json:"requests"`
		Launch      struct {
			Transport string `json:"transport"`
			Process   *struct {
				Launch struct {
					Kind     string   `json:"kind"`
					Path     string   `json:"path"`
					Commands []string `json:"commands"`
				} `json:"launch"`
				Arguments []string `json:"arguments"`
			} `json:"process"`
		} `json:"launch"`
	} `json:"debugAdapters"`
}

func parseDebugAdapters(manifest json.RawMessage) ([]DebugAdapterDeclaration, error) {
	var decoded rawDebugManifest
	if err := json.Unmarshal(manifest, &decoded); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrPackageRead, err)
	}
	adapters := make([]DebugAdapterDeclaration, 0, len(decoded.DebugAdapters))
	for _, raw := range decoded.DebugAdapters {
		if raw.ID == "" || raw.Launch.Process == nil {
			continue
		}
		declaration := DebugAdapterDeclaration{
			ID:          raw.ID,
			DisplayName: raw.DisplayName,
			AdapterID:   raw.AdapterID,
			Transport:   raw.Launch.Transport,
			LaunchKind:  raw.Launch.Process.Launch.Kind,
			Path:        raw.Launch.Process.Launch.Path,
			Commands:    append([]string(nil), raw.Launch.Process.Launch.Commands...),
			Arguments:   append([]string(nil), raw.Launch.Process.Arguments...),
		}
		if declaration.AdapterID == "" {
			declaration.AdapterID = declaration.ID
		}
		adapters = append(adapters, declaration)
	}
	return adapters, nil
}
