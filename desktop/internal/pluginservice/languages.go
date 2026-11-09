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
	// MaxDelimiterBytes bounds one comment or bracket delimiter, matching the
	// contract's editorDelimiter.
	MaxDelimiterBytes = 16
	// MaxDelimiterPairs bounds the bracket and auto-closing lists, matching the
	// contract's editorDelimiterPair arrays.
	MaxDelimiterPairs = 32
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
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	if selectionErr != nil {
		failures = append(failures, selectionErr)
	}
	for _, entry := range selected {
		loaded, err := s.pluginLanguages(ctx, entry.Installed.Path)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
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
		Configuration *struct {
			LineComment      string     `json:"lineComment"`
			BlockComment     []string   `json:"blockComment"`
			Brackets         [][]string `json:"brackets"`
			AutoClosingPairs [][]string `json:"autoClosingPairs"`
		} `json:"configuration"`
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
	var failures []error
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
			// The contract has a language whose grammar is refused open as plain text
			// while the rest of the plugin keeps working, so a bad grammar costs that
			// language its highlighting and nothing else.
			if grammar, err := s.grammar(ctx, directory, manifest, item.ID, item.Grammar.Path); err != nil {
				failures = append(failures, fmt.Errorf("%s: %w", item.ID, err))
			} else {
				language.Grammar = grammar
			}
		}
		if configuration := item.Configuration; configuration != nil {
			if validDelimiter(configuration.LineComment) {
				language.Comments.Line = configuration.LineComment
			}
			if pair, ok := delimiterPair(configuration.BlockComment); ok {
				language.Comments.Block = pair
			}
			language.Brackets = delimiterPairs(configuration.Brackets)
			language.AutoClosing = delimiterPairs(configuration.AutoClosingPairs)
		}
		if len(language.Extensions) == 0 && len(language.FileNames) == 0 {
			// The editor matches a language by extension or base name only. A
			// declaration that names nothing but projectFileNames is a project
			// signal, which this client does not use to choose a language, so the
			// language would be invisible. Reporting it is better than registering a
			// language that can never match.
			failures = append(failures, fmt.Errorf("%s: declares no file extensions or file names", item.ID))
			continue
		}
		languages = append(languages, language)
	}
	return languages, errors.Join(failures...)
}

// grammar reads one grammar file from the package and has Core validate it.
func (s *Service) grammar(ctx context.Context, directory string, manifest json.RawMessage, languageID, name string) ([]byte, error) {
	path, err := pluginhost.ResolvePackagePath(directory, name)
	if err != nil {
		return nil, err
	}
	source, err := readBounded(path, MaxGrammarBytes)
	if err != nil {
		return nil, err
	}
	decoded, err := s.kernel.DecodePluginGrammar(ctx, manifest, languageID, string(source))
	if err != nil {
		return nil, err
	}
	if decoded.Grammar == nil {
		return nil, nil
	}
	return []byte(decoded.Grammar.Source), nil
}

// delimiterPair converts one two-element delimiter declaration.
func delimiterPair(values []string) (syntax.Pair, bool) {
	if len(values) != 2 || !validDelimiter(values[0]) || !validDelimiter(values[1]) {
		return syntax.Pair{}, false
	}
	return syntax.Pair{Open: values[0], Close: values[1]}, true
}

// delimiterPairs converts a list of two-element delimiter declarations, dropping
// the ones that are not a pair and capping the list at the contract's limit.
func delimiterPairs(values [][]string) []syntax.Pair {
	if len(values) == 0 {
		return nil
	}
	pairs := make([]syntax.Pair, 0, min(len(values), MaxDelimiterPairs))
	for _, value := range values {
		if len(pairs) == MaxDelimiterPairs {
			break
		}
		if pair, ok := delimiterPair(value); ok {
			pairs = append(pairs, pair)
		}
	}
	if len(pairs) == 0 {
		return nil
	}
	return pairs
}

// validDelimiter reports whether a delimiter may reach the editor.
//
// The contract bounds a delimiter to MaxDelimiterBytes without control characters.
// Core validates a manifest when it is reviewed, but this file is read again on
// every reload, so the same bounds are applied to the bytes that are actually used.
func validDelimiter(value string) bool {
	if value == "" || len(value) > MaxDelimiterBytes {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
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
