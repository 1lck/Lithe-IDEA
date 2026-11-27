package workbench

import (
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
	"github.com/vivaui/viva/ui/textview"
)

// outputMenu is the context menu of a console's lines, as the old client's output view had:
// copy the selection or the line right-clicked, copy the whole output all returns, select
// all, then the items extra adds. The empty space below the lines opens it too. key names
// the console, so each run's keeps its own scroll and focus.
type outputMenu struct {
	key   string
	all   func() string
	extra func(*ui.MenuItems)
}

// outputLineMenu is the menu of a console: Copy takes the selection, or the line
// right-clicked when nothing is selected, and is off below the lines with no selection.
func (a *App) outputLineMenu(c ui.C, view *textview.View, src textview.Source, m *outputMenu) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		lang := a.language()
		menu.WidthRange(180, 260)
		text, action, copyable := view.Text(), "output.copySelection", view.Has()
		if n, ok := view.MenuLine(); !copyable && ok && n >= src.First() && n < src.First()+src.Count() {
			text, action, copyable = src.Line(n), "output.copyLine", true
		}
		if menu.Item(i18n.Shared(lang, "menu.copy")).Disabled(!copyable).Clicked() {
			c.After(func() {
				a.performed(action, surfaceContextMenu)
				_ = app.SetClipboardText(text)
			})
		}
		if menu.Item(i18n.Shared(lang, "git.console.copyOutput")).Clicked() {
			all := m.all()
			c.After(func() {
				a.performed("output.copyAll", surfaceContextMenu)
				_ = app.SetClipboardText(all)
			})
		}
		if menu.Item(i18n.Shared(lang, "menu.selectAll")).Disabled(src.Count() == 0).Clicked() {
			c.After(func() {
				a.performed("output.selectAll", surfaceContextMenu)
				view.SelectAll()
			})
		}
		if m.extra != nil {
			menu.Separator()
			m.extra(menu)
		}
	}
}

// outputInk is what console lines are colored with: the terminal's 16 ANSI colors in the
// current look, so a program's colors match the Terminal window, and the console's own
// text, background and link colors. It is resolved once for each list a frame declares.
type outputInk struct {
	ansi       [16][3]uint8
	foreground gfx.Color
	background gfx.Color
	link       gfx.Color
}

func (a *App) outputInk() outputInk {
	return outputInk{ansi: a.terminalLook().ANSI(), foreground: a.colors.Text, background: a.colors.Ground, link: a.colors.Accent}
}

// color resolves a styled range's color, or reports false for the console's own. Bold text
// in one of the eight base colors takes its bright variant, as the terminal draws it.
func (ink *outputInk) color(color *core.OutputColor, bold bool) (gfx.Color, bool) {
	if color == nil {
		return gfx.Color{}, false
	}
	if color.Index != nil {
		index := *color.Index
		if index < 0 || index > 255 {
			return gfx.Color{}, false
		}
		if bold && index < 8 {
			index += 8
		}
		red, green, blue := term.Resolve(uint8(index), &ink.ansi)
		return rgbColor(red, green, blue), true
	}
	if len(color.RGB) != 7 || color.RGB[0] != '#' {
		return gfx.Color{}, false
	}
	value, err := strconv.ParseUint(color.RGB[1:], 16, 32)
	if err != nil {
		return gfx.Color{}, false
	}
	return rgbColor(uint8(value>>16), uint8(value>>8), uint8(value)), true
}

func rgbColor(red, green, blue uint8) gfx.Color {
	return gfx.Color{Red: float32(red) / 255, Green: float32(green) / 255, Blue: float32(blue) / 255, Alpha: 1}
}

// outputSource is a console's lines from row from on, as a view numbers them: by their
// sequence in the buffer, so a selection keeps to its text while the oldest lines go.
type outputSource struct {
	output *outputBuffer
	from   int
}

func (s outputSource) First() int        { return s.output.start + s.from }
func (s outputSource) Count() int        { return s.output.count() - s.from }
func (s outputSource) Line(n int) string { return s.output.row(n - s.output.start).text }

// outputList declares a console's lines from row from on as read-only text the user selects
// and copies, which draws only the rows on screen. Each line is cut into the ranges Core
// styled from its escapes and the links Core matched, all at UTF-16 offsets, and every piece
// is drawn in its own colors; a click on a link opens it.
//
// The lines are drawn in the run output's font (fonts.go), each line as tall as that font's
// line spacing makes it. A secondary press opens menu, when there is one. The console keeps
// to the newest line as output arrives, until the user scrolls up, and keeps to it again once
// they scroll back down. A line wider than the console breaks onto more rows when wrap is set
// and otherwise scrolls horizontally without cutting it off with an ellipsis.
func (a *App) outputList(c ui.C, p *project, view *textview.View, scope, label string, output *outputBuffer, from int, wrap bool, menu *outputMenu) ui.Box {
	return a.outputListWithScroll(c, p, view, scope, label, output, from, wrap, nil, menu)
}

func (a *App) outputListWithScroll(c ui.C, p *project, view *textview.View, scope, label string, output *outputBuffer, from int, wrap bool, scrollToEnd *bool, menu *outputMenu) ui.Box {
	if menu != nil && menu.key != "" {
		c = c.Key(menu.key)
	}
	font := a.outputFont()
	ink := a.outputInk()
	src := outputSource{output: output, from: min(max(from, 0), output.count())}
	spec := textview.Spec{
		Label:      label,
		Source:     src,
		Font:       font.textStyle(),
		LineHeight: font.lineHeight(c.Canvas()),
		PadX:       8,
		Selection:  a.terminalLook().Selection,
		Scroll:     wrap,
		Follow:     true,
		Wrap:       wrap,
		Ellipsis:   false,
		Revision:   output.revision,
		Spans: func(n int, text string, dst []textview.Span) []textview.Span {
			return a.outputSpans(p, scope, output.row(n-output.start), &ink, dst)
		},
		Open: func(n int, span textview.Span) {
			if link, ok := a.outputLinkAt(p, scope, output.row(n-output.start), span.From); ok {
				a.openOutputLink(p, link)
			}
		},
		Copy: func(text string) {
			a.performed("output.copySelection", surfaceShortcut)
			_ = app.SetClipboardText(text)
		},
	}
	spec.Font.Color = ink.foreground
	if menu != nil {
		spec.Menu = a.outputLineMenu(c, view, src, menu)
	}
	var box ui.Box
	if wrap {
		if scrollToEnd != nil && *scrollToEnd {
			*scrollToEnd = false
			view.ScrollToEnd()
		}
		box = view.Declare(c, spec)
	} else {
		cellW, _ := c.Canvas().MonoCellSize(spec.Font.Size, spec.Font.MonoFace)
		outer := ui.Scroll(c).Sideways().Scrollbars().Follow(true).Label(label)
		state := outer.ScrollState()
		if scrollToEnd != nil && *scrollToEnd {
			*scrollToEnd = false
			state.ScrollToEnd()
		}
		contentW := max(float32(output.widestCells())*cellW+2*spec.PadX+8, state.ViewportWidth)
		outer.Children(func() {
			view.Declare(c.Part("content"), spec).Width(contentW).MinHeight(state.Viewport)
		})
		box = outer
	}
	// The links of the lines on screen are asked for before they are drawn, so the request
	// goes out in this frame; the answer repaints.
	first, last := view.Visible()
	for n := max(first, src.First()); n < min(last, src.First()+src.Count()); n++ {
		a.outputLinksFor(p, scope, src.Line(n))
	}
	a.flushOutputLinks(p)
	return box
}

// outputSpans styles one console line, appending to dst: a span for every piece
// outputSegments cuts it into, at byte offsets.
func (a *App) outputSpans(p *project, scope string, line styledLine, ink *outputInk, dst []textview.Span) []textview.Span {
	links := a.outputLinksFor(p, scope, line.text)
	if len(links) == 0 && len(line.spans) == 0 {
		return dst
	}
	at := 0 // the segments follow each other from the line's start
	for _, segment := range outputSegments(line, links) {
		span := ink.span(segment)
		span.From, span.To = at, at+len(segment.text)
		at = span.To
		dst = append(dst, span)
	}
	return dst
}

// outputLinkAt is the link of a console line at byte at.
func (a *App) outputLinkAt(p *project, scope string, line styledLine, at int) (core.OutputLink, bool) {
	links := a.outputLinksFor(p, scope, line.text)
	offset := 0
	for _, segment := range outputSegments(line, links) {
		end := offset + len(segment.text)
		if segment.link != nil && offset <= at && at < end {
			return *segment.link, true
		}
		offset = end
	}
	return core.OutputLink{}, false
}

// span is the look of one piece of a console line. A link is drawn in the link color
// whatever its range's colors, so it reads as one.
func (ink *outputInk) span(segment outputSegment) textview.Span {
	style := segment.style
	foreground, ok := ink.color(style.Foreground, style.Bold)
	if !ok {
		foreground = ink.foreground
	}
	background, filled := ink.color(style.Background, false)
	if style.Inverse {
		if !filled {
			background = ink.background
		}
		foreground, background, filled = background, foreground, true
	}
	if segment.link != nil {
		foreground = ink.link
	}
	if style.Dim {
		foreground.Alpha *= 0.6
	}
	if style.Hidden {
		foreground.Alpha = 0
	}
	span := textview.Span{
		Color: foreground, Bold: style.Bold, Italic: style.Italic,
		Underline: style.Underline, Strike: style.Strikethrough, Link: segment.link != nil,
	}
	if filled {
		span.Background = background
	}
	return span
}

// outputSegment is a piece of one console line with one style and at most one link.
type outputSegment struct {
	text  string
	style core.OutputStyle
	link  *core.OutputLink
}

// outputSegments cuts line wherever a styled range or a link starts or ends. Ranges and links
// are at UTF-16 offsets; a link that runs past the line or overlaps an earlier one is dropped,
// and an offset inside a character moves to the character's end.
func outputSegments(line styledLine, links []core.OutputLink) []outputSegment {
	length := utf16Length(line.text)
	links = slices.Clone(links)
	slices.SortStableFunc(links, func(x, y core.OutputLink) int { return x.Start - y.Start })
	kept, reached := links[:0], 0
	for _, link := range links {
		if link.Length <= 0 || link.Start < reached || link.Start+link.Length > length {
			continue
		}
		kept = append(kept, link)
		reached = link.Start + link.Length
	}
	cuts := []int{0, length}
	for _, span := range line.spans {
		cuts = append(cuts, span.Start, span.Start+span.Length)
	}
	for _, link := range kept {
		cuts = append(cuts, link.Start, link.Start+link.Length)
	}
	cuts = slices.DeleteFunc(cuts, func(cut int) bool { return cut < 0 || cut > length })
	slices.Sort(cuts)
	cuts = slices.Compact(cuts)
	offsets := utf16ByteOffsets(line.text, cuts)
	segments := make([]outputSegment, 0, len(cuts))
	span, link := 0, 0
	for index := 0; index+1 < len(cuts); index++ {
		text := line.text[offsets[index]:offsets[index+1]]
		if text == "" {
			continue
		}
		start := cuts[index]
		segment := outputSegment{text: text}
		for span < len(line.spans) && line.spans[span].Start+line.spans[span].Length <= start {
			span++
		}
		if span < len(line.spans) && line.spans[span].Start <= start {
			segment.style = line.spans[span].Style
		}
		for link < len(kept) && kept[link].Start+kept[link].Length <= start {
			link++
		}
		if link < len(kept) && kept[link].Start <= start {
			segment.link = &kept[link]
		}
		segments = append(segments, segment)
	}
	return segments
}

// utf16Length is the length of text in UTF-16 code units, the unit Core's offsets count.
func utf16Length(text string) int {
	units := 0
	for _, r := range text {
		units += utf16Units(r)
	}
	return units
}

// utf16ByteOffsets maps ascending UTF-16 offsets into text to byte offsets. An offset inside a
// character maps to that character's end, and one past the text to its length.
func utf16ByteOffsets(text string, cuts []int) []int {
	offsets := make([]int, len(cuts))
	next, units := 0, 0
	for offset, r := range text {
		for next < len(cuts) && cuts[next] <= units {
			offsets[next] = offset
			next++
		}
		units += utf16Units(r)
	}
	for ; next < len(cuts); next++ {
		offsets[next] = len(text)
	}
	return offsets
}

func utf16Units(r rune) int {
	if r >= 0x10000 {
		return 2
	}
	return 1
}
