package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// SearchLanguageSources reads selectors of enabled language-server contributions.
// It does not load grammars, open source files or start unrelated servers.
func (s *Service) SearchLanguageSources(ctx context.Context) ([]core.SearchLanguageSource, error) {
	if s == nil || s.Manager == nil {
		return nil, ErrAssembly
	}
	entries, err := s.Manager.Installed()
	if err != nil {
		return nil, err
	}
	snapshot, readErr := s.ReadInstalled(ctx, entries)
	sources, err := snapshot.SearchLanguageSources()
	return sources, errors.Join(readErr, err)
}

// SearchLanguageSources reads selectors without reopening the installed manifests.
func (snapshot InstalledSnapshot) SearchLanguageSources() ([]core.SearchLanguageSource, error) {
	var failures []error
	var sources []core.SearchLanguageSource
	for _, installed := range snapshot.manifests {
		entry, manifest := installed.entry, installed.manifest
		var declaration struct {
			Languages []struct {
				ID               string   `json:"id"`
				FileExtensions   []string `json:"fileExtensions"`
				FileNames        []string `json:"fileNames"`
				ProjectFileNames []string `json:"projectFileNames"`
			} `json:"languages"`
			LanguageServers []struct {
				LanguageID string `json:"languageID"`
			} `json:"languageServers"`
		}
		if err := json.Unmarshal(manifest, &declaration); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		for _, server := range declaration.LanguageServers {
			for _, language := range declaration.Languages {
				if server.LanguageID == language.ID {
					sources = append(sources, core.SearchLanguageSource{LanguageID: language.ID, FileExtensions: language.FileExtensions,
						FileNames: append(append([]string(nil), language.FileNames...), language.ProjectFileNames...)})
				}
			}
		}
	}
	return sources, errors.Join(failures...)
}
