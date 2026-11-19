package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// SearchLanguageSources reads selectors of enabled language-server contributions.
// It does not load grammars, open source files or start unrelated servers.
func (s *Service) SearchLanguageSources(ctx context.Context) ([]core.SearchLanguageSource, error) {
	entries, err := s.Manager.Installed()
	if err != nil {
		return nil, err
	}
	entries, err = s.selectInstalled(ctx, entries, false)
	var failures []error
	if err != nil {
		failures = append(failures, err)
	}
	var sources []core.SearchLanguageSource
	for _, entry := range entries {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
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
