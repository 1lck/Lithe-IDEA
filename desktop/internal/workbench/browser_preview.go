package workbench

import (
	"context"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// HTML and SVG files are text the editor edits; where the system has a web engine, what they look
// like is also shown beside the text (html_preview.go, svg_preview.go). "Open in Browser" shows
// the file in the default web browser, as IntelliJ IDEA's does: the browser http links open in,
// whatever application the file's type is associated with, which is often an editor. The file on
// disk is opened, so unsaved changes are saved first.

// browserExtensions are the files a browser shows.
var browserExtensions = map[string]bool{".html": true, ".htm": true, ".xhtml": true, ".svg": true}

// browserPreviewable reports whether d is a file on disk a browser can show.
func browserPreviewable(d *document) bool {
	return d != nil && !d.virtual && d.path != "" && browserExtensions[strings.ToLower(filepath.Ext(d.path))]
}

// openInBrowser saves d when it has changes and opens the file in the default web browser. The
// system is asked off the window thread: on macOS the handoff waits for open to report.
func (a *App) openInBrowser(p *project, d *document, surface actionSurface) {
	if !browserPreviewable(d) {
		return
	}
	open := func() {
		path := d.path
		a.background(nil, 0, func(context.Context) func(*App) {
			err := app.OpenPathInBrowser(path)
			return func(a *App) {
				if err != nil {
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_open_in_browser", documentLogError(err)))
					a.notifyError(i18n.SharedFormat(a.language(), "desktop.editorMenu.openInBrowserFailed", map[string]string{"reason": err.Error()}))
					return
				}
				a.performed("editor.openInBrowser", surface)
			}
		})
	}
	if d.dirty() || d.saving {
		a.saveBeforeClose(p, d, func(ok bool) {
			if ok {
				open()
			}
		})
		return
	}
	open()
}
