package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
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
	snapshot, readErr := s.ReadInstalled(ctx, entries)
	contributions, err := snapshot.VcsPlugins()
	return contributions, errors.Join(readErr, err)
}

// VcsPlugins reads its contribution sections from the same installed bytes.
func (snapshot InstalledSnapshot) VcsPlugins() ([]VcsPlugin, error) {
	var plugins []VcsPlugin
	var failures []error
	for _, installed := range snapshot.manifests {
		entry, manifest := installed.entry, installed.manifest
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
