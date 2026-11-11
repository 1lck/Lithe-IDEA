package workbench

import (
	"context"
	"time"

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

// servedByContentProvider reports whether a plugin serves the URI's scheme.
func (a *App) servedByContentProvider(uri string) bool {
	p := a.project
	return a.plugins != nil && p != nil && a.plugins.HasContentProvider(p.root, uri)
}

// openContentTarget asks the provider for a URI and shows the answer. A failure
// opens nothing and tells the user once.
func (a *App) openContentTarget(p *project, uri string, line, column int) {
	if a.plugins == nil {
		return
	}
	if d := p.docs.byPath(uri); d != nil {
		a.selectDocument(p, d.id)
		d.view.GoToNavigation(line, column, false)
		return
	}
	a.background(p, contentOpenTimeout, func(ctx context.Context) func(*App) {
		err := a.plugins.OpenContentURI(ctx, p.root, uri, line, column)
		if err == nil {
			return nil
		}
		return func(a *App) {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_content", err))
			a.notifyError(i18n.SharedFormat(a.language(), "desktop.pluginHost.contentFailed", map[string]string{"uri": uri}))
		}
	})
}

// OpenVirtualDocument shows provider text in a read-only tab.
func (w pluginWorkbench) OpenVirtualDocument(ctx context.Context, root string, document pluginservice.VirtualDocument) error {
	// Laying the text out takes time in proportion to it, so it is done here and
	// the window thread only shows it.
	content := editorview.Prepare([]byte(document.Text))
	_, err := onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return struct{}{}, err
		}
		if d := p.docs.byPath(document.URI); d != nil {
			a.selectDocument(p, d.id)
			d.view.GoToNavigation(document.Line, document.Column, false)
			return struct{}{}, nil
		}
		registry := a.syntaxRegistry()
		var grammar = registry.Syntax("")
		if language, ok := registry.ForPath(document.Name); ok {
			grammar = registry.Syntax(language.ID)
		}
		a.placeDocumentAs(p, document.URI, document.Name, content, grammar, "", true)
		if d := p.docs.byPath(document.URI); d != nil {
			d.view.GoToNavigation(document.Line, document.Column, false)
		}
		return struct{}{}, nil
	})
	return err
}
