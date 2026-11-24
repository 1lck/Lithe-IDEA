package workbench

import (
	"context"
	"path"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The editor area shows some files in a web view of the system's engine, through the pages of
// package webpreview: the rendered page of a Markdown file (markdown_web.go), the viewer of an
// image, an SVG or a PDF file (viewer_web.go), and an HTML file with its site (html_preview.go).
//
// A page lives while what it shows is open. A paint that does not declare it hides it, as when
// its tab is not selected, and the page keeps its place and its layout, so the tab shows it as it
// was when it is selected again. Past previewPagesKept hidden pages, the one shown longest ago
// closes, and opens again when its tab comes back. Before the window's web host is ready, where
// the system has no web engine (Linux), and once a page could not be opened, the editor shows its
// native preview instead. An HTML file's page needs more of the engine than the others (a store
// of its own that keeps nothing); where it cannot be opened, HTML files alone are text from then
// on.
//
// Note: the decision is recorded in
// .agents/notes/implemented/architecture/2026-11-14-web-view-previews.md

// previewPagesKept is the most pages kept open while hidden.
const previewPagesKept = 6

// previewView is an open page; webpreview.Page is one, and tests stand in for it.
type previewView interface {
	ID() gfx.NativeViewID
	Ready() bool
	Send(message any)
	SetDocument(data []byte, mime string)
	FileURL() string
	Reload()
	Back()
	Forward()
	CanGoBack() bool
	CanGoForward() bool
	IsLoading() bool
	Title() string
	Crashed() bool
	ProcessFailure() app.WebProcessFailure
	LoadFailure() string
	CurrentPath() string
	Focus()
	Close()
}

// previewPages are the open pages of the editor area.
type previewPages struct {
	list []*previewPage
	// frame counts the paints; a page's shown is the paint that declared it last.
	frame uint64
	// failed says a page could not be opened: the previews are native from then on. siteFailed
	// says an HTML file's page could not: HTML files are text from then on.
	failed, siteFailed bool
	// remote fetches the web images of every Markdown page, native or not.
	remote *webpreview.Remote
	// open opens a page; nil is webpreview.Open. Tests replace it.
	open func(webpreview.Config) (previewView, error)
}

// previewPage is one open page.
type previewPage struct {
	view previewView
	// shown is the paint that declared the page last; alive says whether what it shows is open.
	shown  uint64
	alive  func() bool
	closed bool
	// colors is the palette the page was last given.
	colors palette
}

func (entry *previewPage) close() {
	if entry.closed {
		return
	}
	entry.closed = true
	entry.view.Close()
}

// previewTheme is the message that gives a page the window's look.
type previewTheme struct {
	Type  string              `json:"type"`
	Theme core.PluginWebTheme `json:"theme"`
}

// markdownKernel is what the Markdown previews ask Core: the HTML of a source, and what a link or
// an image of a document points at.
type markdownKernel interface {
	RenderMarkdown(ctx context.Context, source string) (string, error)
	ResolveMarkdownReference(ctx context.Context, documentPath, workspaceRoot, reference string, purpose core.MarkdownReferencePurpose) (core.MarkdownReference, error)
}

// previewWorkspaceRoot is the workspace given to Core when resolving a document's references.
// A standalone session has no workspace: p.root is only the first file's folder. With no root,
// Core uses each document's own folder for its image scope and root-relative references.
func (p *project) previewWorkspaceRoot() string {
	if p == nil || p.standalone {
		return ""
	}
	return p.root
}

// previewWeb reports whether pages can be opened: the web host is ready and no page failed to
// open.
func (a *App) previewWeb() bool {
	return a.sessions != nil && a.sessions.webReady && !a.previews.failed
}

// openPreviewPage opens a page that lives while alive says so. It is nil while the previews are
// native: before the web host is ready, without a web engine, or after a page failed to open.
func (a *App) openPreviewPage(config webpreview.Config, alive func() bool) *previewPage {
	if !a.previewWeb() {
		return nil
	}
	config.Host = &a.sessions.web
	config.Log = func(stage string, err error) {
		a.post(func(a *App) {
			a.backgroundFailed("web_preview_"+stage, err)
		})
	}
	open := a.previews.open
	if open == nil {
		open = openWebPreview
	}
	view, err := open(config)
	if err != nil {
		if config.Page == webpreview.SitePage {
			a.previews.siteFailed = true
		} else {
			a.previews.failed = true
		}
		a.operationFailed("web_preview_open", err)
		return nil
	}
	entry := &previewPage{view: view, shown: a.previews.frame, alive: alive}
	a.previews.list = append(a.previews.list, entry)
	return entry
}

func openWebPreview(config webpreview.Config) (previewView, error) {
	page, err := webpreview.Open(config)
	if err != nil {
		return nil, err
	}
	return page, nil
}

// showPreviewPage declares entry's page filling c, in the window's look.
func (a *App) showPreviewPage(c ui.C, entry *previewPage) {
	entry.shown = a.previews.frame
	if entry.view.Ready() && entry.colors != a.colors {
		entry.view.Send(previewTheme{Type: "theme", Theme: a.previewTheme(entry)})
	}
	ui.Slot(c).Fill().NativeView(entry.view.ID())
}

// previewTheme is the window's look for entry's page, which is about to be given it.
func (a *App) previewTheme(entry *previewPage) core.PluginWebTheme {
	entry.colors = a.colors
	return a.pluginPageTheme()
}

// endPreviewFrame closes the pages of files no longer open and the hidden pages past
// previewPagesKept, the one shown longest ago first.
func (a *App) endPreviewFrame() {
	pages := &a.previews
	hidden := 0
	for _, entry := range pages.list {
		if !entry.closed && !entry.alive() {
			entry.close()
		}
		if !entry.closed && entry.shown != pages.frame {
			hidden++
		}
	}
	for ; hidden > previewPagesKept; hidden-- {
		var oldest *previewPage
		for _, entry := range pages.list {
			if !entry.closed && entry.shown != pages.frame && (oldest == nil || entry.shown < oldest.shown) {
				oldest = entry
			}
		}
		oldest.close()
	}
	pages.list = slices.DeleteFunc(pages.list, func(entry *previewPage) bool { return entry.closed })
	pages.frame++
}

// closePreviewPages closes every page, for a project that closes.
func (a *App) closePreviewPages() {
	for _, entry := range a.previews.list {
		entry.close()
	}
	a.previews.list = nil
}

// previewRemote is the fetcher of the web images of Markdown pages, shared by all of them.
func (a *App) previewRemote() *webpreview.Remote {
	if a.previews.remote == nil {
		a.previews.remote = &webpreview.Remote{Fetch: downloadMarkdownImage}
	}
	return a.previews.remote
}

// siteBarInfo returns the document title or active sub-page path for a site preview toolbar.
func siteBarInfo(entry *previewPage, fileName string) string {
	if entry == nil || entry.closed {
		return ""
	}
	if title := strings.TrimSpace(entry.view.Title()); title != "" && title != fileName {
		return title
	}
	if current := entry.view.CurrentPath(); current != "" {
		if base := path.Base(current); base != "" && base != "." && base != "/" && base != fileName {
			return current
		}
	}
	return ""
}

// siteNavActions declares the loading spinner and history controls for an interactive site page.
func (a *App) siteNavActions(c ui.C, entry *previewPage, tooLarge bool) {
	if entry == nil || entry.closed || tooLarge {
		return
	}
	language := a.language()
	if entry.view.IsLoading() {
		ui.Spinner(c.Part("loading")).Size(12, 12).Shrink(0)
	}
	if a.viewerIconButtonDisabled(c.Part("back"), i18n.Shared(language, "desktop.htmlPreview.back"), icons.ChevronLeft, !entry.view.CanGoBack()) {
		entry.view.Back()
	}
	if a.viewerIconButtonDisabled(c.Part("forward"), i18n.Shared(language, "desktop.htmlPreview.forward"), icons.ChevronRight, !entry.view.CanGoForward()) {
		entry.view.Forward()
	}
	if a.viewerIconButton(c.Part("reload"), i18n.Shared(language, "desktop.htmlPreview.reload"), icons.RefreshCw) {
		entry.view.Reload()
	}
}

// showSiteBody renders a site page or a reloadable recovery state when its process or load failed.
func (a *App) showSiteBody(c ui.C, entry *previewPage, reopen func()) {
	language := a.language()
	switch {
	case entry.view.Crashed():
		if isWebProcessHostGone(entry.view.ProcessFailure()) {
			if reopen != nil {
				c.After(reopen)
			}
			return
		}
		message := i18n.Shared(language, "desktop.htmlPreview.crashed")
		if entry.view.ProcessFailure() == app.WebProcessKilled || entry.view.ProcessFailure() == app.WebProcessUnresponsive {
			message = i18n.Shared(language, "desktop.htmlPreview.stopped")
		}
		a.previewReloadMessage(c, message, func() { entry.view.Reload() })
	case entry.view.LoadFailure() != "":
		message := i18n.SharedFormat(language, "desktop.htmlPreview.loadFailed", map[string]string{"reason": entry.view.LoadFailure()})
		a.previewReloadMessage(c, message, func() { entry.view.Reload() })
	default:
		a.showPreviewPage(c, entry)
	}
}

// isWebProcessHostGone reports whether failure indicates the web engine's host process exited
// (Viva maps that state in platform.WebProcessHostGone without exporting the constant in app).
func isWebProcessHostGone(failure app.WebProcessFailure) bool {
	return failure.String() == "host process gone"
}

// previewReloadMessage centers message in the preview area with a Reload action button.
func (a *App) previewReloadMessage(c ui.C, message string, reload func()) {
	language := a.language()
	ui.Column(c).Fill().Center().Gap(10).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, message, 3).FillWidth().TextCenter().Color(a.colors.Subtle)
		if reload != nil && ui.Button(c.Part("reload-page"), i18n.Shared(language, "desktop.htmlPreview.reload")).Outline().Clicked() {
			c.After(reload)
		}
	})
}
