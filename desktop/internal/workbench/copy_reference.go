package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// A secondary press chooses the line under the pointer, not the previous
// keyboard caret. The press belongs to the menu it opens: the menu's item
// consumes the coordinate after the popup closes, and a menu closed without it
// drops the coordinate (referenceMenuPainted), so a menu Shift+F10 opens later
// reads the caret. Each operation owns a revision and an identity token.
type referenceClick struct {
	documentID   int
	line, column int
	// menuShown says the menu the press opened has been painted.
	menuShown bool
}

type referenceRequest struct {
	project              *project
	documentID, revision int
	line, column         int
	path                 string
	pending              *semanticPending
	// wait ends the wait for pending's symbols (awaitReferenceSymbols); it is stopped when
	// the symbols arrive or the request is replaced.
	wait *time.Timer
}

// referenceSymbolsTimeout bounds how long copying waits for the language server's symbols.
// Submitting the request is bounded by semanticStartTimeout, but nothing bounds the answer: a
// server that is indexing or stuck would leave the menu choice without a result. Past this
// wait the request is cancelled and the file and line are copied, as without a server.
const referenceSymbolsTimeout = 3 * time.Second

type copyReferenceState struct {
	click   *referenceClick
	request *referenceRequest
	// symbolsWait overrides referenceSymbolsTimeout for tests.
	symbolsWait time.Duration
}

type referenceKernel interface {
	CopyReferenceLocation(context.Context, core.ReferenceLocationRequest) (core.ReferenceLocationResult, error)
}

func (a *App) copyReferenceLocation(p *project, d *document) {
	if p == nil || d == nil || d.virtual || d.path == "" || a.project != p {
		return
	}
	kernel, ok := a.kernel.(referenceKernel)
	if !ok {
		return
	}
	a.performed("editor.copyReferenceLocation", surfaceContextMenu)
	line, column := d.view.CaretUTF16()
	if click := a.editor.copyReference.click; click != nil && click.documentID == d.id {
		line, column = click.line, click.column
	}
	a.editor.copyReference.click = nil
	if previous := a.editor.copyReference.request; previous != nil {
		previous.stopWait()
		if previous.pending != nil {
			a.cancelSemantic(previous.pending)
		}
	}
	request := &referenceRequest{
		project: p, documentID: d.id, revision: d.view.Revision(),
		line: line, column: column, path: d.path,
	}
	a.editor.copyReference.request = request

	// A loaded Structure result can be used only for exactly this document
	// revision. Otherwise ask the same LSP documentSymbols feature directly;
	// never use a stale tree from a previous document or unsaved edit.
	outline := &a.editor.outline
	if outline.project == p && outline.documentID == d.id && outline.loaded &&
		outline.revision == request.revision {
		a.finishReferenceLocation(request, outline.symbols, kernel)
		return
	}
	server, offered := a.editorServer(d, featureDocumentSymbols)
	if offered && server != nil && a.semanticDocumentReady(d) {
		request.pending = a.submitEditorRequest(pluginSemanticCopyReference, p, d, server, core.PluginSemanticRequest{})
		a.awaitReferenceSymbols(request)
		return
	}
	// An unavailable or unsynchronized language server does not block copying:
	// the shared Core produces a path reference instead of guessing symbols.
	a.finishReferenceLocation(request, nil, kernel)
}

// referenceMenuPainted follows the editor menu of d in the paint that declared it: a press on
// d is kept while the menu it opened shows and dropped once that menu has closed.
func (a *App) referenceMenuPainted(d *document, shown bool) {
	click := a.editor.copyReference.click
	if click == nil || click.documentID != d.id {
		return
	}
	switch {
	case shown:
		click.menuShown = true
	case click.menuShown:
		a.editor.copyReference.click = nil
	}
}

// awaitReferenceSymbols cancels request's symbols request once referenceSymbolsTimeout passes
// without an answer and copies the reference without symbols.
func (a *App) awaitReferenceSymbols(request *referenceRequest) {
	wait := a.editor.copyReference.symbolsWait
	if wait <= 0 {
		wait = referenceSymbolsTimeout
	}
	pending := request.pending
	request.wait = time.AfterFunc(wait, func() {
		a.post(func(a *App) {
			if a.editor.copyReference.request != request || request.pending != pending {
				return
			}
			a.backgroundFailed("editor_copy_reference_symbols", context.DeadlineExceeded)
			a.cancelSemantic(pending)
			a.applyReferenceSymbols(pending, core.BackendEvent{}, true)
		})
	})
}

// stopWait ends the wait for the symbols, if one is running.
func (r *referenceRequest) stopWait() {
	if r.wait != nil {
		r.wait.Stop()
		r.wait = nil
	}
}

// applyReferenceSymbols is reached through the ordinary semantic event router.
// Failed, unsupported or malformed symbols retain a useful file/line fallback.
func (a *App) applyReferenceSymbols(pending *semanticPending, event core.BackendEvent, failed bool) {
	request := a.editor.copyReference.request
	if request == nil || request.pending != pending {
		return
	}
	request.pending = nil
	request.stopWait()
	p, d := a.currentSemanticDocument(request.documentID)
	if p != request.project || d == nil || d.view.Revision() != request.revision {
		// The symbols describe a text the user has since changed or closed: nothing is copied.
		a.editor.copyReference.request = nil
		return
	}
	var symbols []core.DocumentSymbol
	if !failed {
		var err error
		symbols, err = core.PluginDocumentSymbols(event)
		if err != nil {
			a.backgroundFailed("editor_copy_reference_symbols", err)
		}
	}
	if kernel, ok := a.kernel.(referenceKernel); ok {
		a.finishReferenceLocation(request, symbols, kernel)
	}
}

func (a *App) finishReferenceLocation(request *referenceRequest, symbols []core.DocumentSymbol, kernel referenceKernel) {
	a.background(request.project, kernelCallTimeout, func(ctx context.Context) func(*App) {
		result, err := kernel.CopyReferenceLocation(ctx, core.ReferenceLocationRequest{
			Path: request.path, Line: request.line, UTF16Column: request.column, Symbols: symbols,
		})
		return func(a *App) {
			if a.editor.copyReference.request != request || a.project != request.project {
				return
			}
			d := request.project.docs.find(request.documentID)
			if d == nil || d.view.Revision() != request.revision ||
				request.project.selectedDocument(request.project.docs.group) != d {
				a.editor.copyReference.request = nil
				return
			}
			a.editor.copyReference.request = nil
			if err != nil {
				a.operationFailed("editor_copy_reference", err)
				a.notifyError(a.text.Errors.Core(err.Error()))
				return
			}
			if err := app.SetClipboardText(result.Reference); err != nil {
				a.operationFailed("clipboard_copy", err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.copyFailed", map[string]string{"reason": err.Error()}))
			}
		}
	})
}
