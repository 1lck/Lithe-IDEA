package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
)

const (
	// documentSyncTimeout bounds one open, change, save or close call on a
	// language server. The calls are local; a wedged server must not keep a
	// document's synchronization in flight forever.
	documentSyncTimeout = 15 * time.Second
	// maxPendingDocumentChanges coalesces a burst of edits before a whole-text
	// replacement is cheaper and more reliable than replaying every stale range.
	maxPendingDocumentChanges = 64
)

// documentSync is the editor-to-language-server state of one document.
//
// The document is opened once per session and every later edit is sent as an
// LSP content change, so the server sees the same versions and positions as the
// editor. The state is touched only on the window thread; background work gets
// copies and reports back through a generation check.
type documentSync struct {
	// generation invalidates the result of work that belonged to a document
	// before it was closed, reopened, or its server was replaced.
	generation uint64
	// uri is the identity Core resolved for the document, and pluginID the
	// session that holds it.
	uri      string
	pluginID string
	// opened says a session currently holds the document.
	opened bool
	// pending holds changes made while a synchronization was in flight.
	pending []core.PluginTextChange
	// full asks for a whole-document replacement instead of pending, after the
	// buffer overflowed or the view replaced its text as one step (undo, reload).
	full bool
	// running says a background synchronization is in flight.
	running bool
}

// reset forgets the session state and invalidates in-flight work. It leaves the
// document itself untouched.
func (s *documentSync) reset() {
	s.generation++
	s.uri, s.pluginID = "", ""
	s.opened, s.full, s.running = false, false, false
	s.pending = nil
}

// documentSyncServer is the language server that serves a document, if it is
// running. An empty language or provider means nothing serves it.
func (a *App) documentSyncServer(d *document) (*pluginServer, string) {
	if d == nil || d.languageID == "" {
		return nil, ""
	}
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	pluginID := a.pluginServerLanguages[d.languageID]
	if pluginID == "" {
		return nil, ""
	}
	server := a.pluginServers[pluginID]
	if server == nil || server.session == nil || server.session.Documents == nil {
		return nil, ""
	}
	return server, pluginID
}

// documentEdited records one edit and starts its synchronization. The hook runs
// on the window thread, so it only queues work.
func (a *App) documentEdited(p *project, d *document, edit editorview.Edit) {
	a.relocateDocumentBreakpoints(p, d, edit)
	a.scheduleEditorActions(p, d)
	if a.plugins == nil || a.project != p || p.docs.byPath(d.path) != d {
		return
	}
	// A definition or completion answer describes the text the trigger saw.
	// Keeping it after an edit would apply or jump from stale positions.
	a.pluginSemanticsEdited(d)
	a.scheduleAutoCompletion(p, d, edit)
	s := &d.sync
	if s.full || len(s.pending) >= maxPendingDocumentChanges {
		s.full, s.pending = true, nil
	} else {
		s.pending = append(s.pending, core.PluginTextChange{
			Range: &core.PluginDocumentRange{
				Start: core.PluginDocumentPosition{Line: edit.StartLine, UTF16Column: edit.StartColumn},
				End:   core.PluginDocumentPosition{Line: edit.EndLine, UTF16Column: edit.EndColumn},
			},
			Text: edit.Text,
		})
	}
	a.startDocumentSync(p, d)
}

// startDocumentSync opens the document when the session does not hold it yet,
// or sends the queued changes when it does. At most one call is in flight per
// document; edits that arrive meanwhile stay queued.
func (a *App) startDocumentSync(p *project, d *document) {
	s := &d.sync
	if s.running || a.plugins == nil || a.project != p {
		return
	}
	server, pluginID := a.documentSyncServer(d)
	if server == nil {
		return
	}
	if !s.opened || s.pluginID != pluginID {
		path, languageID := d.path, d.languageID
		text, _ := d.view.Text()
		revision, generation := d.view.Revision(), s.generation
		// Bind ownership before Open returns so disabling the plugin also
		// invalidates a document whose opening request is still in flight.
		s.pluginID = pluginID
		s.running = true
		a.background(p, documentSyncTimeout, func(ctx context.Context) func(*App) {
			uri, err := a.kernel.PluginDocumentURI(ctx, path, "auto")
			if err == nil {
				var identity string
				identity, err = server.session.Documents.Open(ctx, pluginlsp.Document{
					URI:        uri,
					LanguageID: languageID,
					Text:       string(text),
				})
				if err == nil {
					uri = identity
				}
			}
			return func(a *App) {
				a.finishDocumentOpen(p, d, server, pluginID, generation, revision, uri, err, ctx.Err())
			}
		})
		return
	}
	if !s.full && len(s.pending) == 0 {
		return
	}
	changes := append([]core.PluginTextChange(nil), s.pending...)
	if s.full {
		text, _ := d.view.Text()
		changes = []core.PluginTextChange{{Text: string(text)}}
	}
	s.pending, s.full = nil, false
	revision, generation := d.view.Revision(), s.generation
	uri := s.uri
	s.running = true
	a.background(p, documentSyncTimeout, func(ctx context.Context) func(*App) {
		err := server.session.Documents.Change(ctx, uri, changes)
		return func(a *App) {
			a.finishDocumentChange(p, d, generation, revision, err, ctx.Err())
		}
	})
}

// finishDocumentOpen accepts one Open result. A document or session replaced
// meanwhile is left alone; an answer that belongs to the current state either
// records the identity or reports the failure.
func (a *App) finishDocumentOpen(p *project, d *document, server *pluginServer, pluginID string, generation uint64, revision int, uri string, err, ctxErr error) {
	s := &d.sync
	if a.project != p || p.docs.byPath(d.path) != d || s.generation != generation {
		// The tab or session changed while the open was in flight. A successful
		// open must not leave a document the server can keep publishing for.
		if err == nil && uri != "" && a.isCurrentPluginServer(pluginID, server) {
			a.closeLateDocument(server, uri)
		}
		return
	}
	s.running = false
	if err != nil {
		a.reportDocumentSyncFailure("plugin_document_open", ctxErr, err)
		s.reset()
		return
	}
	s.opened, s.uri, s.pluginID = true, uri, pluginID
	s.pending, s.full = nil, false
	if d.view.Revision() != revision {
		// Edits made while the document was opening were not part of the text
		// Core received. Send the current buffer as one replacement.
		s.full = true
		a.startDocumentSync(p, d)
	}
	a.resumeDeferredSemantics()
}

// closeLateDocument closes a document whose Open finished after the editor or
// session that requested it was replaced. Best effort: the session may already
// be stopping.
func (a *App) closeLateDocument(server *pluginServer, uri string) {
	if server == nil || server.session == nil || server.session.Documents == nil {
		return
	}
	a.background(nil, documentSyncTimeout, func(ctx context.Context) func(*App) {
		err := server.session.Documents.Close(ctx, uri)
		return func(a *App) {
			if err != nil {
				a.reportDocumentSyncFailure("plugin_document_close_late", ctx.Err(), err)
			}
		}
	})
}

// finishDocumentChange accepts one Change result. A failed call reopens the
// document on the next edit with its current text instead of replaying ranges
// the server never accepted.
func (a *App) finishDocumentChange(p *project, d *document, generation uint64, revision int, err, ctxErr error) {
	s := &d.sync
	if a.project != p || p.docs.byPath(d.path) != d || s.generation != generation {
		return
	}
	s.running = false
	if err != nil {
		a.reportDocumentSyncFailure("plugin_document_change", ctxErr, err)
		s.reset()
		return
	}
	if d.view.Revision() != revision || s.full || len(s.pending) > 0 {
		a.startDocumentSync(p, d)
	}
	a.resumeDeferredSemantics()
}

// reportDocumentSyncFailure logs a failed synchronization, unless the project
// closed and cancelled it. A cancellation is expected and not a warning.
func (a *App) reportDocumentSyncFailure(event string, ctxErr, err error) {
	if errors.Is(err, context.Canceled) || errors.Is(ctxErr, context.Canceled) {
		return
	}
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields(event, err))
}

// openDocumentsForPlugin opens every document of languageID in a newly started
// server's session. A file opened before its server was ready is therefore
// synchronized once the server exists, instead of waiting for another edit.
func (a *App) openDocumentsForPlugin(p *project, server *pluginServer, languageID string) {
	if a.project != p || server == nil {
		return
	}
	for _, d := range p.docs.list {
		if d.languageID == languageID {
			a.startDocumentSync(p, d)
		}
	}
}

// syncDocumentSaved tells the session that an exact buffer was written to disk.
// It is best effort: the server may not support didSave, and a failure is
// logged rather than reported as a save failure.
func (a *App) syncDocumentSaved(p *project, d *document, text []byte) {
	s := &d.sync
	server, pluginID := a.documentSyncServer(d)
	if server == nil || !s.opened || s.pluginID != pluginID || s.uri == "" {
		return
	}
	uri, saved := s.uri, string(text)
	a.background(p, documentSyncTimeout, func(ctx context.Context) func(*App) {
		_, err := server.session.Documents.Save(ctx, uri, saved)
		return func(a *App) {
			if err != nil {
				a.reportDocumentSyncFailure("plugin_document_save", ctx.Err(), err)
			}
		}
	})
}

// closeDocumentInSession removes a closed tab from its server and withdraws the
// diagnostics that server published for it. Core clears its own state on
// didClose; the host's copy must not outlive the document.
func (a *App) closeDocumentInSession(p *project, d *document) {
	a.pluginSemanticsDocumentClosed(d)
	s := &d.sync
	server, pluginID := a.documentSyncServer(d)
	uri, opened := s.uri, s.opened && s.pluginID == pluginID
	s.reset()
	if !opened || server == nil || uri == "" {
		return
	}
	a.clearPluginFileDiagnostics(pluginID, d.path)
	a.background(p, documentSyncTimeout, func(ctx context.Context) func(*App) {
		err := server.session.Documents.Close(ctx, uri)
		return func(a *App) {
			if err != nil {
				a.reportDocumentSyncFailure("plugin_document_close", ctx.Err(), err)
			}
		}
	})
}

// releasePluginDocuments invalidates the synchronization of every document held
// by one plugin, after its session stopped.
func (a *App) releasePluginDocuments(pluginID string) {
	if a.project == nil {
		return
	}
	a.pluginSemanticsReset()
	a.semanticTokensReleased(pluginID)
	for _, d := range a.project.docs.list {
		if d.sync.pluginID == pluginID {
			d.sync.reset()
		}
	}
}

// releaseAllPluginDocuments invalidates every document's synchronization when
// the project's sessions stop.
func (a *App) releaseAllPluginDocuments() {
	if a.project == nil {
		return
	}
	a.pluginSemanticsReset()
	a.semanticTokensReleased("")
	for _, d := range a.project.docs.list {
		d.sync.reset()
	}
}
