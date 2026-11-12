package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
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
	entries, err := s.CurrentInstalled(ctx)
	failures := []error{}
	if err != nil {
		failures = append(failures, err)
		if entries == nil {
			return nil, errors.Join(failures...)
		}
	}
	plugins := make([]GeneratorPlugin, 0, len(entries))
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		manifest, readErr := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if readErr != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, readErr))
			continue
		}
		plugins = append(plugins, GeneratorPlugin{
			PluginID: entry.Installed.ID,
			Version:  entry.Installed.Version,
			Path:     entry.Installed.Path,
			Enabled:  entry.Enabled,
			Manifest: manifest,
		})
	}
	return plugins, errors.Join(failures...)
}
