package workbench

import (
	"context"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// Where the system has a web engine, an HTML file opens as text with its page beside it, and the
// tab strip's switch shows the source, both, or the page alone, as for an SVG file. The page is
// the site page of package webpreview: Core names the folder it is served from, the workspace
// when the file lies in one (htmlPreview.site), and decides each request of the page
// (htmlPreview.resolveRequest), so the page loads its scripts, styles and pictures as from a
// local web server and is refused hidden files and keys. The file itself is served the editor's
// text, given at most once per htmlPreviewDelay: the page loads it again at once, scrolled where
// it was. A link the user follows off the site opens as a Markdown link does
// (followDocumentLink): a web or mail address in the system's application.
//
// The bar over the page moves back and forward through its history, loads it again, and opens
// the file in the system browser. Without a web engine, or where the page cannot be opened, an
// HTML file is text alone, and the editor's menu still opens it in the browser
// (browser_preview.go).

const (
	// htmlPreviewMaxBytes is the largest text the page is given.
	htmlPreviewMaxBytes = 8 << 20
	// htmlPreviewDelay is the least time between two texts of an edited file, so that typing does
	// not load the page again at every key.
	htmlPreviewDelay = 150 * time.Millisecond
)

// htmlPreviewWait calls done, from another goroutine, once htmlPreviewDelay passed. Tests replace
// it to end the wait when they choose.
var htmlPreviewWait = func(done func()) { time.AfterFunc(htmlPreviewDelay, done) }

// htmlKernel is what the page of an HTML file asks Core: the file's site, and what each request
// of the site serves.
type htmlKernel interface {
	HTMLPreviewSite(ctx context.Context, documentPath, workspaceRoot string) (core.HTMLPreviewSite, error)
	ResolveHTMLPreviewRequest(ctx context.Context, documentPath, workspaceRoot, path string) (core.HTMLPreviewResource, error)
}

// htmlPreviewState is the page of one HTML file.
type htmlPreviewState struct {
	// path is the file the page is of; a file that moves starts over.
	path string
	// site is the file's site once Core named it; asked says the question was put, failed that
	// Core could not answer it.
	site          *core.HTMLPreviewSite
	asked, failed bool
	entry         *previewPage
	// given is the editor revision the page was last given, -1 for none.
	given int
	// waiting says a change waits out htmlPreviewDelay; due says the wait is over.
	waiting, due bool
	// too says the text is over htmlPreviewMaxBytes.
	too bool
}

// isHTMLDocument reports whether d is an HTML file, by its name.
func isHTMLDocument(d *document) bool {
	if d != nil && d.previewKind == "HTML" {
		return true
	}
	if d == nil || d.virtual {
		return false
	}
	switch strings.ToLower(filepath.Ext(d.path)) {
	case ".html", ".htm", ".xhtml":
		return true
	}
	return false
}

// htmlPreviewable reports whether d is an HTML file whose page can be shown: the web host is
// ready, no page failed to open, and Core answers for its site.
func (a *App) htmlPreviewable(d *document) bool {
	if !isHTMLDocument(d) || !a.previewWeb() || a.previews.siteFailed {
		return false
	}
	_, ok := a.kernel.(htmlKernel)
	return ok
}

// htmlState is d's page state, made the first time it is shown and again when the file moved.
func (a *App) htmlState(d *document) *htmlPreviewState {
	if d.html == nil || d.html.path != d.path {
		d.html = &htmlPreviewState{path: d.path, given: -1}
	}
	return d.html
}

// htmlDocument declares the body of group for HTML file d in the file's mode: the source, the
// page, or the two in equal halves.
func (a *App) htmlDocument(c ui.C, p *project, group string, d *document) {
	switch d.pageMode {
	case pageSource:
		a.documentView(c, group, d)
		return
	case pageOnly:
		d.group = group
		a.htmlPage(c, p, d)
		return
	}
	ui.Row(c).Fill().Children(func() {
		ui.Column(c.Part("source")).Grow(1).Basis(0).FillHeight().Clip().Children(func() {
			a.documentView(c, group, d)
		})
		ui.Row(c).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
		ui.Column(c.Part("page")).Grow(1).Basis(0).FillHeight().Clip().Children(func() {
			a.htmlPage(c, p, d)
		})
	})
}

// htmlPage declares d's page under the viewer's bar, once Core named its site.
func (a *App) htmlPage(c ui.C, p *project, d *document) {
	s := a.htmlState(d)
	a.askHTMLSite(p, d, s)
	var entry *previewPage
	if s.site != nil {
		entry = a.htmlWebPage(p, d, s)
	}
	if entry != nil {
		a.giveHTML(d, s)
	}
	language := a.language()
	name := filepath.Base(d.path)
	ui.Column(c.Part("html")).Fill().Background(a.colors.Editor).Clip().Children(func() {
		bar := viewerBar{name: name, actions: func() { a.htmlActions(c, p, d, s, entry) }}
		if !s.too {
			bar.info = siteBarInfo(entry, name)
		}
		a.viewerToolbar(c, bar)
		switch {
		case s.failed:
			a.panelMessage(c, i18n.Shared(language, "desktop.htmlPreview.failed"), a.colors.Subtle)
		case entry == nil:
			// Core has not named the site yet.
		case s.too:
			a.panelMessage(c, i18n.Shared(language, "desktop.htmlPreview.tooLarge"), a.colors.Subtle)
		default:
			a.showSiteBody(c, entry, func() {
				if d.html == s && s.entry == entry {
					entry.close()
					s.entry = nil
					a.invalidator.Invalidate()
				}
			})
		}
	})
}

// htmlActions declares the buttons of d's page on the viewer's bar: back, forward and load
// again while the page is shown, and open in the system browser.
func (a *App) htmlActions(c ui.C, p *project, d *document, s *htmlPreviewState, entry *previewPage) {
	language := a.language()
	a.siteNavActions(c, entry, s.too)
	if browserPreviewable(d) && a.viewerIconButton(c.Part("browser"), i18n.Shared(language, "desktop.editorMenu.openInBrowser"), icons.ExternalLink) {
		c.After(func() { a.openInBrowser(p, d, surfaceButton) })
	}
}

// askHTMLSite asks Core for the site of d's page the first time the page is shown.
func (a *App) askHTMLSite(p *project, d *document, s *htmlPreviewState) {
	kernel, ok := a.kernel.(htmlKernel)
	if !ok || s.asked {
		return
	}
	s.asked = true
	path, root := d.path, p.previewWorkspaceRoot()
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		site, err := kernel.HTMLPreviewSite(ctx, path, root)
		return func(a *App) {
			if d.html != s {
				return
			}
			if err != nil {
				s.failed = true
				a.operationFailed("html_preview_site", err)
				return
			}
			s.site = &site
		}
	})
}

// htmlWebPage is the page of d, opened the first time it is shown once Core named its site, and
// again after it was closed. It is nil where the page cannot be opened.
func (a *App) htmlWebPage(p *project, d *document, s *htmlPreviewState) *previewPage {
	if s.entry != nil && !s.entry.closed {
		return s.entry
	}
	kernel, ok := a.kernel.(htmlKernel)
	if !ok {
		return nil
	}
	// A page opened again is given the text again.
	s.entry, s.given = nil, -1
	path, root := d.path, p.previewWorkspaceRoot()
	var entry *previewPage
	entry = a.openPreviewPage(webpreview.Config{
		Page:    webpreview.SitePage,
		Address: s.site.Address,
		Request: func(ctx context.Context, route string) (core.HTMLPreviewResource, error) {
			return kernel.ResolveHTMLPreviewRequest(ctx, path, root, route)
		},
		Follow: func(address string) {
			if entry != nil && s.entry == entry {
				a.followDocumentLink(p, path, address, nil)
			}
		},
		OnProcessFailed: func(failure app.WebProcessFailure) {
			if entry != nil && s.entry == entry && isWebProcessHostGone(failure) {
				entry.close()
				s.entry = nil
			}
			a.invalidator.Invalidate()
		},
	}, func() bool {
		return a.project == p && p.docs.find(d.id) == d && d.html == s && s.entry == entry && a.htmlPreviewable(d)
	})
	s.entry = entry
	return entry
}

// giveHTML gives the page d's text when it changed since the page was last given it, at once the
// first time and otherwise once htmlPreviewDelay passed since the change was seen.
func (a *App) giveHTML(d *document, s *htmlPreviewState) {
	revision := d.view.Revision()
	if revision == s.given || s.waiting {
		return
	}
	if s.given >= 0 && !s.due {
		s.waiting = true
		htmlPreviewWait(func() {
			a.post(func(*App) { s.waiting, s.due = false, true })
		})
		return
	}
	s.due = false
	text := d.view.TextSnapshot()
	s.given = revision
	if s.too = text.Len() > htmlPreviewMaxBytes; s.too {
		return
	}
	s.entry.view.SetDocument([]byte(text.String()), s.site.MIME)
}
