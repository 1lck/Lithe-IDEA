package workbench

import (
	"net/url"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// annotateDocumentLinks gives the view the document's links, each with its index as its ID.
func (a *App) annotateDocumentLinks(d *document) {
	links := make([]editorview.Link, 0, len(d.links))
	for index, link := range d.links {
		links = append(links, editorview.Link{
			ID:          index,
			StartLine:   link.StartLine,
			StartColumn: link.StartColumn,
			EndLine:     link.EndLine,
			EndColumn:   link.EndColumn,
		})
	}
	d.view.SetLinks(links)
}

// documentLinkPointer underlines the link under a pointer held with the link modifier, and opens it
// on a modifier click. It reports handled only for a click that opened a link; a hover never takes
// the pointer from the editor.
func (a *App) documentLinkPointer(event gfx.PointerEvent, d *document) (gfx.EventResult, bool) {
	if d == nil {
		return gfx.EventResult{}, false
	}
	switch event.Kind {
	case gfx.PointerMove:
		if !linkModifierHeld(event.Modifiers) {
			a.setHoveredLink(d, nil)
			return gfx.EventResult{}, false
		}
		if link, ok := d.view.LinkAt(event.X, event.Y); ok {
			a.setHoveredLink(d, &link)
		} else {
			a.setHoveredLink(d, nil)
		}
	case gfx.PointerExit:
		a.setHoveredLink(d, nil)
	case gfx.PointerDown:
		if event.Button != gfx.PointerButtonPrimary || !linkModifierHeld(event.Modifiers) {
			return gfx.EventResult{}, false
		}
		link, ok := d.view.LinkAt(event.X, event.Y)
		if !ok || link.ID < 0 || link.ID >= len(d.links) {
			return gfx.EventResult{}, false
		}
		a.openDocumentLink(d.links[link.ID])
		return gfx.EventResult{Handled: true, Repaint: true}, true
	}
	return gfx.EventResult{}, false
}

// setHoveredLink moves the underline and wakes the window only when it changed.
func (a *App) setHoveredLink(d *document, link *editorview.Link) {
	if d.view.SetHoveredLink(link) {
		a.invalidator.Invalidate()
	}
}

// linkModifierHeld is the modifier that asks for a link: Command on macOS, Control elsewhere.
func linkModifierHeld(modifiers gfx.Modifiers) bool {
	modifier := gfx.ModifierControl
	if runtime.GOOS == "darwin" {
		modifier = gfx.ModifierMeta
	}
	return modifiers&modifier != 0
}

// openDocumentLink follows one link: a file:// target opens in the editor, and http, https or mailto
// go to the system. Any other scheme is not followed.
func (a *App) openDocumentLink(link pluginservice.EditorLink) {
	target, err := url.Parse(link.Target)
	if err != nil {
		return
	}
	switch strings.ToLower(target.Scheme) {
	case "file":
		p := a.project
		if p == nil {
			return
		}
		a.performed("editor.documentLink.open", surfaceButton)
		a.openFileAtPosition(p, fileURIPath(target), 0, 0)
	case "http", "https", "mailto":
		a.performed("editor.documentLink.open", surfaceButton)
		if err := app.OpenURL(link.Target); err != nil {
			a.notify(i18n.SharedFormat(a.language(), "desktop.editor.linkOpenFailed", map[string]string{"reason": err.Error()}))
		}
	}
}

// fileURIPath is the local path of a file URI. A Windows drive path keeps its drive letter.
func fileURIPath(target *url.URL) string {
	path := target.Path
	if runtime.GOOS == "windows" && len(path) >= 3 && path[0] == '/' && path[2] == ':' {
		path = path[1:]
	}
	return filepath.FromSlash(path)
}

// Links from the language server. A server that declares documentLinks is asked for them when the
// text has settled, as the folding ranges are; an answer for a text that changed since is dropped.
// The plugin providers' links (collectEditorActions) join them, and the editor shows both.

const (
	// pluginSemanticDocumentLinks is the operation, featureDocumentLinks the feature a server
	// declares for it, and pluginMethodDocumentLinks the method Core reports the answer under.
	pluginSemanticDocumentLinks = "documentLinks"
	featureDocumentLinks        = "documentLinks"
	pluginMethodDocumentLinks   = "textDocument/documentLink"
	// documentLinkDelay is how long the text stays unchanged before the links are asked for.
	documentLinkDelay = 500 * time.Millisecond
)

// documentServerLinks is a document's language-server link requests and their answer.
type documentServerLinks struct {
	// revision is the text the links were last asked for; links is the answer for it.
	revision int
	links    []pluginservice.EditorLink
	pending  *semanticPending
	// changedAt is when the text was first seen at its current revision.
	changedAt time.Time
	seen      int
}

// linkSync asks for a shown document's server links when its text has settled since they were last
// asked for, or when its language server became able to answer.
func (a *App) linkSync(c ui.C, p *project, d *document) {
	s := &d.serverLinks
	if a.editorRequestWaiting(s.pending) {
		return
	}
	s.pending = nil
	revision := d.view.Revision()
	now := a.now()
	if s.seen != revision {
		s.seen, s.changedAt = revision, now
	}
	server, offered := a.editorServer(d, featureDocumentLinks)
	if server == nil || !offered || d.virtual || !a.semanticDocumentReady(d) || s.revision == revision {
		return
	}
	if s.revision >= 0 {
		if wait := s.changedAt.Add(documentLinkDelay).Sub(now); wait > 0 {
			c.Canvas().RequestFrameIn(wait)
			return
		}
	}
	s.revision = revision
	s.pending = a.submitEditorRequest(pluginSemanticDocumentLinks, p, d, server, core.PluginSemanticRequest{})
}

// applyServerDocumentLinks takes a server's documentLinks answer. A failed request or an answer for
// a text that has since changed leaves the links as they are.
func (a *App) applyServerDocumentLinks(pending *semanticPending, event core.BackendEvent, failed bool) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.serverLinks.pending != pending {
		return
	}
	d.serverLinks.pending = nil
	if failed {
		d.serverLinks.links = nil
		a.refreshDocumentLinks(d)
		return
	}
	if d.view.Revision() != pending.revision {
		return
	}
	links, err := core.PluginServerDocumentLinks(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("server_document_links", err))
		return
	}
	converted := make([]pluginservice.EditorLink, 0, len(links))
	for _, link := range links {
		// A link without a target has nothing to open until it is resolved, so it is not shown.
		if link.Target == nil || *link.Target == "" {
			continue
		}
		converted = append(converted, pluginservice.EditorLink{
			StartLine: link.StartLine, StartColumn: link.StartColumn, EndLine: link.EndLine, EndColumn: link.EndColumn,
			Target: *link.Target, Tooltip: derefString(link.Tooltip),
		})
	}
	d.serverLinks.links = converted
	a.refreshDocumentLinks(d)
}

// refreshDocumentLinks shows the plugin providers' links and the server's together.
func (a *App) refreshDocumentLinks(d *document) {
	links := make([]pluginservice.EditorLink, 0, len(d.pluginLinks)+len(d.serverLinks.links))
	links = append(links, d.pluginLinks...)
	links = append(links, d.serverLinks.links...)
	d.links = links
	a.annotateDocumentLinks(d)
}

func derefString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
