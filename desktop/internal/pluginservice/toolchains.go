package pluginservice

import (
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
}

// ToolchainPlugins reads the newest enabled version of every plugin. The
// toolchain registry decides which manifests actually define a tool; a broken
// manifest is reported without hiding the other plugins.
func (s *Service) ToolchainPlugins(entries []pluginmanager.Entry) ([]ToolchainPlugin, error) {
	var plugins []ToolchainPlugin
	var failures []error
	for _, entry := range newestVersions(entries) {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		plugins = append(plugins, ToolchainPlugin{
			PluginID: entry.Installed.ID,
			Version:  entry.Installed.Version,
			Manifest: manifest,
		})
	}
	return plugins, errors.Join(failures...)
}
