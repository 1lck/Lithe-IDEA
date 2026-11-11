package workbench

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// The Markdown Preview tool window: the selected Markdown file, rendered, with a table of
// contents made of its headings.
//
// Viva draws Markdown from the source itself (package markdown and components.MarkdownView),
// so the preview parses the file's text directly and does not ask Core for HTML (core.Client's
// RenderMarkdown is for the places that need it, such as exports). The text is read from the
// editor, so the preview follows edits. A file over markdownPreviewMaxBytes is not rendered:
// parsing and laying out grow with the file and the preview redoes both on each change.

const (
	markdownPreviewMaxBytes = 1 << 20
	markdownPadding         = 12
	// markdownContentsHeight is the room of the table of contents above the page.
	markdownContentsHeight = 120
	markdownContentsRow    = 22
)

// markdownHeading is one entry of the table of contents.
type markdownHeading struct {
	level int
	text  string
	// start is the byte offset of the heading in the source.
	start int
}

// markdownPreviewState is the preview's state for the selected document.
type markdownPreviewState struct {
	documentID, revision int
	// path is the file shown; images are its images, by file or address (markdown_images.go).
	path     string
	images   map[string]*markdownImage
	source   string
	doc      markdown.Document
	view     components.MarkdownView
	headings []markdownHeading
	// laidWidth and laidRevision say what the view was laid out for.
	laidWidth    float32
	laidRevision int
	scroll       float32
	height       float32
	contents     ui.ListState
	input        ui.Handlers
	draw         func(*ui.DrawContext)
	area         gfx.Rect
	// too says the file is too large to render.
	too bool
}

// isMarkdownDocument reports whether d is a Markdown file by its language or name.
func isMarkdownDocument(d *document) bool {
	if d == nil || d.virtual {
		return false
	}
	if d.languageID == "markdown" {
		return true
	}
	switch strings.ToLower(filepath.Ext(d.path)) {
	case ".md", ".markdown", ".mdown":
		return true
	}
	return false
}

// syncMarkdownPreview parses the document's text again when it changed since the last frame.
func (a *App) syncMarkdownPreview(d *document) {
	s := &a.editor.markdown
	revision := d.view.Revision()
	if s.documentID == d.id && s.revision == revision {
		return
	}
	if s.documentID != d.id || s.path != d.path {
		s.scroll = 0
		s.contents = ui.ListState{}
		s.images = nil
		s.path = d.path
	}
	s.documentID, s.revision = d.id, revision
	text := d.view.TextSnapshot()
	s.too = text.Len() > markdownPreviewMaxBytes
	s.headings = s.headings[:0]
	s.laidRevision = -1
	if s.too {
		s.source = ""
		s.doc.Parse("")
		return
	}
	s.source = text.String()
	s.doc.Parse(s.source)
	for i := range s.doc.Blocks {
		b := &s.doc.Blocks[i]
		if b.Kind != markdown.Heading {
			continue
		}
		var title strings.Builder
		for _, span := range s.doc.Spans(b) {
			if span.Text != markdown.Newline {
				title.WriteString(span.Text)
			}
		}
		s.headings = append(s.headings, markdownHeading{level: b.Level, text: title.String(), start: b.Start})
	}
}

// markdownPreviewPanel declares the Markdown Preview tool window.
func (a *App) markdownPreviewPanel(c ui.C, p *project) {
	language := a.language()
	d := p.selectedDocument(p.docs.group)
	if !isMarkdownDocument(d) {
		a.panelMessage(c, i18n.Shared(language, "desktop.markdown.noFile"), a.colors.Subtle)
		return
	}
	a.syncMarkdownPreview(d)
	s := &a.editor.markdown
	if s.too {
		a.panelMessage(c, i18n.Shared(language, "desktop.markdown.tooLarge"), a.colors.Subtle)
		return
	}
	if s.draw == nil {
		s.input = ui.Handlers{
			Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
				before := s.scroll
				dy := event.DeltaY
				if !event.Precise {
					dy *= 3
				}
				s.scroll = min(max(s.scroll+dy, 0), max(s.height-s.area.Height, 0))
				return gfx.EventResult{Handled: true, Repaint: s.scroll != before}
			},
			Pointer: func(event gfx.PointerEvent) gfx.EventResult {
				if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary {
					return gfx.EventResult{}
				}
				index, ok := event.Target.In(s.input.Parts())
				if !ok {
					return gfx.EventResult{}
				}
				destination := s.view.Link(index)
				if destination == "" {
					return gfx.EventResult{}
				}
				a.followMarkdownLink(p, d, destination)
				return gfx.EventResult{Handled: true, Repaint: true}
			},
		}
		s.draw = func(dc *ui.DrawContext) { a.paintMarkdown(dc) }
	}
	jump := -1
	ui.Column(c).Fill().Children(func() {
		if len(s.headings) > 0 {
			ui.List(c, &s.contents, len(s.headings), func(row ui.ListRow) {
				h := s.headings[row.Index]
				row.Element.FillWidth().Height(markdownContentsRow).PadSides(8+float32(max(h.level-1, 0))*12, 0, 8, 0).Items(ui.Center).
					Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
					ui.Text(row.C, h.text).FontSize(12.5).Color(a.colors.Text).Ellipsis().Shrink(1)
				})
				if row.Element.Clicked() {
					jump = row.Index
				}
			}).Label(i18n.Shared(language, "desktop.markdown.contents")).FillWidth().Height(markdownContentsHeight).Shrink(0)
			if row, ok := s.contents.Submitted(); ok {
				jump = row
			}
		}
		ui.Control(c.Part("markdown"), i18n.Shared(language, "desktop.markdown.preview"), &s.input).Fill().Background(a.colors.Editor).Clip().Draw(s.draw)
	})
	if jump >= 0 && jump < len(s.headings) {
		if y, ok := s.view.YAtSource(s.source, s.headings[jump].start); ok {
			s.scroll = min(max(y, 0), max(s.height-s.area.Height, 0))
		}
	}
}

// paintMarkdown lays the document out for the width it has and draws it scrolled.
func (a *App) paintMarkdown(dc *ui.DrawContext) {
	s := &a.editor.markdown
	s.area = dc.Rect
	width := dc.Rect.Width - 2*markdownPadding
	if width <= 0 {
		return
	}
	if s.laidRevision != s.revision || s.laidWidth != width {
		style := components.MarkdownStyle{Size: a.theme.Metrics.FontSizeM, LineHeight: 20, Image: a.markdownImageBitmap}
		s.height = s.view.Layout(dc.Canvas, style, &s.doc, width) + 2*markdownPadding
		s.laidWidth, s.laidRevision = width, s.revision
		s.scroll = min(s.scroll, max(s.height-dc.Rect.Height, 0))
	}
	s.view.Paint(dc.Canvas, components.MarkdownPaint{
		Look: components.MarkdownLookFor(a.theme),
		X:    dc.Rect.X + markdownPadding, Y: dc.Rect.Y + markdownPadding - s.scroll,
		Clip:  dc.Rect,
		Links: s.input.Parts(),
	})
}

// markdownLinkTarget is where a Markdown link points: an external address, a file relative to
// the document or an anchor inside it.
type markdownLinkTarget struct {
	external string
	path     string
	anchor   string
}

// markdownLinkTargetOf classifies one destination. A scheme other than http, https or mailto
// is not followed: a preview never launches a local handler from a file's text.
func markdownLinkTargetOf(documentPath, destination string) markdownLinkTarget {
	destination = strings.TrimSpace(destination)
	if destination == "" {
		return markdownLinkTarget{}
	}
	if strings.HasPrefix(destination, "#") {
		return markdownLinkTarget{anchor: strings.TrimPrefix(destination, "#")}
	}
	if parsed, err := url.Parse(destination); err == nil && parsed.Scheme != "" {
		switch strings.ToLower(parsed.Scheme) {
		case "http", "https", "mailto":
			return markdownLinkTarget{external: destination}
		}
		return markdownLinkTarget{}
	}
	path := destination
	if index := strings.IndexAny(path, "?#"); index >= 0 {
		path = path[:index]
	}
	if path == "" {
		return markdownLinkTarget{}
	}
	path = filepath.FromSlash(path)
	if !filepath.IsAbs(path) {
		path = filepath.Join(filepath.Dir(documentPath), path)
	}
	return markdownLinkTarget{path: filepath.Clean(path)}
}

// followMarkdownLink opens what a preview link points at: an external address in the system
// browser, a file in the editor, or the heading an anchor names.
func (a *App) followMarkdownLink(p *project, d *document, destination string) {
	s := &a.editor.markdown
	target := markdownLinkTargetOf(d.path, destination)
	switch {
	case target.external != "":
		_ = openURL(target.external)
	case target.anchor != "":
		if index := s.headingIndex(target.anchor); index >= 0 {
			if y, ok := s.view.YAtSource(s.source, s.headings[index].start); ok {
				s.scroll = min(max(y, 0), max(s.height-s.area.Height, 0))
			}
		}
	case target.path != "":
		info, err := os.Stat(target.path)
		if err != nil || info.IsDir() {
			return
		}
		a.openFileAtPosition(p, target.path, 0, 0)
	}
}

// headingIndex finds the heading an anchor names, matching GitHub's slug of the heading text.
func (s *markdownPreviewState) headingIndex(anchor string) int {
	want := strings.ToLower(strings.TrimSpace(anchor))
	for index, heading := range s.headings {
		slug := strings.ToLower(strings.TrimSpace(heading.text))
		slug = strings.ReplaceAll(slug, " ", "-")
		if slug == want {
			return index
		}
	}
	return -1
}
