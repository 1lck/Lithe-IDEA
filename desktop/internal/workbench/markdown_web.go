package workbench

import (
	"context"
	"math"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/ui"
)

// Where the system has a web engine, a Markdown file's page is shown in a web view (the
// Markdown page of package webpreview) so that it shows what a README holds besides Markdown:
// raw HTML, inline SVG, math, highlighted code and diagrams. Core renders the source to
// sanitized HTML in the dialect every Lithe frontend shares (markdown.render); the page lays it
// out and draws the rest itself, with scripts embedded in the application.
//
// The page and the source scroll together by source line, as the native page does: the page
// reports the line at its top as the user scrolls it and is told the line at the editor's top as
// the editor scrolls, each without echoing the other's move. Links come back to the host, which
// follows them as Core resolves them (followMarkdownLink), and the page's images are served as
// Core resolves them. The source is rendered again after each change, one rendering at a time.

// markdownRenderTimeout bounds Core's rendering of one revision.
const markdownRenderTimeout = 10 * time.Second

// markdownWeb is the web page of one Markdown file.
type markdownWeb struct {
	entry *previewPage
	// path is the file the page was opened for.
	path string
	// rendered is the editor revision the page was last given and html its HTML; rendering is
	// the revision Core is rendering, -1 for none.
	rendered, rendering int
	html                string
	// line is the source line at the page's top, from 1 and fractional.
	line float64
	// language is the language of the strings the page was given.
	language i18n.Language
}

// The messages the Markdown page takes.
type (
	markdownPageSetup struct {
		Type    string              `json:"type"`
		Strings map[string]string   `json:"strings"`
		Theme   core.PluginWebTheme `json:"theme"`
	}
	markdownPageRender struct {
		Type     string `json:"type"`
		Revision int    `json:"revision"`
		HTML     string `json:"html"`
	}
	markdownPageScroll struct {
		Type string  `json:"type"`
		Line float64 `json:"line"`
	}
)

// markdownWebPage is the web page of d, opened the first time it is shown and again after it was
// closed or the file renamed. It is nil while the page is native.
func (a *App) markdownWebPage(p *project, d *document, s *markdownPreviewState) *markdownWeb {
	if w := s.web; w != nil && !w.entry.closed && w.path == d.path {
		return w
	}
	line := 1.0
	if w := s.web; w != nil {
		w.entry.close()
		if w.path == d.path {
			line = w.line
		} else {
			s.headings, s.contents, s.contentsOpen = s.headings[:0], ui.ListState{}, false
		}
		s.web = nil
		// The page Viva draws, if it is shown instead, parses the source again: the headings
		// were the web page's.
		s.revision = -1
	}
	kernel, ok := a.kernel.(markdownKernel)
	if !ok || !a.previewWeb() {
		return nil
	}
	w := &markdownWeb{path: d.path, rendered: -1, rendering: -1, line: line}
	// The page asks for its images on goroutines of its own: what they need is copied here.
	path, root := d.path, p.root
	entry := a.openPreviewPage(webpreview.Config{
		Page: webpreview.MarkdownPage,
		Resolve: func(ctx context.Context, reference string) (core.MarkdownReference, error) {
			return kernel.ResolveMarkdownReference(ctx, path, root, reference, core.MarkdownResource)
		},
		Remote: a.previewRemote(),
		OnMessage: func(message webpreview.Message) {
			if s.web == w {
				a.markdownWebMessage(p, d, s, w, message)
			}
		},
		Follow: func(address string) {
			if s.web == w {
				a.followMarkdownLink(p, d, s, address)
			}
		},
	}, func() bool {
		return a.project == p && p.docs.find(d.id) == d && d.markdown == s && s.web == w && isMarkdownDocument(d)
	})
	if entry == nil {
		return nil
	}
	w.entry = entry
	s.web = w
	s.revision = -1
	return w
}

// markdownWebBody declares d's web page, rendering the source again when it changed, and beside
// the source scrolls the page to the editor's line when the editor moved.
func (a *App) markdownWebBody(c ui.C, p *project, d *document, s *markdownPreviewState, w *markdownWeb) {
	a.renderMarkdownWeb(p, d, s, w)
	if s.too {
		a.panelMessage(c, i18n.Shared(a.language(), "desktop.markdown.tooLarge"), a.colors.Subtle)
		return
	}
	view := w.entry.view
	if view.Ready() && w.language != a.language() {
		a.markdownWebSetup(w)
	}
	if d.pageMode == pageSplit || s.followOnce {
		s.followEditorWeb(d, w, s.followOnce)
		s.followOnce = false
	}
	a.showPreviewPage(c, w.entry)
}

// renderMarkdownWeb asks Core for the HTML of d's text when it changed since the page was last
// given HTML and no rendering is under way. A file over markdownPreviewMaxBytes is not rendered.
func (a *App) renderMarkdownWeb(p *project, d *document, s *markdownPreviewState, w *markdownWeb) {
	revision := d.view.Revision()
	if revision == w.rendered || w.rendering >= 0 {
		return
	}
	text := d.view.TextSnapshot()
	if s.too = text.Len() > markdownPreviewMaxBytes; s.too {
		w.rendered, w.html = revision, ""
		s.headings = s.headings[:0]
		return
	}
	kernel, ok := a.kernel.(markdownKernel)
	if !ok {
		return
	}
	source := text.String()
	w.rendering = revision
	a.background(p, markdownRenderTimeout, func(ctx context.Context) func(*App) {
		html, err := kernel.RenderMarkdown(ctx, source)
		return func(a *App) {
			if s.web != w {
				return
			}
			w.rendering, w.rendered = -1, revision
			if err != nil {
				// The page keeps the last HTML; the next change renders again.
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("markdown_render", err))
				return
			}
			w.html = html
			w.entry.view.Send(markdownPageRender{Type: "render", Revision: revision, HTML: html})
		}
	})
}

// markdownWebMessage takes in what d's page posted.
func (a *App) markdownWebMessage(p *project, d *document, s *markdownPreviewState, w *markdownWeb, message webpreview.Message) {
	switch message.Type {
	case "ready":
		// A page that loads, or loads again, is given everything it shows.
		a.markdownWebSetup(w)
		if w.html != "" {
			w.entry.view.Send(markdownPageRender{Type: "render", Revision: w.rendered, HTML: w.html})
		}
		if d.pageMode == pageSplit {
			if line, ok := editorSourceLine(d); ok {
				w.line = line
			}
			_, s.editorScroll = d.view.ScrollOffset()
		}
		w.entry.view.Send(markdownPageScroll{Type: "scroll", Line: w.line})
	case "rendered":
		s.headings = s.headings[:0]
		for _, heading := range message.Headings {
			s.headings = append(s.headings, markdownHeading{level: heading.Level, text: heading.Text, start: -1, line: float64(heading.Line)})
		}
	case "scrolled":
		w.line = message.Line
		s.leadEditor(d)
	case "link":
		a.followMarkdownLink(p, d, s, message.Href)
	}
	a.invalidator.Invalidate()
}

// markdownWebSetup gives w's page its strings and the window's look.
func (a *App) markdownWebSetup(w *markdownWeb) {
	language := a.language()
	w.language = language
	w.entry.view.Send(markdownPageSetup{Type: "setup", Theme: a.previewTheme(w.entry), Strings: map[string]string{
		"empty":         i18n.Shared(language, "desktop.markdown.empty"),
		"imagePreview":  i18n.Shared(language, "desktop.markdown.imagePreview"),
		"closeImage":    i18n.Shared(language, "desktop.markdown.closeImage"),
		"mermaidFailed": i18n.Shared(language, "desktop.markdown.mermaidFailed"),
		"markmap":       i18n.Shared(language, "desktop.markdown.markmap"),
		"markmapFailed": i18n.Shared(language, "desktop.markdown.markmapFailed"),
	}})
}

// followEditorWeb scrolls the web page to the source line at the top of the editor when the
// editor moved or force says to, unless the page moved the editor there itself.
func (s *markdownPreviewState) followEditorWeb(d *document, w *markdownWeb, force bool) {
	_, scroll := d.view.ScrollOffset()
	if s.led {
		s.led = false
		s.editorScroll = scroll
		return
	}
	if scroll == s.editorScroll && !force {
		return
	}
	s.editorScroll = scroll
	if line, ok := editorSourceLine(d); ok {
		w.line = line
		w.entry.view.Send(markdownPageScroll{Type: "scroll", Line: line})
	}
}

// editorSourceLine is the source line at the top of d's editor, from 1, with the part of it
// scrolled past as a fraction; past the editor's last row it is the line after the last.
func editorSourceLine(d *document) (float64, bool) {
	v := d.view
	_, scroll := v.ScrollOffset()
	top := v.LineTop(0) + scroll
	line, ok := v.LineAt(top)
	if !ok {
		// Before the editor was painted it has no lines to read.
		if v.LineHeight() > 0 && scroll > 0 {
			return float64(v.TextSnapshot().LineCount() + 1), true
		}
		return 0, false
	}
	from, to := v.LineTop(line), v.LineTop(line+1)
	fraction := float32(0)
	if to > from {
		fraction = min(max((top-from)/(to-from), 0), 1)
	}
	return float64(line) + 1 + float64(fraction), true
}

// editorOffsetForLine is the editor scroll that shows source line (from 1, fractional) at the
// editor's top.
func editorOffsetForLine(d *document, line float64) (float32, bool) {
	v := d.view
	count := v.TextSnapshot().LineCount()
	if v.LineHeight() <= 0 || count == 0 || line < 1 {
		return 0, false
	}
	index, fraction := int(line)-1, float32(line-math.Floor(line))
	if index >= count {
		index, fraction = count-1, 1
	}
	origin := v.LineTop(0)
	from, to := v.LineTop(index)-origin, v.LineTop(index+1)-origin
	return from + (to-from)*fraction, true
}
