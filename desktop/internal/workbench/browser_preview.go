package workbench

import (
	"net/url"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// HTML and SVG files are text the editor edits; what they look like is shown by the system
// browser, as IntelliJ IDEA's "Open in Browser" does. The file on disk is opened, so unsaved
// changes are saved first.

// browserExtensions are the files a browser shows.
var browserExtensions = map[string]bool{".html": true, ".htm": true, ".xhtml": true, ".svg": true}

// browserPreviewable reports whether d is a file on disk a browser can show.
func browserPreviewable(d *document) bool {
	return d != nil && !d.virtual && d.path != "" && browserExtensions[strings.ToLower(filepath.Ext(d.path))]
}

// openInBrowser saves d when it has changes and opens the file in the system browser.
func (a *App) openInBrowser(p *project, d *document) {
	if !browserPreviewable(d) {
		return
	}
	open := func() {
		address := (&url.URL{Scheme: "file", Path: filepath.ToSlash(d.path)}).String()
		if !strings.HasPrefix(filepath.ToSlash(d.path), "/") {
			// A Windows path such as C:/x.html is file:///C:/x.html.
			address = "file:///" + filepath.ToSlash(d.path)
		}
		if err := openURL(address); err != nil {
			a.notifyError(i18n.SharedFormat(a.language(), "desktop.editorMenu.openInBrowserFailed", map[string]string{"reason": err.Error()}))
			return
		}
		a.performed("editor.openInBrowser", surfaceMenu)
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
