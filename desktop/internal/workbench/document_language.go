package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
)

type languageLoad struct {
	done   chan struct{}
	once   sync.Once
	closed atomic.Bool
}

func (l *languageLoad) finish() {
	if l == nil {
		return
	}
	l.once.Do(func() {
		l.closed.Store(true)
		close(l.done)
	})
}

// resolveDocumentLanguage runs on the worker that opens editable text. Path
// matches keep priority. Core receives only the bounded, decoded first line.
func (a *App) resolveDocumentLanguage(ctx context.Context, registry *syntax.Registry, path string, text rope.Rope) (string, *syntax.Syntax) {
	hasExtension := filepath.Ext(path) != ""
	var pending <-chan struct{}
	if initial := a.initialLanguageLoad.Load(); initial != nil && !hasExtension {
		select {
		case <-initial.done:
		default:
			pending = initial.done
		}
	}
	for {
		if language, ok := registry.ForPath(path); ok {
			return language.ID, registry.SyntaxForPath(path)
		}
		if hasExtension {
			return "", nil
		}
		if pending == nil {
			break
		}
		// Known paths restore immediately. For unknown paths, the initial snapshot
		// may add an exact file name, which still wins over a first-line match.
		select {
		case <-pending:
			pending = nil
		case <-ctx.Done():
			return "", nil
		}
	}
	const maxFirstLineBytes = 1024
	end := text.LineEnd(0)
	if end == 0 || end > maxFirstLineBytes+1 {
		return "", nil
	}
	line := strings.TrimSuffix(text.Line(0), "\r")
	if len(line) == 0 || len(line) > maxFirstLineBytes {
		return "", nil
	}
	const maxCandidates = 64
	kernel := core.NewClient()
	for batch := range slices.Chunk(registry.FirstLineCandidates(), maxCandidates) {
		var match struct {
			LanguageID string `json:"languageID"`
		}
		err := kernel.Execute(ctx, "languages.matchFirstLine", struct {
			FirstLine  string                      `json:"firstLine"`
			Candidates []syntax.FirstLineCandidate `json:"candidates"`
		}{line, batch}, &match)
		if err != nil {
			a.backgroundFailedIn(ctx, "plugin_languages", err)
			return "", nil
		}
		if match.LanguageID != "" {
			return match.LanguageID, registry.Syntax(match.LanguageID)
		}
	}
	return "", nil
}
