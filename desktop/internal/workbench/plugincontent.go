package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// Documents without a file: a plugin provides the text of a URI such as a class
// inside a jar, and the editor shows it read-only. The host keeps no copy of the
// text once the tab closes and asks the plugin again on reopening.

// contentOpenTimeout bounds asking the plugin and preparing the tab: the provider's
// own 30 second wait plus room to start its backend.
const contentOpenTimeout = 2 * time.Minute

var _ pluginservice.VirtualDocumentHost = pluginWorkbench{}

// The read belongs to the visible source caret. The token stays on the native
// context; it is never part of the plugin protocol or a language-specific rule.
type contentOpenKey struct{}
type contentOpenRequest struct {
	project                *project
	source                 *document
	revision, line, column int
	cancel                 context.CancelFunc
}

func (r *contentOpenRequest) current(a *App) bool {
	if r.project != a.project || r.source == nil || r.project.docs.find(r.source.id) != r.source || r.project.selectedDocument(r.project.docs.group) != r.source {
		return false
	}
	line, column := r.source.view.CaretUTF16()
	return r.source.view.Revision() == r.revision && line == r.line && column == r.column
}

func (a *App) cancelContentOpen() {
	if a.contentOpen != nil {
		a.contentOpen.cancel()
		a.contentOpen = nil
	}
}

func contentOpenAllowed(a *App, ctx context.Context) bool {
	request, _ := ctx.Value(contentOpenKey{}).(*contentOpenRequest)
	return request == nil || (a.contentOpen == request && request.current(a))
}

// servedByContentProvider reports whether a plugin serves the URI's scheme.
func (a *App) servedByContentProvider(uri string) bool {
	p := a.project
	return a.plugins != nil && p != nil && a.plugins.HasContentProvider(p.root, uri)
}

// openContentTarget asks the provider for a URI and shows the answer. A failure
// opens nothing and tells the user once.
func (a *App) openContentTarget(p *project, uri string, line, column int) {
	a.cancelContentOpen()
	if a.plugins == nil {
		return
	}
	if d := p.docs.byPath(uri); d != nil {
		a.selectDocument(p, d.id)
		d.view.GoToNavigation(line, column, false)
		return
	}
	source := p.selectedDocument(p.docs.group)
	if source == nil {
		return
	}
	readContext, cancel := context.WithCancel(context.Background())
	row, col := source.view.CaretUTF16()
	request := &contentOpenRequest{project: p, source: source, revision: source.view.Revision(), line: row, column: col, cancel: cancel}
	a.contentOpen = request
	readContext = context.WithValue(readContext, contentOpenKey{}, request)
	a.background(p, contentOpenTimeout, func(ctx context.Context) func(*App) {
		stop := context.AfterFunc(ctx, cancel)
		defer stop()
		defer cancel()
		err := a.plugins.OpenContentURI(readContext, p.root, uri, line, column)
		if errors.Is(err, context.Canceled) && ctx.Err() != nil {
			err = ctx.Err()
		}
		return func(a *App) {
			if a.contentOpen == request {
				a.contentOpen = nil
			}
			// log-exempt: user cancellation: an abandoned navigation opens no tab.
			if err == nil || errors.Is(err, context.Canceled) {
				return
			}
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_content", err))
			a.notifyError(i18n.SharedFormat(a.language(), "desktop.pluginHost.contentFailed", map[string]string{"uri": uri}))
		}
	})
}

// OpenVirtualDocument shows provider text in a read-only tab.
func (w pluginWorkbench) OpenVirtualDocument(ctx context.Context, root string, document pluginservice.VirtualDocument) error {
	registry, err := onWindow(w.app, ctx, func(a *App) (*syntax.Registry, error) {
		if !contentOpenAllowed(a, ctx) {
			return nil, context.Canceled
		}
		return a.syntaxRegistry(), nil
	})
	if err != nil {
		return err
	}
	// Laying the text out takes time in proportion to it, so it is done here and
	// the window thread only shows it. Grammar loading follows the same path as
	// disk documents and must also stay off the window thread.
	content := editorview.Prepare([]byte(document.Text))
	grammar := registry.SyntaxForPath(document.Name)
	languageID := ""
	if language, ok := registry.ForPath(document.Name); ok {
		languageID = language.ID
	}
	_, err = onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		if !contentOpenAllowed(a, ctx) {
			return struct{}{}, context.Canceled
		}
		p, err := a.projectAt(root)
		if err != nil {
			return struct{}{}, err
		}
		// The UI commit is synchronous. Clear the read owner before selecting
		// its destination, so ordinary focus cleanup cannot cancel this commit.
		if request, _ := ctx.Value(contentOpenKey{}).(*contentOpenRequest); request != nil && a.contentOpen == request {
			a.contentOpen = nil
		}
		if d := p.docs.byPath(document.URI); d != nil {
			a.selectDocument(p, d.id)
			d.view.GoToNavigation(document.Line, document.Column, false)
			return struct{}{}, nil
		}
		a.placeDocumentAs(p, document.URI, document.Name, content, grammar, languageID, true)
		if d := p.docs.byPath(document.URI); d != nil {
			d.view.GoToNavigation(document.Line, document.Column, false)
		}
		return struct{}{}, nil
	})
	return err
}
