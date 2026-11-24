package workbench

import (
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Where the system has a web engine, an SVG file opens as text with its picture beside it, and
// the tab strip's switch shows the source, both, or the picture alone, as for a Markdown file.
// By default the picture uses the image page of package webpreview, with the image viewer's rules
// and bar (viewer_image.go), given the editor's text rather than the file: it follows each change,
// at most once per svgPreviewDelay, and keeps the user's zoom and scroll across changes. A change
// the engine cannot draw keeps the last picture it drew; a text it never could draw shows the
// viewer's failure. Toggling Interactive mode switches to an isolated ephemeral site page so
// hover, clicks, links, animations and scripts inside the SVG work natively. Without a web engine
// an SVG file is text alone.

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
	// interactive renders the SVG directly in an isolated ephemeral site page so hover, clicks,
	// links and scripts run natively instead of inside the static image viewer.
	interactive bool
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

// svgPage declares d's picture under the viewer's bar, which zooms it or switches to interactive mode.
func (a *App) svgPage(c ui.C, p *project, d *document) {
	s := a.svgState(d)
	entry := a.svgWebPage(p, d, s)
	if entry != nil {
		a.giveSVG(d, s)
	}
	name := filepath.Base(d.path)
	ui.Column(c.Part("svg")).Fill().Background(a.colors.Editor).Clip().Children(func() {
		bar := viewerBar{name: name, actions: func() { a.svgActions(c, p, d, s, entry) }}
		if s.interactive {
			if !s.too {
				bar.info = siteBarInfo(entry, name)
			}
		} else if entry != nil && !entry.closed && !s.too && !s.failed && s.zoom.known() {
			bar.info = strconv.Itoa(s.zoom.width) + " × " + strconv.Itoa(s.zoom.height)
			bar.zoom = &s.zoom
			bar.zoomTo = func(request zoomRequest) { entry.view.Send(zoomMessage(request)) }
		}
		a.viewerToolbar(c, bar)
		if entry == nil {
			return
		}
		switch {
		case s.too:
			a.panelMessage(c, i18n.Shared(a.language(), "desktop.svg.tooLarge"), a.colors.Subtle)
		case s.interactive:
			a.showSiteBody(c, entry, func() {
				if d.svg == s && s.entry == entry {
					entry.close()
					s.entry = nil
					a.invalidator.Invalidate()
				}
			})
		case s.failed:
			a.imageFailure(c, d.path)
		default:
			a.showPreviewPage(c, entry)
		}
	})
}

func (a *App) svgActions(c ui.C, p *project, d *document, s *svgPreviewState, entry *previewPage) {
	language := a.language()
	if s.interactive {
		a.siteNavActions(c, entry, s.too)
	}
	if a.svgInteractiveSwitch(c, s) {
		c.After(func() {
			s.interactive = !s.interactive
			if s.entry != nil {
				s.entry.close()
				s.entry = nil
			}
			s.given, s.waiting, s.due, s.zoom, s.failed = -1, false, false, imageZoom{}, false
			a.invalidator.Invalidate()
		})
	}
	if browserPreviewable(d) && a.viewerIconButton(c.Part("browser"), i18n.Shared(language, "desktop.editorMenu.openInBrowser"), icons.ExternalLink) {
		c.After(func() { a.openInBrowser(p, d, surfaceButton) })
	}
}

func (a *App) svgInteractiveSwitch(c ui.C, s *svgPreviewState) bool {
	language := a.language()
	disabled := !s.interactive && a.previews.siteFailed
	label := i18n.Shared(language, "desktop.svg.interactive")
	if disabled {
		label = i18n.Shared(language, "desktop.svg.interactiveUnavailable")
	}
	on := s.interactive
	k := c.Part("interactive")
	button := ui.Row(k).Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleSwitch, Checked: on, Disabled: disabled, Cursor: gfx.PointerCursorHand})
	iconColor := a.colors.Subtle
	switch {
	case disabled:
	case on:
		button = button.Background(a.colors.Active).Pressed(ui.Look{}.Background(a.colors.Active))
		iconColor = a.colors.Text
	default:
		button = button.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	}
	button.Tooltip(label).Children(func() {
		icon := ui.Icon(c, icons.Play).Size(shellIconSize, shellIconSize).Color(iconColor)
		if !disabled {
			icon.StateFrom(button).Hover(ui.Look{}.Color(a.colors.Text))
		}
	})
	return !disabled && button.Clicked()
}

// svgWebPage is the page of d's picture, opened the first time it is shown and again after it
// was closed. It is nil while the previews are native.
func (a *App) svgWebPage(p *project, d *document, s *svgPreviewState) *previewPage {
	if s.entry != nil && !s.entry.closed {
		return s.entry
	}
	// A page opened again is given the text again, at its fitted scale.
	s.entry, s.given, s.zoom, s.failed = nil, -1, imageZoom{}, false
	if s.interactive && a.previews.siteFailed {
		s.interactive = false
	}
	var entry *previewPage
	config := webpreview.Config{
		Page: webpreview.ImagePage,
		OnMessage: func(message webpreview.Message) {
			if entry != nil && s.entry == entry {
				a.svgWebMessage(s, entry, message)
			}
		},
	}
	if s.interactive {
		path := d.path
		config = webpreview.Config{
			Page:    webpreview.SitePage,
			Address: url.PathEscape(filepath.Base(path)),
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
		}
	}
	entry = a.openPreviewPage(config, func() bool {
		return a.project == p && p.docs.find(d.id) == d && d.svg == s && s.entry == entry && isSVGDocument(d)
	})
	if entry == nil && s.interactive && a.previews.siteFailed {
		// SitePage could not open (for example, WebView2 without ephemeral storage); fall back to
		// the image viewer page without disabling SVG previews.
		s.interactive = false
		return a.svgWebPage(p, d, s)
	}
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
	if (!s.interactive && !view.Ready()) || revision == s.given || s.waiting {
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
	if !s.interactive {
		// The address changes with the revision, so the engine does not draw a picture it cached.
		view.Send(imagePageShow{Type: "show", Src: "document?r=" + strconv.Itoa(revision), SVG: true, Keep: keep})
	}
}
