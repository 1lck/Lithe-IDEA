package pluginservice

import (
	"context"
	"encoding/json"
)

// GeneratorPlugin is one installed plugin as the New Project window reads it:
// the manifest Core validates, where its package is (templates are read from
// there), and whether the user has it turned on.
type GeneratorPlugin struct {
	PluginID string
	Version  string
	// Path is the installed package directory. It is read, never written.
	Path     string
	Enabled  bool
	Manifest json.RawMessage
}

// GeneratorPlugins reads the newest installed version of every plugin, disabled
// ones included, so the window can say which plugin provides a requirement and
// offer to enable it. A manifest that cannot be read is reported without hiding
// the others.
func (s *Service) GeneratorPlugins(ctx context.Context) ([]GeneratorPlugin, error) {
	if s == nil || s.Manager == nil {
		return nil, ErrAssembly
	}
	entries, err := s.Manager.Installed()
	if err != nil {
		return nil, err
	}
	snapshot, err := s.readInstalled(ctx, entries, true)
	if cancelled := ctx.Err(); cancelled != nil {
		return nil, cancelled
	}
	return snapshot.GeneratorPlugins(), err
}

// GeneratorPlugins keeps the enabled flag, including disabled requirements when
// the inventory snapshot was created with them.
func (snapshot InstalledSnapshot) GeneratorPlugins() []GeneratorPlugin {
	plugins := make([]GeneratorPlugin, 0, len(snapshot.manifests))
	for _, installed := range snapshot.manifests {
		entry := installed.entry
		plugins = append(plugins, GeneratorPlugin{
			PluginID: entry.Installed.ID,
			Version:  entry.Installed.Version,
			Path:     entry.Installed.Path,
			Enabled:  entry.Enabled,
			Manifest: installed.manifest,
		})
	}
	return plugins
}
