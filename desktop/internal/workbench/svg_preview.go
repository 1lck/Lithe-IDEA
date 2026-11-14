package workbench

import (
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/ui"
)

// Where the system has a web engine, an SVG file opens as text with its picture beside it, and
// the tab strip's switch shows the source, both, or the picture alone, as for a Markdown file.
// The picture is the image page of package webpreview, with the image viewer's rules and bar
// (viewer_image.go), given the editor's text rather than the file: it follows each change, at
// most once per svgPreviewDelay, and keeps the user's zoom and scroll across changes. A change
// the engine cannot draw keeps the last picture it drew; a text it never could draw shows the
// viewer's failure. Without a web engine an SVG file is text alone.

const (
	// svgPreviewMaxBytes is the largest text the picture is drawn for.
	svgPreviewMaxBytes = 4 << 20
	// svgPreviewDelay is the least time between two pictures of an edited text, so that typing
	// does not decode the picture at every key.
	svgPreviewDelay = 150 * time.Millisecond
)

// svgPreviewWait calls done, from another goroutine, once svgPreviewDelay passed. Tests replace
// it to end the wait when they choose.
var svgPreviewWait = func(done func()) { time.AfterFunc(svgPreviewDelay, done) }

// svgPreviewState is the picture of one SVG file.
type svgPreviewState struct {
	entry *previewPage
	// given is the editor revision the page was last given, -1 for none.
	given int
	// waiting says a change waits out svgPreviewDelay; due says the wait is over.
	waiting, due bool
	// zoom is what the page last reported of the picture.
	zoom imageZoom
	// failed says the page could not draw the text it was given and had drawn none before; too
	// says the text is over svgPreviewMaxBytes.
	failed, too bool
}

// isSVGDocument reports whether d is an SVG file, by its name.
func isSVGDocument(d *document) bool {
	return d != nil && !d.virtual && strings.EqualFold(filepath.Ext(d.path), ".svg")
}

// svgState is d's picture state, made the first time it is shown.
func (a *App) svgState(d *document) *svgPreviewState {
	if d.svg == nil {
		d.svg = &svgPreviewState{given: -1}
	}
	return d.svg
}

// svgDocument declares the body of group for SVG file d in the file's mode: the source, the
// picture, or the two in equal halves.
func (a *App) svgDocument(c ui.C, p *project, group string, d *document) {
	switch d.pageMode {
	case pageSource:
		a.documentView(c, group, d)
		return
	case pageOnly:
		d.group = group
		a.svgPage(c, p, d)
		return
	}
	ui.Row(c).Fill().Children(func() {
		ui.Column(c.Part("source")).Grow(1).Basis(0).FillHeight().Clip().Children(func() {
			a.documentView(c, group, d)
		})
		ui.Row(c).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
		ui.Column(c.Part("page")).Grow(1).Basis(0).FillHeight().Clip().Children(func() {
			a.svgPage(c, p, d)
		})
	})
}

// svgPage declares d's picture under the viewer's bar, which zooms it.
func (a *App) svgPage(c ui.C, p *project, d *document) {
	s := a.svgState(d)
	ui.Column(c.Part("svg")).Fill().Background(a.colors.Editor).Clip().Children(func() {
		bar := viewerBar{name: filepath.Base(d.path)}
		if s.entry != nil && !s.entry.closed && !s.too && !s.failed && s.zoom.known() {
			entry := s.entry
			bar.info = strconv.Itoa(s.zoom.width) + " × " + strconv.Itoa(s.zoom.height)
			bar.zoom = &s.zoom
			bar.zoomTo = func(request zoomRequest) { entry.view.Send(zoomMessage(request)) }
		}
		a.viewerToolbar(c, bar)
		entry := a.svgWebPage(p, d, s)
		if entry == nil {
			return
		}
		a.giveSVG(d, s)
		switch {
		case s.too:
			a.panelMessage(c, i18n.Shared(a.language(), "desktop.svg.tooLarge"), a.colors.Subtle)
		case s.failed:
			a.imageFailure(c, d.path)
		default:
			a.showPreviewPage(c, entry)
		}
	})
}

// svgWebPage is the page of d's picture, opened the first time it is shown and again after it
// was closed. It is nil while the previews are native.
func (a *App) svgWebPage(p *project, d *document, s *svgPreviewState) *previewPage {
	if s.entry != nil && !s.entry.closed {
		return s.entry
	}
	// A page opened again is given the text again, at its fitted scale.
	s.entry, s.given, s.zoom, s.failed = nil, -1, imageZoom{}, false
	var entry *previewPage
	entry = a.openPreviewPage(webpreview.Config{
		Page: webpreview.ImagePage,
		OnMessage: func(message webpreview.Message) {
			if entry != nil && s.entry == entry {
				a.svgWebMessage(s, entry, message)
			}
		},
	}, func() bool {
		return a.project == p && p.docs.find(d.id) == d && d.svg == s && s.entry == entry && isSVGDocument(d)
	})
	s.entry = entry
	return entry
}

// svgWebMessage takes in what d's picture page posted.
func (a *App) svgWebMessage(s *svgPreviewState, entry *previewPage, message webpreview.Message) {
	switch message.Type {
	case "ready":
		// A page that loads, or loads again, is given the window's look, then the text.
		entry.view.Send(previewTheme{Type: "setup", Theme: a.previewTheme(entry)})
		s.given, s.zoom, s.failed = -1, imageZoom{}, false
	case "scale":
		s.zoom = imageZoom{shown: message.Scale, fit: message.Fit, width: message.Width, height: message.Height}
		s.failed = false
	case "failed":
		// The page keeps the last picture it drew; only a text never drawn shows the failure.
		s.failed = !s.zoom.known()
	}
	a.invalidator.Invalidate()
}

// giveSVG gives the page d's text when it changed since the page was last given it, at once the
// first time and otherwise once svgPreviewDelay passed since the change was seen.
func (a *App) giveSVG(d *document, s *svgPreviewState) {
	view := s.entry.view
	revision := d.view.Revision()
	if !view.Ready() || revision == s.given || s.waiting {
		return
	}
	if s.given >= 0 && !s.due {
		s.waiting = true
		svgPreviewWait(func() {
			a.post(func(*App) { s.waiting, s.due = false, true })
		})
		return
	}
	s.due = false
	text := d.view.TextSnapshot()
	keep := s.given >= 0
	s.given = revision
	if s.too = text.Len() > svgPreviewMaxBytes; s.too {
		return
	}
	view.SetDocument([]byte(text.String()), "image/svg+xml")
	// The address changes with the revision, so the engine does not draw a picture it cached.
	view.Send(imagePageShow{Type: "show", Src: "document?r=" + strconv.Itoa(revision), SVG: true, Keep: keep})
}
