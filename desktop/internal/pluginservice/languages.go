package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

const (
	// MaxManifestBytes bounds the manifest read from an installed package.
	MaxManifestBytes = 8 << 20
	// MaxGrammarBytes bounds one grammar file. A TextMate grammar of a real
	// language is well under a megabyte; the ceiling only stops a malformed
	// package from being read into memory.
	MaxGrammarBytes = 16 << 20
)

// ErrPackageRead reports an installed package this service cannot read.
var ErrPackageRead = errors.New("plugin package cannot be read")

// LoadLanguages reads the static language declarations of every enabled plugin.
//
// Grammars are read from the installed package and decoded by Core, so a grammar
// Core rejects is reported rather than registered with the editor. Languages of a
// disabled plugin are not returned at all, which is how disabling one withdraws
// its highlighting.
//
// The returned slice is usable even when the error is non-nil: the error
// summarises the plugins whose declarations could not be read, and the others
// still contribute.
func (s *Service) LoadLanguages(ctx context.Context, entries []pluginmanager.Entry) ([]syntax.PluginLanguage, error) {
	if s == nil || s.kernel == nil {
		return nil, fmt.Errorf("%w: no kernel", ErrAssembly)
	}
	var languages []syntax.PluginLanguage
	var failures []error
	for _, entry := range entries {
		if !entry.Enabled {
			continue
		}
		loaded, err := s.pluginLanguages(ctx, entry.Installed.Path)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		languages = append(languages, loaded...)
	}
	return languages, errors.Join(failures...)
}

// languageDeclaration is the part of a manifest this package reads.
type languageDeclaration struct {
	Languages []struct {
		ID             string   `json:"id"`
		FileExtensions []string `json:"fileExtensions"`
		FileNames      []string `json:"fileNames"`
		Grammar        *struct {
			Kind string `json:"kind"`
			Path string `json:"path"`
		} `json:"grammar"`
	} `json:"languages"`
}

// pluginLanguages reads one installed package's language contributions.
func (s *Service) pluginLanguages(ctx context.Context, directory string) ([]syntax.PluginLanguage, error) {
	manifest, err := readBounded(filepath.Join(directory, pluginpkg.ManifestFile), MaxManifestBytes)
	if err != nil {
		return nil, err
	}
	var declaration languageDeclaration
	if err := json.Unmarshal(manifest, &declaration); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrPackageRead, err)
	}
	languages := make([]syntax.PluginLanguage, 0, len(declaration.Languages))
	for _, item := range declaration.Languages {
		if item.ID == "" {
			continue
		}
		language := syntax.PluginLanguage{
			ID:         item.ID,
			Extensions: item.FileExtensions,
			FileNames:  item.FileNames,
		}
		if item.Grammar != nil {
			path, err := pluginhost.ResolvePackagePath(directory, item.Grammar.Path)
			if err != nil {
				return nil, err
			}
			source, err := readBounded(path, MaxGrammarBytes)
			if err != nil {
				return nil, err
			}
			decoded, err := s.kernel.DecodePluginGrammar(ctx, manifest, item.ID, string(source))
			if err != nil {
				return nil, err
			}
			if decoded.Grammar != nil {
				language.Grammar = []byte(decoded.Grammar.Source)
			}
		}
		languages = append(languages, language)
	}
	return languages, nil
}

// readBounded reads a whole file, refusing one over limit bytes.
func readBounded(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrPackageRead, err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrPackageRead, err)
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: %s is larger than %d bytes", ErrPackageRead, path, limit)
	}
	return data, nil
}
