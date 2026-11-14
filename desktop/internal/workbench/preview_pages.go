package workbench

import (
	"context"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The editor area shows some files in a web view of the system's engine, through the pages of
// package webpreview: the rendered page of a Markdown file (markdown_web.go), and the viewer of
// an image, an SVG or a PDF file (viewer_web.go).
//
// A page lives while what it shows is open. A paint that does not declare it hides it, as when
// its tab is not selected, and the page keeps its place and its layout, so the tab shows it as it
// was when it is selected again. Past previewPagesKept hidden pages, the one shown longest ago
// closes, and opens again when its tab comes back. Before the window's web host is ready, where
// the system has no web engine (Linux), and once a page could not be opened, the editor shows its
// native preview instead.
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
	Close()
}

// previewPages are the open pages of the editor area.
type previewPages struct {
	list []*previewPage
	// frame counts the paints; a page's shown is the paint that declared it last.
	frame uint64
	// failed says a page could not be opened: the previews are native from then on.
	failed bool
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

// previewWeb reports whether pages can be opened: the web host is ready and no page failed to
// open.
func (a *App) previewWeb() bool {
	return a.webReady && !a.previews.failed
}

// openPreviewPage opens a page that lives while alive says so. It is nil while the previews are
// native: before the web host is ready, without a web engine, or after a page failed to open.
func (a *App) openPreviewPage(config webpreview.Config, alive func() bool) *previewPage {
	if !a.previewWeb() {
		return nil
	}
	config.Host = &a.web
	config.Log = func(stage string, err error) {
		a.post(func(a *App) {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("web_preview_"+stage, err))
		})
	}
	open := a.previews.open
	if open == nil {
		open = openWebPreview
	}
	view, err := open(config)
	if err != nil {
		a.previews.failed = true
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("web_preview_open", err))
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
