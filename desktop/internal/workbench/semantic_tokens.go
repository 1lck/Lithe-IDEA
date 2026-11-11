package workbench

import (
	"context"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
)

// Semantic highlighting: the language server's colors laid over the syntax colors.
//
// Core asks the server and decodes the answer with the legend the server negotiated; the
// editor's highlighter (package syntax) owns the overlay, moves it across edits so the colors
// stay put while the next answer is on its way, and drops an answer for text that was edited
// since. This file decides when to ask: a pause after the text changed, when the server
// refreshes, and when a document first synchronizes. Only the visible lines are ever painted,
// so a large answer costs memory, not frame time; a file over semanticTokensMaxBytes keeps its
// syntax colors alone.

const (
	// semanticTokensDelay is the pause after the last edit before the server is asked again.
	semanticTokensDelay = 250 * time.Millisecond
	// semanticTokensMaxBytes is the largest document that asks for semantic tokens: the answer
	// of a server for a larger one grows with the file, not with what is shown.
	semanticTokensMaxBytes = 4 << 20
)

// documentTokens is one document's request state.
type documentTokens struct {
	pending *semanticPending
	// asked is the document revision the last request was for, -1 for none.
	asked int
	// timer is the wait before the next request; generation names the newest wait.
	cancel     context.CancelFunc
	generation uint64
}

// semanticTokensState holds the request state of every open document.
type semanticTokensState struct {
	docs map[int]*documentTokens
}

func (a *App) tokensOf(d *document) *documentTokens {
	s := &a.editor.tokens
	if s.docs == nil {
		s.docs = map[int]*documentTokens{}
	}
	t := s.docs[d.id]
	if t == nil {
		t = &documentTokens{asked: -1}
		s.docs[d.id] = t
	}
	return t
}

// scheduleSemanticTokens asks for the document's tokens after a pause, replacing a wait that
// is still running.
func (a *App) scheduleSemanticTokens(p *project, d *document, delay time.Duration) {
	if a.plugins == nil || d == nil || d.virtual || a.project != p || a.settings.DisableSemanticHighlight {
		return
	}
	t := a.tokensOf(d)
	if t.cancel != nil {
		t.cancel()
		t.cancel = nil
	}
	t.generation++
	generation, id := t.generation, d.id
	ctx, cancel := context.WithCancel(p.ctx)
	t.cancel = cancel
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				// log-exempt: 用户取消：新的编辑或关闭文档会取消等待。
				return nil
			}
		}
		return func(a *App) {
			if current, document := a.currentSemanticDocument(id); current == p && document != nil && a.tokensOf(document).generation == generation {
				a.requestSemanticTokens(p, document)
			}
		}
	})
}

// requestSemanticTokens asks the document's server for its tokens when the server offers them
// and the document is in step with it. A request that cannot start yet is tried again when the
// document's synchronization finishes (see semanticTokensResume).
func (a *App) requestSemanticTokens(p *project, d *document) {
	t := a.tokensOf(d)
	revision := d.view.Revision()
	if t.pending != nil && !a.editorRequestWaiting(t.pending) {
		t.pending = nil
	}
	if t.pending != nil {
		// The answer in flight is for older text; ask again once it has come.
		t.asked = -1
		return
	}
	if t.asked == revision || !a.semanticDocumentReady(d) {
		return
	}
	if d.view.TextSnapshot().Len() > semanticTokensMaxBytes {
		return
	}
	server, offered := a.editorServer(d, featureSemanticTokens)
	if server == nil || !offered {
		// No language server offers tokens: a plugin's semantic tokens provider may, with its legend.
		if a.plugins != nil && a.plugins.HasSemanticTokensProvider(p.root, d.path, d.languageID) {
			a.requestProviderTokens(p, d, revision)
		}
		return
	}
	t.asked = revision
	t.pending = a.submitEditorRequest(pluginSemanticTokens, p, d, server, core.PluginSemanticRequest{})
}

// requestProviderTokens asks a plugin's semantic tokens provider for the tokens of the text at revision. The
// answer is laid over that text only while the document still has it; an edit asks again.
func (a *App) requestProviderTokens(p *project, d *document, revision int) {
	t := a.tokensOf(d)
	t.asked = revision
	view, text := d.view, d.view.TextSnapshot()
	id, path, language, root, plugins := strconv.Itoa(d.id), d.path, d.languageID, p.root, a.plugins
	a.background(p, 20*time.Second, func(ctx context.Context) func(*App) {
		tokens, err := plugins.PluginSemanticTokens(ctx, root, path, language, id, revision)
		return func(a *App) {
			if p.docs.find(d.id) != d || view.Revision() != revision {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantic_tokens", err))
				return
			}
			legend := syntax.NewSemanticLegend(tokens.Types, tokens.Modifiers)
			spans := make([]syntax.SemanticToken, 0, len(tokens.Tokens))
			for _, token := range tokens.Tokens {
				spans = append(spans, syntax.SemanticToken{
					Line: uint32(token.Line), StartChar: uint32(token.StartChar), Length: uint32(token.Length),
					Type: uint32(token.Type), Modifiers: token.Modifiers,
				})
			}
			view.SetSemantic(text, legend, spans)
		}
	})
}

// applySemanticTokens takes the answer of a semanticTokens request: the tokens are laid over
// the text they were asked for, off the window thread.
func (a *App) applySemanticTokens(pending *semanticPending, event core.BackendEvent, failed bool) {
	if a.settings.DisableSemanticHighlight {
		return
	}
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil {
		return
	}
	t := a.tokensOf(d)
	if t.pending == pending {
		t.pending = nil
	}
	if failed {
		return
	}
	tokens, err := core.PluginSemanticTokens(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantic_tokens", err))
		return
	}
	view := d.view
	text := view.TextSnapshot()
	revision := pending.revision
	if view.Revision() != revision {
		// The text moved on while the server worked; the overlay was moved across the edits
		// and the next request follows.
		a.scheduleSemanticTokens(p, d, semanticTokensDelay)
		return
	}
	a.background(p, 0, func(context.Context) func(*App) {
		legend := syntax.NewSemanticLegend(tokens.TokenTypes, tokens.TokenModifiers)
		spans := make([]syntax.SemanticToken, 0, len(tokens.Tokens))
		for _, token := range tokens.Tokens {
			if token.Line < 0 || token.StartChar < 0 || token.Length <= 0 || token.TokenType < 0 {
				continue
			}
			spans = append(spans, syntax.SemanticToken{
				Line: uint32(token.Line), StartChar: uint32(token.StartChar), Length: uint32(token.Length),
				Type: uint32(token.TokenType), Modifiers: token.TokenModifiers,
			})
		}
		view.SetSemantic(text, legend, spans)
		return nil
	})
	if t.asked != revision {
		a.scheduleSemanticTokens(p, d, semanticTokensDelay)
	}
}

// semanticTokensResume asks for the tokens of every open document that has none for its
// current text, once a synchronization finished or the server became ready.
func (a *App) semanticTokensResume() {
	p := a.project
	if p == nil || a.plugins == nil {
		return
	}
	for _, d := range p.docs.list {
		if t := a.tokensOf(d); t.asked != d.view.Revision() && !d.virtual {
			a.requestSemanticTokens(p, d)
		}
	}
}

// semanticTokensRefresh handles the server's request to recolor everything: the documents it
// serves ask again.
func (a *App) semanticTokensRefresh(server *pluginServer) {
	p := a.project
	if p == nil || server == nil || server.session == nil || !a.isCurrentPluginServer(server.session.PluginID, server) {
		return
	}
	for _, d := range p.docs.list {
		if d.sync.pluginID != server.session.PluginID {
			continue
		}
		a.tokensOf(d).asked = -1
		a.scheduleSemanticTokens(p, d, 0)
	}
}

// semanticTokensEdited keeps the colors in step with an edit of d: the overlay moves with the
// text on its own, and a request follows after a pause.
func (a *App) semanticTokensEdited(p *project, d *document) {
	if _, ok := a.editorServer(d, featureSemanticTokens); !ok {
		return
	}
	a.scheduleSemanticTokens(p, d, semanticTokensDelay)
}

// setDisableSemanticHighlight stores the editor switch and applies it at once: turning the
// colors off clears every overlay and drops pending requests, turning them on asks again for
// the open documents.
func (a *App) setDisableSemanticHighlight(disabled bool) {
	if a.settings.DisableSemanticHighlight == disabled {
		return
	}
	a.settings.DisableSemanticHighlight = disabled
	a.saveSettings()
	p := a.project
	if p == nil {
		return
	}
	for _, d := range p.docs.list {
		if disabled {
			d.view.ClearSemantic()
			a.semanticTokensDropped(d)
			continue
		}
		a.scheduleSemanticTokens(p, d, 0)
	}
}

// semanticTokensDropped forgets a closed document's state.
func (a *App) semanticTokensDropped(d *document) {
	t := a.editor.tokens.docs[d.id]
	if t == nil {
		return
	}
	if t.cancel != nil {
		t.cancel()
	}
	if a.editorRequestWaiting(t.pending) {
		a.cancelSemantic(t.pending)
	}
	delete(a.editor.tokens.docs, d.id)
}

// semanticTokensReleased drops the colors and the state of the documents of a stopped server,
// so the next server starts from the syntax colors.
func (a *App) semanticTokensReleased(pluginID string) {
	p := a.project
	if p == nil {
		return
	}
	for _, d := range p.docs.list {
		if pluginID != "" && d.sync.pluginID != pluginID {
			continue
		}
		d.view.ClearSemantic()
		if t := a.editor.tokens.docs[d.id]; t != nil {
			t.asked = -1
			if t.cancel != nil {
				t.cancel()
				t.cancel = nil
			}
			t.pending = nil
		}
	}
}
