package workbench

import (
	"sort"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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

// outputLineMenu is the menu of the console line raw, or of no line when line is false.
func (a *App) outputLineMenu(c ui.C, raw string, line bool, m *outputMenu) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		lang := a.language()
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "menu.copy")).Disabled(!line).Clicked() {
			line := strings.TrimRight(raw, "\r\n")
			c.After(func() {
				a.performed("output.copyLine", surfaceMenu)
				_ = app.SetClipboardText(line)
			})
		}
		if menu.Item(i18n.Shared(lang, "git.console.copyOutput")).Clicked() {
			text := m.all()
			c.After(func() {
				a.performed("output.copyAll", surfaceMenu)
				_ = app.SetClipboardText(text)
			})
		}
		if m.extra != nil {
			menu.Separator()
			m.extra(menu)
		}
	}
}

// outputList declares console lines as a list that holds only the rows on screen.
// A line with no link is plain text; one with links is split into text and
// clickable ranges at the UTF-16 offsets Core reported.
//
// The lines are drawn in the run output's font (fonts.go), each line as tall as that font's
// line spacing makes it. A line right-clicked opens menu, when there is one.
func (a *App) outputList(c ui.C, p *project, state *ui.ListState, scope, label string, lines []string, menu *outputMenu) ui.Box {
	font := a.outputFont()
	lineH := font.lineHeight(c.Canvas())
	list := ui.List(c, state, len(lines), func(row ui.ListRow) {
		a.outputLine(row, p, scope, lines[row.Index], font, lineH)
		if menu != nil {
			ui.ContextMenu(row.C, row.Element, a.outputLineMenu(row.C, lines[row.Index], true, menu))
		}
	}).Label(label).FillWidth()
	a.flushOutputLinks(p)
	if menu != nil {
		list = list.Hit(ui.ID(c.Key(menu.key)), label)
		ui.ContextMenu(c, list, a.outputLineMenu(c, "", false, menu))
	}
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
