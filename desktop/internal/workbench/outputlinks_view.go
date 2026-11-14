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
)

// outputMenu is the context menu of a console's lines, as the old client's output view had:
// copy the line right-clicked, copy the whole output all returns, then the items extra adds.
// The empty space below the lines opens it too, with no line to copy; key names that space.
type outputMenu struct {
	key   string
	all   func() string
	extra func(*ui.MenuItems)
}

// outputLineMenu is the menu of the console line text, or of no line when line is false.
func (a *App) outputLineMenu(c ui.C, text string, line bool, m *outputMenu) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		lang := a.language()
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "menu.copy")).Disabled(!line).Clicked() {
			c.After(func() {
				a.performed("output.copyLine", surfaceMenu)
				_ = app.SetClipboardText(text)
			})
		}
		if menu.Item(i18n.Shared(lang, "git.console.copyOutput")).Clicked() {
			all := m.all()
			c.After(func() {
				a.performed("output.copyAll", surfaceMenu)
				_ = app.SetClipboardText(all)
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

// outputList declares a console's lines from from on as a list that holds only the rows on
// screen. Each line is cut into the ranges Core styled from its escapes and the links Core
// matched, all at UTF-16 offsets, and every piece is drawn in its own colors.
//
// The lines are drawn in the run output's font (fonts.go), each line as tall as that font's
// line spacing makes it. A line right-clicked opens menu, when there is one. The list keeps
// to the newest line as output arrives, until the user scrolls up, and keeps to it again once
// they scroll back down.
func (a *App) outputList(c ui.C, p *project, state *ui.ListState, scope, label string, output *outputBuffer, from int, menu *outputMenu) ui.Box {
	font := a.outputFont()
	lineH := font.lineHeight(c.Canvas())
	ink := a.outputInk()
	from = min(max(from, 0), output.count())
	list := ui.List(c, state, output.count()-from, func(row ui.ListRow) {
		line := output.row(from + row.Index)
		a.outputLine(row, p, scope, line, &ink, font, lineH)
		if menu != nil {
			ui.ContextMenu(row.C, row.Element, a.outputLineMenu(row.C, line.text, true, menu))
		}
	}).Scrollbars().Label(label).FillWidth().Follow(true)
	a.flushOutputLinks(p)
	if menu != nil {
		list = list.Hit(ui.ID(c.Key(menu.key)), label)
		ui.ContextMenu(c, list, a.outputLineMenu(c, "", false, menu))
	}
	return list
}

// outputLine declares one console line in its row.
func (a *App) outputLine(row ui.ListRow, p *project, scope string, line styledLine, ink *outputInk, font scopeFont, lineH float32) {
	c := row.C
	row.Element.PadX(8)
	links := a.outputLinksFor(p, scope, line.text)
	if len(links) == 0 && len(line.spans) == 0 {
		ui.Text(c, line.text).FontSize(font.Size).MonoFace(font.face).LineHeight(lineH).Color(ink.foreground)
		return
	}
	for _, segment := range outputSegments(line, links) {
		a.outputSegment(c, p, segment, ink, font, lineH)
	}
}

// outputSegment declares one piece of a console line in its style. A link is drawn in the
// link color whatever its range's colors, so it reads as one.
func (a *App) outputSegment(c ui.C, p *project, segment outputSegment, ink *outputInk, font scopeFont, lineH float32) {
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
	box := ui.Text(c, segment.text).FontSize(font.Size).MonoFace(font.face).LineHeight(lineH).Color(foreground).Shrink(0)
	if style.Bold {
		box = box.Weight(gfx.WeightBold)
	}
	if filled {
		box = box.Background(background)
	}
	if style.Underline || style.Strikethrough {
		size, underline, strike := font.Size, style.Underline, style.Strikethrough
		box = box.DrawOver(func(d *ui.DrawContext) {
			middle := d.Rect.Y + d.Rect.Height/2
			color := d.Fade(foreground)
			if underline {
				d.Canvas.Fill(gfx.Rect{X: d.Rect.X, Y: middle + size*0.4, Width: d.Rect.Width, Height: 1}, color)
			}
			if strike {
				d.Canvas.Fill(gfx.Rect{X: d.Rect.X, Y: middle + size*0.05 - 0.5, Width: d.Rect.Width, Height: 1}, color)
			}
		})
	}
	if link := segment.link; link != nil {
		box = box.HitWith(ui.ID(c), segment.text, gfx.HitOptions{Role: gfx.RoleLink, Cursor: gfx.PointerCursorHand})
		if box.Clicked() {
			a.openOutputLink(p, *link)
		}
	}
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
