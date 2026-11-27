package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

const (
	pluginSemanticDocumentHighlight = "documentHighlight"
	pluginMethodDocumentHighlight   = "textDocument/documentHighlight"
	symbolHighlightDelay            = 100 * time.Millisecond
	symbolSelectionMaxBytes         = 256
	symbolSearchMaxBytes            = 2 << 20
)

type symbolHighlightKey struct {
	document *document
	server   *pluginServer
	revision int
	start    int
	end      int
	caret    int
	ready    bool
}

type symbolHighlightState struct {
	key     symbolHighlightKey
	timer   *time.Timer
	cancel  context.CancelFunc
	pending *semanticPending
	// generation rejects an old response even if the caret returned to the same place.
	generation uint64
}

func (a *App) clearSymbolHighlights() {
	s := &a.semantics.symbolHighlights
	if s.key.document != nil {
		s.key.document.view.SetSymbolHighlights(nil)
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	if s.cancel != nil {
		s.cancel()
	}
	a.cancelSemantic(s.pending)
	*s = symbolHighlightState{generation: s.generation + 1}
}

// A stopped server invalidates its answers, but the open editor still owns its
// selection. Retain only that target so synchronization can resume the query.
func (a *App) releaseSymbolHighlights(pluginID string) {
	s := &a.semantics.symbolHighlights
	server := s.key.server
	if server == nil || server.session == nil || server.session.PluginID != pluginID {
		return
	}
	d := s.key.document
	a.clearSymbolHighlights()
	s.key = symbolHighlightKey{document: d, revision: -1}
}

func (a *App) resumeSymbolHighlights() {
	if d := a.semantics.symbolHighlights.key.document; d != nil {
		a.syncSymbolHighlights(a.project, d)
	}
}

// syncSymbolHighlights watches the editor's own gesture, not pointer hover or
// frame painting. It snapshots text on the UI thread and reads it on a worker.
func (a *App) syncSymbolHighlights(p *project, d *document) {
	if p == nil || a.project != p || d == nil || d.view == nil || p.docs.find(d.id) != d {
		return
	}
	s := &a.semantics.symbolHighlights
	if d.view.IsComposing() {
		a.clearSymbolHighlights()
		return
	}
	start, end := d.view.Selection()
	_, caret := d.view.SelectionOffsets()
	key := symbolHighlightKey{document: d, revision: d.view.Revision(), start: start, end: end, caret: caret}
	if server, offered := a.editorServer(d, pluginSemanticDocumentHighlight); offered {
		key.server, key.ready = server, a.semanticDocumentReady(d)
	}
	if key == s.key {
		return
	}
	a.clearSymbolHighlights()
	s.key = key
	text := d.view.TextSnapshot()
	var word string
	if start != end {
		if end-start > symbolSelectionMaxBytes {
			return
		}
		word, _ = text.Substring(start, end)
		if !syntax.IdentifierSelection(word) {
			return
		}
	} else if key.server == nil {
		return
	}
	if key.server != nil && !key.ready || key.server == nil && text.Len() > symbolSearchMaxBytes {
		return
	}
	gen := s.generation
	run := func(a *App) {
		if !a.symbolHighlightCurrent(p, key, gen) {
			return
		}
		s.timer = nil
		if key.server != nil {
			line, column := d.view.PositionOf(start)
			position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
			s.pending = a.submitEditorRequest(pluginSemanticDocumentHighlight, p, d, key.server, core.PluginSemanticRequest{Position: &position})
			return
		}
		kernel, ok := a.kernel.(editorFindKernel)
		if !ok {
			return
		}
		s.cancel = a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
			found, err := kernel.FindEditorText(ctx, text.Bytes(), core.EditorFindRequest{
				Query: word, CaseSensitive: true, WholeIdentifier: true, Caret: start,
			})
			// log-exempt: 用户取消：选区、文本或工作区已经更换。
			if errors.Is(err, context.Canceled) {
				return nil
			}
			ranges := selectedIdentifierHighlights(found.Matches, start, end)
			return func(a *App) {
				if a.symbolHighlightCurrent(p, key, gen) {
					s.cancel = nil
					if err != nil {
						a.backgroundFailed("editor_find", err)
						return
					}
					d.view.SetSymbolHighlights(ranges)
				}
			}
		})
	}
	delay := a.semantics.symbolHighlightDelay
	if delay < 0 {
		run(a)
		return
	}
	if delay == 0 {
		delay = symbolHighlightDelay
	}
	s.timer = time.AfterFunc(delay, func() { a.post(run) })
}

func (a *App) symbolHighlightCurrent(p *project, key symbolHighlightKey, generation uint64) bool {
	s := &a.semantics.symbolHighlights
	d := key.document
	if a.project != p || s.generation != generation || s.key != key || d.view.Revision() != key.revision || d.view.IsComposing() {
		return false
	}
	start, end := d.view.Selection()
	_, caret := d.view.SelectionOffsets()
	return start == key.start && end == key.end && caret == key.caret
}

// selectedIdentifierHighlights only accepts a full-identifier selection. A partial
// selection must not light up a different identifier that happens to match.
func selectedIdentifierHighlights(matches []core.EditorByteRange, start, end int) []editorview.Range {
	for _, selected := range matches {
		if selected.Start == start && selected.End == end {
			ranges := make([]editorview.Range, 0, len(matches)-1)
			for _, match := range matches {
				if match != selected {
					ranges = append(ranges, editorview.Range{Start: match.Start, End: match.End})
				}
			}
			return ranges
		}
	}
	return nil
}

func (a *App) applySymbolHighlights(pending *semanticPending, event core.BackendEvent, failed bool) {
	s := &a.semantics.symbolHighlights
	if s.pending != pending {
		return
	}
	s.pending = nil
	key, gen, p := s.key, s.generation, pending.project
	if failed || !a.symbolHighlightCurrent(p, key, gen) {
		return
	}
	d := key.document
	text := d.view.TextSnapshot()
	s.cancel = a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		reported, err := core.PluginSemanticHighlightRanges(event)
		var ranges []editorview.Range
		if err == nil {
			projected := make([]core.PluginDocumentRange, len(reported.Ranges))
			for i, highlight := range reported.Ranges {
				projected[i] = highlight.PluginDocumentRange
			}
			ranges, err = projectSymbolHighlightRanges(ctx, text, projected)
		}
		// log-exempt: 用户取消：选区、文本或工作区已经更换。
		if errors.Is(err, context.Canceled) {
			return nil
		}
		return func(a *App) {
			if a.symbolHighlightCurrent(p, key, gen) {
				s.cancel = nil
				if reported.Truncated {
					a.backgroundFailed("document_highlight_truncated", errors.New("highlight_limit"))
				}
				if err != nil {
					a.backgroundFailed("plugin_semantics", err)
					if !errors.Is(err, editorview.ErrPosition) {
						return
					}
				}
				d.view.SetSymbolHighlights(ranges)
			}
		}
	})
}

// projectSymbolHighlightRanges preserves the valid siblings of a range that
// does not resolve against this revision. The caller logs the batch once.
func projectSymbolHighlightRanges(ctx context.Context, text rope.Rope, reported []core.PluginDocumentRange) ([]editorview.Range, error) {
	ranges := make([]editorview.Range, 0, len(reported))
	var invalid error
	for _, r := range reported {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		start, startErr := editorview.OffsetOfSnapshot(text, r.Start.Line, r.Start.UTF16Column)
		end, endErr := editorview.OffsetOfSnapshot(text, r.End.Line, r.End.UTF16Column)
		if startErr != nil || endErr != nil || start >= end {
			invalid = editorview.ErrPosition
			continue
		}
		ranges = append(ranges, editorview.Range{Start: start, End: end})
	}
	return ranges, invalid
}
