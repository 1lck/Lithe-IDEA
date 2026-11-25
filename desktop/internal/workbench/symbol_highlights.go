package workbench

import (
	"context"
	"errors"
	"regexp"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

const (
	pluginSemanticDocumentHighlight = "documentHighlight"
	pluginMethodDocumentHighlight   = "textDocument/documentHighlight"
	symbolHighlightDelay            = 100 * time.Millisecond
	symbolSelectionMaxBytes         = 256
	symbolSearchMaxBytes            = 2 << 20
)

var symbolSelection = regexp.MustCompile(`^[_$\pL][_$\pL\pN\pM]*$`)

type symbolHighlightKey struct {
	document *document
	server   *pluginServer
	revision int
	anchor   int
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

func (a *App) resumeSymbolHighlights() {
	if d := a.semantics.symbolHighlights.key.document; d != nil {
		a.syncSymbolHighlights(a.project, d)
	}
}

// syncSymbolHighlights watches the editor's own gesture, not pointer hover or
// frame painting. It snapshots text on the UI thread and reads it on a worker.
func (a *App) syncSymbolHighlights(p *project, d *document) {
	if p == nil || a.project != p || d == nil || d.view == nil {
		return
	}
	s := &a.semantics.symbolHighlights
	if d.view.IsComposing() {
		a.clearSymbolHighlights()
		return
	}
	anchor, caret := d.view.SelectionOffsets()
	key := symbolHighlightKey{document: d, revision: d.view.Revision(), anchor: anchor, caret: caret}
	if server, offered := a.editorServer(d, pluginSemanticDocumentHighlight); offered {
		key.server, key.ready = server, a.semanticDocumentReady(d)
	}
	if key == s.key {
		return
	}
	a.clearSymbolHighlights()
	s.key = key
	start, end := min(anchor, caret), max(anchor, caret)
	text := d.view.TextSnapshot()
	var word string
	if start != end {
		if end-start > symbolSelectionMaxBytes {
			return
		}
		word, _ = text.Substring(start, end)
		if !symbolSelection.MatchString(word) {
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
				Query: word, CaseSensitive: true, WholeWord: true, Caret: start,
			})
			// log-exempt: 用户取消：选区、文本或工作区已经更换。
			if errors.Is(err, context.Canceled) {
				return nil
			}
			ranges := selectedWordHighlights(found.Matches, start, end)
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
	anchor, caret := d.view.SelectionOffsets()
	return anchor == key.anchor && caret == key.caret
}

// selectedWordHighlights only accepts a full-word selection. A partial
// selection must not light up a different identifier that happens to match.
func selectedWordHighlights(matches []core.EditorByteRange, start, end int) []editorview.Range {
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
		ranges := make([]editorview.Range, 0, len(reported))
		for _, r := range reported {
			if ctx.Err() != nil {
				break
			}
			start, startErr := editorview.OffsetOfSnapshot(text, r.Start.Line, r.Start.UTF16Column)
			end, endErr := editorview.OffsetOfSnapshot(text, r.End.Line, r.End.UTF16Column)
			if startErr != nil || endErr != nil {
				err = editorview.ErrPosition
				break
			}
			if start < end {
				ranges = append(ranges, editorview.Range{Start: start, End: end})
			}
		}
		if err == nil {
			err = ctx.Err()
		}
		// log-exempt: 用户取消：选区、文本或工作区已经更换。
		if errors.Is(err, context.Canceled) {
			return nil
		}
		return func(a *App) {
			if a.symbolHighlightCurrent(p, key, gen) {
				s.cancel = nil
				if err != nil {
					a.backgroundFailed("plugin_semantics", err)
					return
				}
				d.view.SetSymbolHighlights(ranges)
			}
		}
	})
}
