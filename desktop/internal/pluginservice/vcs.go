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

// VcsPlugin is one enabled plugin's VCS provider declaration. Core validates
// the manifest again whenever it detects roots or plans a provider; this is
// only the catalog the host presents a tool window for.
type VcsPlugin struct {
	PluginID  string
	Version   string
	Directory string
	Manifest  json.RawMessage
	Providers []VcsProviderDeclaration
}

// VcsProviderDeclaration is the presentation part of one declared provider.
type VcsProviderDeclaration struct {
	ID          string
	DisplayName string
}

// VcsPlugins reads the newest enabled version of every plugin that declares
// VCS providers. A broken manifest is reported without hiding the others.
func (s *Service) VcsPlugins(ctx context.Context, entries []pluginmanager.Entry) ([]VcsPlugin, error) {
	var plugins []VcsPlugin
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
		var decoded struct {
			VcsProviders []struct {
				ID          string `json:"id"`
				DisplayName string `json:"displayName"`
			} `json:"vcsProviders"`
		}
		if err := json.Unmarshal(manifest, &decoded); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w: %w", entry.Installed.ID, ErrPackageRead, err))
			continue
		}
		var providers []VcsProviderDeclaration
		for _, provider := range decoded.VcsProviders {
			if provider.ID != "" {
				providers = append(providers, VcsProviderDeclaration{ID: provider.ID, DisplayName: provider.DisplayName})
			}
		}
		if len(providers) == 0 {
			continue
		}
		plugins = append(plugins, VcsPlugin{
			PluginID:  entry.Installed.ID,
			Version:   entry.Installed.Version,
			Directory: entry.Installed.Path,
			Manifest:  manifest,
			Providers: providers,
		})
	}
	return plugins, errors.Join(failures...)
}
