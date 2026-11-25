package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// colorDecorationsState owns each open document's provider colors. These colors are independent
// of the language server's semantic tokens, which keep their normal lifecycle.
type colorDecorationsState struct {
	docs map[int]*documentColorDecorations
}

// documentColorDecorations is one document's color pipeline: whether a provider serves it, the
// pause after an edit and the request in flight. A keystroke only restarts the pause: it neither
// looks up providers nor starts a worker, and the view keeps the colors it moved with the edit
// until the answer for the new text replaces them.
type documentColorDecorations struct {
	// provided is whether a provider serves the document at path in language. known is false
	// until it is looked up and again when a color provider registers or withdraws; a new path or
	// language is looked up again too.
	path, language  string
	known, provided bool
	// timer starts the request once typing pauses, and cancel ends the request in flight.
	timer  *time.Timer
	cancel context.CancelFunc
	// generation counts the requests planned and revoked, so that a timer or an answer overtaken
	// by a newer edit, request or withdrawal changes nothing.
	generation uint64
}

const (
	colorDecorationsDelay   = 250 * time.Millisecond
	colorDecorationsTimeout = 20 * time.Second
)

// revoke stops the pending request and the one in flight.
func (s *documentColorDecorations) revoke() {
	s.generation++
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
}

// scheduleColorDecorations asks the providers for the document's colors after delay, replacing
// the request already pending or running. The colors the view moved with an edit stay until the
// answer for the new text replaces them; colors chosen under another path, language or set of
// color providers, or for a document no provider serves any longer, go at once.
func (a *App) scheduleColorDecorations(p *project, d *document, delay time.Duration) {
	if p == nil || d == nil || d.view == nil || a.project != p {
		return
	}
	docs := a.editor.colorDecorations.docs
	if docs == nil {
		docs = make(map[int]*documentColorDecorations)
		a.editor.colorDecorations.docs = docs
	}
	state := docs[d.id]
	if state == nil {
		state = &documentColorDecorations{}
		docs[d.id] = state
	}
	state.revoke()
	if !a.colorDecorationsServed(p, d, state) {
		d.view.ClearColorDecorations()
		return
	}
	if delay <= 0 {
		a.requestColorDecorations(p, d, state)
		return
	}
	generation := state.generation
	state.timer = time.AfterFunc(delay, func() {
		a.post(func(a *App) {
			if a.project == p && p.docs.find(d.id) == d && a.editor.colorDecorations.docs[d.id] == state && state.generation == generation {
				state.timer = nil
				a.requestColorDecorations(p, d, state)
			}
		})
	})
}

// colorDecorationsServed reports whether a provider serves the document as it is now. Only a
// document within the snapshot limit is sent to providers, and the providers are looked up once
// per path, language and change of the color providers, not on every keystroke.
func (a *App) colorDecorationsServed(p *project, d *document, state *documentColorDecorations) bool {
	if d.virtual || d.view.TextSnapshot().Len() > pluginservice.DocumentSnapshotMaxBytes {
		return false
	}
	if !state.known || state.path != d.path || state.language != d.languageID {
		d.view.ClearColorDecorations()
		state.path, state.language, state.known = d.path, d.languageID, true
		state.provided = a.plugins != nil && a.plugins.HasColorDecorationsProvider(p.root, d.path, d.languageID)
	}
	return state.provided
}

// requestColorDecorations asks the providers for the colors of the current text. Preparation
// reads an immutable text snapshot on the worker; the window applies only its latest answer.
func (a *App) requestColorDecorations(p *project, d *document, state *documentColorDecorations) {
	ctx, cancel := context.WithTimeout(a.operationContext(p.ctx), colorDecorationsTimeout)
	state.cancel = cancel
	generation := state.generation
	view, text, revision := d.view, d.view.TextSnapshot(), d.view.Revision()
	plugins, root, path, language, id := a.plugins, p.root, d.path, d.languageID, documentPublicID(d)
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		decorations, err := plugins.PluginColorDecorations(ctx, root, path, language, id, revision)
		if errors.Is(ctx.Err(), context.Canceled) {
			// log-exempt: 用户取消：新的编辑、提供者撤回或关闭文档会结束过期请求，这不是失败。
			return nil
		}
		spans := make([]editorview.ColorDecoration, 0, len(decorations))
		for _, decoration := range decorations {
			spans = append(spans, editorview.ColorDecoration{
				StartLine: decoration.Range.Start.Line, StartCharacter: decoration.Range.Start.Character,
				EndLine: decoration.Range.End.Line, EndCharacter: decoration.Range.End.Character,
				SourceID: decoration.SourceID, Light: decoration.Light, Dark: decoration.Dark,
			})
		}
		prepared := editorview.PrepareColorDecorations(text, spans)
		return func(a *App) {
			a.finishColorDecorations(p, d, state, generation, view, revision, prepared, err)
		}
	})
}

// finishColorDecorations applies an answer when it is still the document's latest request and
// the text is still the one it was computed for.
func (a *App) finishColorDecorations(p *project, d *document, state *documentColorDecorations, generation uint64, view *editorview.View, revision int, prepared editorview.PreparedColorDecorations, err error) {
	if a.project != p || p.docs.find(d.id) != d || view != d.view || a.editor.colorDecorations.docs[d.id] != state || state.generation != generation {
		return
	}
	state.cancel = nil
	if view.Revision() != revision {
		return
	}
	if err != nil {
		a.backgroundFailed("plugin_color_decorations", err)
	}
	view.SetPreparedColorDecorations(prepared)
}

// colorProvidersChanged looks up the providers of every open document again and asks for their
// colors, after a color provider registered or withdrew.
func (a *App) colorProvidersChanged(p *project) {
	for _, d := range p.docs.list {
		if state := a.editor.colorDecorations.docs[d.id]; state != nil {
			state.known = false
		}
		a.scheduleColorDecorations(p, d, 0)
	}
}

// dropColorDecorations revokes the document's requests before clearing its colors, so a late
// result can never resurrect ranges from an ended document or provider registration.
func (a *App) dropColorDecorations(d *document) {
	if d == nil {
		return
	}
	if state := a.editor.colorDecorations.docs[d.id]; state != nil {
		state.revoke()
		delete(a.editor.colorDecorations.docs, d.id)
	}
	if d.view != nil {
		d.view.ClearColorDecorations()
	}
}
