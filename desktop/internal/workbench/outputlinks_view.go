package workbench

import (
	"sort"
	"strings"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// outputList declares console lines as a list that holds only the rows on screen.
// A line with no link is plain text; one with links is split into text and
// clickable ranges at the UTF-16 offsets Core reported.
//
// The lines are drawn in the run output's font (fonts.go), each line as tall as that font's
// line spacing makes it.
func (a *App) outputList(c ui.C, p *project, state *ui.ListState, scope, label string, lines []string) ui.Box {
	font := a.outputFont()
	lineH := font.lineHeight(c.Canvas())
	list := ui.List(c, state, len(lines), func(row ui.ListRow) {
		a.outputLine(row, p, scope, lines[row.Index], font, lineH)
	}).Label(label).FillWidth()
	a.flushOutputLinks(p)
	return list
}

// outputLine declares one console line in its row.
func (a *App) outputLine(row ui.ListRow, p *project, scope, raw string, font scopeFont, lineH float32) {
	c := row.C
	line := strings.TrimRight(raw, "\r\n")
	text := func(value string) ui.Box {
		return ui.Text(c, value).FontSize(font.Size).MonoFace(font.face).LineHeight(lineH)
	}
	row.Element.PadX(8)
	links := a.outputLinksFor(p, scope, line)
	if len(links) == 0 {
		text(line).Color(a.colors.Text)
		return
	}
	sort.SliceStable(links, func(i, j int) bool { return links[i].Start < links[j].Start })
	position := 0
	for _, link := range links {
		before, linked, ok := splitUTF16(line, position, link.Start, link.Length)
		if !ok {
			continue
		}
		if before != "" {
			text(before).Color(a.colors.Text).Shrink(0)
		}
		box := text(linked).Color(a.colors.Accent).Shrink(0).
			HitWith(ui.ID(c), linked, gfx.HitOptions{Role: gfx.RoleLink, Cursor: gfx.PointerCursorHand})
		if box.Clicked() {
			a.openOutputLink(p, link)
		}
		position = link.Start + link.Length
	}
	if rest := utf16Tail(line, position); rest != "" {
		text(rest).Color(a.colors.Text).Shrink(0)
	}
}
