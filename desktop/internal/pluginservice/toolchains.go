package pluginservice

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"

	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// ToolchainPlugin is one enabled plugin's manifest as the shared toolchain
// registry validates it. The host does not project a second tool table.
type ToolchainPlugin struct {
	PluginID string
	Version  string
	Manifest json.RawMessage
	// Directory is the installed package, read-only; files the manifest names, such as
	// its translations, are read from it.
	Directory string
}

// ToolchainPlugins reads the newest enabled version of every plugin. The
// toolchain registry decides which manifests actually define a tool; a broken
// manifest is reported without hiding the other plugins.
func (s *Service) ToolchainPlugins(ctx context.Context, entries []pluginmanager.Entry) ([]ToolchainPlugin, error) {
	var plugins []ToolchainPlugin
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
		plugins = append(plugins, ToolchainPlugin{
			PluginID:  entry.Installed.ID,
			Version:   entry.Installed.Version,
			Manifest:  manifest,
			Directory: entry.Installed.Path,
		})
	}
	return plugins, errors.Join(failures...)
}
