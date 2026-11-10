package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The editor's own language requests: the outline's document symbols and the semantic
// tokens. They are not user gestures, so unlike a definition or a completion they do not
// close popups, take the shared deferred slot or log an action; they ride on the semantic
// pending list so the session's answer finds them (see matchPending), and ask only while the
// document is in step with the server.

const (
	// pluginSemanticDocumentSymbols and pluginSemanticTokens are the operations of the
	// outline and the semantic colors; their methods are what Core reports on completion.
	pluginSemanticDocumentSymbols = "documentSymbols"
	pluginSemanticTokens          = "semanticTokens"
	pluginMethodDocumentSymbols   = "textDocument/documentSymbol"
	pluginMethodSemanticTokens    = "textDocument/semanticTokens/full"
	// pluginSemanticTokensRefresh is the event that tells the host the server's semantic
	// colors changed everywhere.
	pluginSemanticTokensRefresh = "semanticTokensRefresh"

	// The features a server is offered with, as Core's featuresChanged event names them.
	featureDocumentSymbols = "documentSymbols"
	featureSemanticTokens  = "semanticTokens"
)

// editorServer is the ready language server of d that offers feature, and false when there
// is none yet: no server for the language, not started, or the feature not offered. known
// reports whether the server has declared its features at all.
func (a *App) editorServer(d *document, feature string) (server *pluginServer, offered bool) {
	server, ok := a.semanticServer(d)
	if !ok || !server.isReady() {
		return nil, false
	}
	return server, server.features[feature]
}

// submitEditorRequest sends request for d, which the caller has checked is in step with the
// server, and returns the pending answer to wait for. The pending request is not tied to the
// caret.
func (a *App) submitEditorRequest(kind semanticKind, p *project, d *document, server *pluginServer, request core.PluginSemanticRequest) *semanticPending {
	a.editor.requests++
	pending := &semanticPending{
		kind:       kind,
		generation: a.editor.requests,
		project:    p,
		server:     server,
		documentID: d.id,
		path:       d.path,
		uri:        d.sync.uri,
		revision:   d.view.Revision(),
	}
	a.semantics.pending = append(a.semantics.pending, pending)
	request.Operation, request.URI = string(kind), d.sync.uri
	a.background(p, semanticStartTimeout, func(ctx context.Context) func(*App) {
		operation, err := a.plugins.RequestLanguageSession(ctx, server.session, request)
		return func(a *App) { a.semanticRequestStarted(pending, operation, err, ctx.Err()) }
	})
	return pending
}

// editorRequestDone reports whether pending is still waiting for its answer.
func (a *App) editorRequestWaiting(pending *semanticPending) bool {
	return pending != nil && a.hasPending(pending)
}

// applyEditorEvent hands a completed editor request to its feature. It reports whether the
// request was one of the editor's.
func (a *App) applyEditorEvent(pending *semanticPending, event core.BackendEvent, failed bool) bool {
	switch pending.kind {
	case pluginSemanticDocumentSymbols:
		a.applyOutline(pending, event, failed)
	case pluginSemanticTokens:
		a.applySemanticTokens(pending, event, failed)
	default:
		return false
	}
	return true
}
