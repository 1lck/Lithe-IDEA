package workbench

import (
	"net/url"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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
