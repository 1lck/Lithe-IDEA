package pluginservice

import (
	"context"

	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
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
	snapshot, err := s.ReadInstalled(ctx, entries)
	return snapshot.ToolchainPlugins(), err
}

// ToolchainPlugins hands the captured manifests to Core's toolchain registry.
func (snapshot InstalledSnapshot) ToolchainPlugins() []ToolchainPlugin {
	var plugins []ToolchainPlugin
	for _, installed := range snapshot.manifests {
		entry := installed.entry
		plugins = append(plugins, ToolchainPlugin{
			PluginID:  entry.Installed.ID,
			Version:   entry.Installed.Version,
			Manifest:  installed.manifest,
			Directory: entry.Installed.Path,
		})
	}
	return plugins
}
