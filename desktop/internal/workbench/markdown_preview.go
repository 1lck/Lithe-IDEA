package workbench

import (
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// A Markdown file opens as a two-column editor: its source on the left and the rendered page on
// the right, the two scrolled together by source line. The switch at the end of the group's tab
// strip shows the source alone, both, or the page alone, and the page's Contents button lists
// its headings to jump to.
//
// Viva draws Markdown from the source itself (package markdown and components.MarkdownView),
// so the page parses the file's text directly and does not ask Core for HTML (core.Client's
// RenderMarkdown is for the places that need it, such as exports). The text is read from the
// editor, so the page follows edits. A file over markdownPreviewMaxBytes is not rendered:
// parsing and laying out grow with the file and the page redoes both on each change.

const (
	markdownPreviewMaxBytes = 1 << 20
	markdownPadding         = 12
	markdownContentsRow     = 22
	// markdownContentsMax is the most the heading list grows to before it scrolls.
	markdownContentsMax   = 400
	markdownContentsWidth = 280
)

// markdownMode is how the tab of a Markdown file shows it. The zero mode, both side by side, is
// how a file opens.
type markdownMode uint8

const (
	markdownSplit markdownMode = iota
	markdownSource
	markdownPage
)

// markdownModes are the switch's buttons in the order they are shown; markdownModeSwitch names
// them in the same order.
var markdownModes = [...]struct {
	mode markdownMode
	icon gfx.Icon
}{
	{markdownSource, icons.Pencil},
	{markdownSplit, icons.Columns2},
	{markdownPage, icons.FileText},
}

// markdownHeading is one entry of the page's contents.
type markdownHeading struct {
	level int
	text  string
	// start is the byte offset of the heading in the source.
	start int
}

// markdownPreviewState is the rendered page of one Markdown file.
type markdownPreviewState struct {
	// revision is the editor revision the page was parsed from.
	revision int
	// path is the file shown; images are its images, by file or address (markdown_images.go).
	path   string
	images map[string]*markdownImage
	source string
	// lineStarts are the byte offsets of the source's lines, for the scroll that follows them.
	lineStarts []int
	doc        markdown.Document
	view       components.MarkdownView
	headings   []markdownHeading
	// laidWidth and laidRevision say what the view was laid out for.
	laidWidth    float32
	laidRevision int
	// scroll is how far down the page is, in the page's own pixels; height is the page's height
	// and area where it was painted last.
	scroll, height float32
	area           gfx.Rect
	input          ui.Handlers
	draw           func(*ui.DrawContext)
	image          func(string) (gfx.Bitmap, bool)
	contents       ui.ListState
	contentsOpen   bool
	// editorScroll is the editor's scroll the page last followed; led says the page scrolled
	// the editor itself, so the next paint takes the editor's new place as followed, and
	// followOnce that the next paint follows the editor whatever the mode, as the page comes
	// back after the source was shown alone.
	editorScroll float32
	led          bool
	followOnce   bool
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

// markdownState is d's page, made with its handlers the first time it is shown.
func (a *App) markdownState(p *project, d *document) *markdownPreviewState {
	if d.markdown != nil {
		return d.markdown
	}
	s := &markdownPreviewState{revision: -1, laidRevision: -1}
	d.markdown = s
	s.input = ui.Handlers{
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			dy := event.DeltaY
			if !event.Precise {
				dy *= 3
			}
			before := s.scroll
			s.scroll = s.clamp(s.scroll + dy)
			if s.scroll == before {
				return gfx.EventResult{Handled: true}
			}
			s.leadEditor(d)
			return gfx.EventResult{Handled: true, Repaint: true}
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary {
				return gfx.EventResult{}
			}
			// A press on the page makes its group the one the editor commands act on, as a
			// press in the source does.
			p.docs.group = d.group
			index, ok := event.Target.In(s.input.Parts())
			if !ok {
				return gfx.EventResult{Repaint: true}
			}
			destination := s.view.Link(index)
			if destination == "" {
				return gfx.EventResult{Repaint: true}
			}
			a.followMarkdownLink(p, d, s, destination)
			return gfx.EventResult{Handled: true, Repaint: true}
		},
	}
	s.image = func(destination string) (gfx.Bitmap, bool) { return a.markdownImageBitmap(d, s, destination) }
	s.draw = func(dc *ui.DrawContext) { a.paintMarkdown(dc, d, s) }
	return s
}

// sync parses the document's text again when it changed since the last frame.
func (s *markdownPreviewState) sync(d *document) {
	revision := d.view.Revision()
	if s.revision == revision && s.path == d.path {
		return
	}
	if s.path != d.path {
		s.scroll = 0
		s.contents = ui.ListState{}
		s.images = nil
		s.path = d.path
	}
	s.revision = revision
	text := d.view.TextSnapshot()
	s.too = text.Len() > markdownPreviewMaxBytes
	s.headings = s.headings[:0]
	s.lineStarts = s.lineStarts[:0]
	s.laidRevision = -1
	if s.too {
		s.source = ""
		s.doc.Parse("")
		return
	}
	s.source = text.String()
	s.lineStarts = append(s.lineStarts, 0)
	for i := 0; i < len(s.source); i++ {
		if s.source[i] == '\n' {
			s.lineStarts = append(s.lineStarts, i+1)
		}
	}
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

// markdownModeSwitch declares the buttons at the end of the tab strip that show d's source, both
// side by side, or the page.
func (a *App) markdownModeSwitch(c ui.C, d *document) {
	language := a.language()
	labels := [len(markdownModes)]string{
		i18n.Shared(language, "editor.markdownSourceView"),
		i18n.Shared(language, "editor.markdownSplitView"),
		i18n.Shared(language, "editor.markdownPreviewView"),
	}
	for i, entry := range markdownModes {
		label := labels[i]
		on := d.markdownMode == entry.mode
		k := c.Part("md" + strconv.Itoa(int(entry.mode)))
		button := ui.Row(k).Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
			HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleRadio, Checked: on, Cursor: gfx.PointerCursorHand}).
			Pressed(ui.Look{}.Background(a.colors.Active))
		icon := a.colors.Subtle
		if on {
			button = button.Background(a.colors.Active)
			icon = a.colors.Text
		} else {
			button = button.Hover(ui.Look{}.Background(a.colors.Hover))
		}
		button.Tooltip(label).Children(func() {
			ui.Icon(k, entry.icon).Size(shellIconSize, shellIconSize).Color(icon).
				StateFrom(button).Hover(ui.Look{}.Color(a.colors.Text))
		})
		if button.Clicked() && !on {
			from := d.markdownMode
			d.markdownMode = entry.mode
			// The side coming back takes up where the side shown alone was.
			if s := d.markdown; s != nil {
				switch from {
				case markdownSource:
					s.led, s.followOnce = false, true
				case markdownPage:
					s.moveEditor(d)
				}
			}
		}
	}
}

// markdownDocument declares the body of group for Markdown file d in the file's mode: the
// source, the page, or the two in equal halves.
func (a *App) markdownDocument(c ui.C, p *project, group string, d *document) {
	switch d.markdownMode {
	case markdownSource:
		a.documentView(c, group, d)
		return
	case markdownPage:
		d.group = group
		a.markdownPage(c, p, d)
		return
	}
	ui.Row(c).Fill().Children(func() {
		ui.Column(c.Part("source")).Grow(1).Basis(0).FillHeight().Clip().Children(func() {
			a.documentView(c, group, d)
		})
		ui.Row(c).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
		ui.Column(c.Part("page")).Grow(1).Basis(0).FillHeight().Clip().Children(func() {
			a.markdownPage(c, p, d)
		})
	})
}

// markdownPage declares d's rendered page with the Contents button in its top right corner and,
// while it is open, the list of headings under it.
func (a *App) markdownPage(c ui.C, p *project, d *document) {
	language := a.language()
	s := a.markdownState(p, d)
	s.sync(d)
	if s.too {
		a.panelMessage(c, i18n.Shared(language, "desktop.markdown.tooLarge"), a.colors.Subtle)
		return
	}
	title := i18n.Shared(language, "desktop.markdown.contents")
	jump := -1
	ui.Column(c).Fill().Background(a.colors.Editor).Clip().Children(func() {
		ui.Control(c.Part("markdown"+strconv.Itoa(d.id)), i18n.Shared(language, "desktop.markdown.preview"), &s.input).Fill().Draw(s.draw)
		if len(s.headings) == 0 {
			s.contentsOpen = false
			return
		}
		ui.Row(c).Absolute().Top(markdownPadding / 2).Right(markdownPadding).Background(a.colors.Panel).
			Radius(a.theme.Metrics.RadiusItem()).Children(func() {
			button := ui.Button(c.Part("contents"), title).Icon(icons.ListTree).IconOnly().Ghost().
				Size(shellHideSize, shellHideSize).Shrink(0).Tooltip(title)
			if button.Clicked() {
				s.contentsOpen = !s.contentsOpen
			}
			spec := ui.PopoverSpec{Align: ui.End, Width: markdownContentsWidth, ConsumeOutsidePress: true, Title: title}
			ui.PopoverWith(c, button, spec, &s.contentsOpen, func() {
				height := min(float32(len(s.headings))*markdownContentsRow, markdownContentsMax)
				ui.List(c, &s.contents, len(s.headings), func(row ui.ListRow) {
					h := s.headings[row.Index]
					row.Element.FillWidth().Height(markdownContentsRow).PadSides(8+float32(max(h.level-1, 0))*12, 0, 8, 0).Items(ui.Center).
						Radius(a.theme.Metrics.RadiusItem()).Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
						ui.Text(row.C, h.text).FontSize(12.5).Color(a.colors.Text).Ellipsis().Shrink(1)
					})
					if row.Element.Clicked() {
						jump = row.Index
					}
				}).Label(title).FillWidth().Height(height)
				if row, ok := s.contents.Submitted(); ok {
					jump = row
				}
			})
		})
	})
	if jump >= 0 && jump < len(s.headings) {
		s.contentsOpen = false
		s.scrollTo(d, s.headings[jump].start)
	}
}

// paintMarkdown lays the page out for the width it has and draws it scrolled. Beside the source
// it first follows the editor when the editor scrolled or the page was laid out again.
func (a *App) paintMarkdown(dc *ui.DrawContext, d *document, s *markdownPreviewState) {
	s.area = dc.Rect
	width := dc.Rect.Width - 2*markdownPadding
	if width <= 0 {
		return
	}
	relaid := false
	if s.laidRevision != s.revision || s.laidWidth != width {
		// Laid out again for another width, the page keeps the source at its top there.
		keep := -1
		if s.laidRevision == s.revision && s.laidWidth > 0 {
			if offset, ok := s.view.SourceAtY(s.source, s.scroll); ok {
				keep = offset
			}
		}
		style := components.MarkdownStyle{Size: a.theme.Metrics.FontSizeM, LineHeight: 20, Image: s.image}
		s.height = s.view.Layout(dc.Canvas, style, &s.doc, width) + 2*markdownPadding
		s.laidWidth, s.laidRevision = width, s.revision
		relaid = true
		if keep >= 0 {
			if y, ok := s.view.YAtSource(s.source, keep); ok {
				s.scroll = y
			}
		}
	}
	if d.markdownMode == markdownSplit || s.followOnce {
		s.followEditor(d.view, relaid || s.followOnce)
		s.followOnce = false
	}
	s.scroll = s.clamp(s.scroll)
	s.view.Paint(dc.Canvas, components.MarkdownPaint{
		Look: components.MarkdownLookFor(a.theme),
		X:    dc.Rect.X + markdownPadding, Y: dc.Rect.Y + markdownPadding - s.scroll,
		Clip:  dc.Rect,
		Links: s.input.Parts(),
	})
}

// clamp keeps a scroll of the page inside it.
func (s *markdownPreviewState) clamp(y float32) float32 {
	return min(max(y, 0), max(s.height-s.area.Height, 0))
}

// lineStart is the byte offset where source line i starts; past the last line it is the end.
func (s *markdownPreviewState) lineStart(i int) int {
	if i < 0 {
		return 0
	}
	if i >= len(s.lineStarts) {
		return len(s.source)
	}
	return s.lineStarts[i]
}

// scrollTo puts the source offset at the top of the page and, beside the source, scrolls the
// editor to the same line.
func (s *markdownPreviewState) scrollTo(d *document, offset int) {
	if y, ok := s.view.YAtSource(s.source, offset); ok {
		s.scroll = s.clamp(y)
		s.leadEditor(d)
	}
}

// followEditor scrolls the page to the source line at the top of the editor when the editor
// moved or force says to, unless the page moved the editor there itself.
func (s *markdownPreviewState) followEditor(v *editorview.View, force bool) {
	_, scroll := v.ScrollOffset()
	if s.led {
		s.led = false
		s.editorScroll = scroll
		return
	}
	if scroll == s.editorScroll && !force {
		return
	}
	s.editorScroll = scroll
	if y, ok := s.pageOffsetForEditor(v); ok {
		s.scroll = s.clamp(y)
	}
}

// pageOffsetForEditor is the page scroll that shows at its top the source line at the top of the
// editor, as far into the line's rendering as the editor is into the line.
func (s *markdownPreviewState) pageOffsetForEditor(v *editorview.View) (float32, bool) {
	_, scroll := v.ScrollOffset()
	top := v.LineTop(0) + scroll
	line, ok := v.LineAt(top)
	if !ok {
		// Before the editor was painted it has no lines to read; past its last row the page
		// shows its end.
		if v.LineHeight() > 0 && scroll > 0 {
			return s.height, true
		}
		return 0, false
	}
	from, to := v.LineTop(line), v.LineTop(line+1)
	fraction := float32(0)
	if to > from {
		fraction = min(max((top-from)/(to-from), 0), 1)
	}
	y0, ok := s.view.YAtSource(s.source, s.lineStart(line))
	if !ok {
		return 0, false
	}
	y1, ok := s.view.YAtSource(s.source, s.lineStart(line+1))
	if !ok {
		y1 = y0
	}
	return y0 + (y1-y0)*fraction, true
}

// editorOffsetForPage is the editor scroll that shows at its top the source line at the top of
// the page, as far into the line as the page is into its rendering.
func (s *markdownPreviewState) editorOffsetForPage(v *editorview.View) (float32, bool) {
	if v.LineHeight() <= 0 || len(s.lineStarts) == 0 {
		return 0, false
	}
	offset, ok := s.view.SourceAtY(s.source, s.scroll)
	if !ok {
		return 0, false
	}
	line := max(sort.SearchInts(s.lineStarts, offset+1)-1, 0)
	fraction := float32(0)
	y0, ok0 := s.view.YAtSource(s.source, s.lineStart(line))
	y1, ok1 := s.view.YAtSource(s.source, s.lineStart(line+1))
	if ok0 && ok1 && y1 > y0 {
		fraction = min(max((s.scroll-y0)/(y1-y0), 0), 1)
	}
	origin := v.LineTop(0)
	from, to := v.LineTop(line)-origin, v.LineTop(line+1)-origin
	return from + (to-from)*fraction, true
}

// leadEditor scrolls the source beside the page to the line at the page's top.
func (s *markdownPreviewState) leadEditor(d *document) {
	if d.markdownMode == markdownSplit {
		s.moveEditor(d)
	}
}

// moveEditor scrolls d's editor to the source line at the page's top.
func (s *markdownPreviewState) moveEditor(d *document) {
	y, ok := s.editorOffsetForPage(d.view)
	if !ok {
		return
	}
	x, _ := d.view.ScrollOffset()
	d.view.SetScrollOffset(x, y)
	s.led = true
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

// followMarkdownLink opens what a page link points at: an external address in the system
// browser, a file in the editor, or the heading an anchor names.
func (a *App) followMarkdownLink(p *project, d *document, s *markdownPreviewState, destination string) {
	target := markdownLinkTargetOf(d.path, destination)
	switch {
	case target.external != "":
		_ = openURL(target.external)
	case target.anchor != "":
		if index := s.headingIndex(target.anchor); index >= 0 {
			s.scrollTo(d, s.headings[index].start)
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
