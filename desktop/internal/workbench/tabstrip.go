package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the strip of tabs over an editor group and in the header of the Terminal tool
// window, one component for both. Tabs that do not all fit in one row are laid out the way
// the editor setting asks for:
//
//   - tabsScroll keeps the tabs at their own width in one row that scrolls sideways, with a
//     button at the end that lists the tabs the strip does not show in full. The selected tab
//     is scrolled into view whenever the selection changes.
//   - tabsSqueeze makes the tabs narrower, down to a least width, so more of them fit; past
//     that the row scrolls and lists its hidden tabs as tabsScroll does.
//   - tabsRows wraps the tabs onto as many rows as they need, the strip's buttons at the end
//     of the first row.
//
// The row that scrolls is the only row of a Viva List whose RowWidth is the width of all the
// tabs, so the List scrolls it sideways and keeps the offset. The widths of the tabs are
// measured before they are declared, and the width of the strip is read from the paint
// before, which asks for one more paint when it changes what the strip shows.

// tabLayout is how an editor group's strip lays out tabs that do not fit in one row.
type tabLayout uint8

const (
	tabsScroll tabLayout = iota
	tabsSqueeze
	tabsRows
)

const (
	// tabChrome is the width of a tab besides its title: the padding at both ends, the icon,
	// the close button and the gaps between them. A file's tab that has unsaved changes adds
	// its dot and one more gap.
	tabChrome = 8 + terminalChipIcon + terminalChipGap + terminalChipGap + terminalCloseSize + 2
	// tabHideSlack is how far a tab may poke out of the strip and still count as shown, for
	// the rounding of the layout.
	tabHideSlack = 0.5
)

// tabStrip is what the window remembers about one editor group's strip between paints.
type tabStrip struct {
	// list is the strip's one row, whose sideways scroll is the strip's.
	list ui.ListState
	// width is the width of the strip in the last paint, read by its draw hook.
	width float32
	hook  func(*ui.DrawContext)
	// revealed is the member that was last scrolled into view, so the strip scrolls to the
	// selected tab once when the selection changes and leaves the user's own scrolling alone
	// after that.
	revealed string
	// hidden are the members whose tabs the strip does not show in full, in the group's
	// order; the strip lists them behind its button.
	hidden []string
	// menu says the list of hidden tabs is open.
	menu bool
	// seen says the paint being drawn declared the strip.
	seen bool
	// widths, starts and hiddenScratch are reused by every paint so laying the strip out
	// allocates nothing once they have grown.
	widths        []float32
	starts        []int
	hiddenScratch []string
}

// shownTab is one tab of a group's strip: a terminal's or an open file's.
type shownTab struct {
	term *terminal
	doc  *document
}

// member is the name the group lists the tab's terminal or file under.
func (s shownTab) member() string {
	if s.doc != nil {
		return documentMember(s.doc.id)
	}
	return terminalMember(s.term.id)
}

// tabLayout is the layout the editor setting asks for.
func (a *App) tabLayout() tabLayout {
	switch {
	case a.settings.EditorTabRows == settingswindow.TabRowsMultiple:
		return tabsRows
	case a.settings.EditorTabOverflow == settingswindow.TabOverflowSqueeze:
		return tabsSqueeze
	}
	return tabsScroll
}

// setTabRows and setTabOverflow store a change of the editor's tab setting from the settings
// window. A value the setting does not know stores the default.
func (a *App) setTabRows(value string) {
	if value != settingswindow.TabRowsMultiple {
		value = ""
	}
	if a.settings.EditorTabRows == value {
		return
	}
	a.settings.EditorTabRows = value
	a.tabSettingChanged()
}

func (a *App) setTabOverflow(value string) {
	if value != settingswindow.TabOverflowSqueeze {
		value = ""
	}
	if a.settings.EditorTabOverflow == value {
		return
	}
	a.settings.EditorTabOverflow = value
	a.tabSettingChanged()
}

// tabSettingChanged saves the settings and starts every strip afresh, so the next paint lays
// its tabs out in the new way from the left with the selected tab in view.
func (a *App) tabSettingChanged() {
	for _, s := range a.term.strips {
		s.list.ScrollToX(0)
		s.revealed, s.menu = "", false
	}
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.saveSettings()
}

// stripOf is the remembered state of group's strip, made when the group is first drawn.
func (u *terminalUI) stripOf(group string) *tabStrip {
	if u.strips == nil {
		u.strips = make(map[string]*tabStrip)
	}
	s := u.strips[group]
	if s == nil {
		s = &tabStrip{}
		s.hook = func(d *ui.DrawContext) { s.width = d.Rect.Width }
		s.list.RowHeight = panelHeaderHeight
		u.strips[group] = s
	}
	return s
}

// groupTabs lists the tabs group shows, in its order, and the member that is selected: each
// member whose terminal or file is still open.
func (a *App) groupTabs(group string) ([]shownTab, string) {
	p := a.project
	g := p.terms.bench.Group(group)
	if g == nil {
		return nil, ""
	}
	shown := make([]shownTab, 0, len(g.Members))
	for _, member := range g.Members {
		if id, ok := memberTerminal(member); ok {
			if t := p.terms.find(id); t != nil {
				shown = append(shown, shownTab{term: t})
			}
		} else if id, ok := memberDocument(member); ok {
			if d := p.docs.find(id); d != nil {
				shown = append(shown, shownTab{doc: d})
			}
		}
	}
	return shown, g.Selected
}

// tabWidth is the width a tab takes at its own size: its title and the room around it. A
// terminal's tab is kept between the least and the greatest width of a tab.
func (a *App) tabWidth(canvas *gfx.Canvas, s shownTab) float32 {
	size := a.theme.Metrics.FontSizeM
	if s.doc != nil {
		width := tabChrome + canvas.TextWidth(s.doc.name, size)
		if s.doc.dirty() {
			width += terminalChipGap + documentDirty
		}
		return width
	}
	width := tabChrome + canvas.TextWidth(a.terminalTitle(s.term), size)
	return min(max(width, terminalChipMinWidth), terminalChipMaxWidth)
}

// squeezeTabs narrows the widest tabs, down to the least width of a tab, until the tabs and
// the gaps between them fit in avail or none can give up more.
func squeezeTabs(widths []float32, avail, gap float32) {
	total := float32(0)
	for _, w := range widths {
		total += w
	}
	total += gap * float32(max(len(widths)-1, 0))
	for total > avail {
		widest, most := -1, float32(terminalChipMinWidth)
		for i, w := range widths {
			if w > most {
				widest, most = i, w
			}
		}
		if widest < 0 {
			return
		}
		cut := min(widths[widest]-terminalChipMinWidth, total-avail)
		// Narrowing the widest to the next widest at a time converges in at most one step per
		// tab; a step of the whole excess would make a short tab the widest.
		next := float32(terminalChipMinWidth)
		for i, w := range widths {
			if i != widest && w > next && w < widths[widest] {
				next = w
			}
		}
		cut = min(cut, widths[widest]-next)
		if cut <= 0 {
			cut = min(widths[widest]-terminalChipMinWidth, total-avail)
		}
		widths[widest] -= cut
		total -= cut
	}
}

// tabBar declares the strip of tabs of the group place describes, in the container being
// declared: the tabs, then the strip's own buttons. buttons declares them, and ends the first
// row of the strip. An editor group's tabs fill the strip, so its buttons are at the strip's
// end; the Terminal tool window's take only the room they need, up to what the strip has, and
// its buttons follow them.
func (a *App) tabBar(c ui.C, place *groupPlace, layout tabLayout, buttons func()) {
	u := &a.term
	s := u.stripOf(place.id)
	s.seen = true
	tabs, current := a.groupTabs(place.id)
	canvas := c.Canvas()
	s.widths = s.widths[:0]
	for _, t := range tabs {
		s.widths = append(s.widths, a.tabWidth(canvas, t))
	}
	if layout == tabsRows {
		a.tabRows(c, place, s, tabs, current, buttons)
		return
	}
	if layout == tabsSqueeze && s.width > 0 {
		// The buttons at the end of the strip keep their room; the tabs share the rest.
		squeezeTabs(s.widths, s.width, chromeGap)
	}
	content := float32(0)
	for _, w := range s.widths {
		content += w + chromeGap
	}
	s.list.RowWidth = content
	a.stripReveal(s, current, tabs)
	hiddenNow := a.stripHidden(s, tabs)

	ui.Row(c).Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(chromeGap).Grow(1).Children(func() {
		view := ui.List(c, &s.list, 1, func(row ui.ListRow) {
			row.Element.FillWidth().Height(panelHeaderHeight).Items(ui.Center).Gap(chromeGap).Children(func() {
				for i, t := range tabs {
					a.stripTab(row.C, place, t, current, i, len(tabs), s.widths[i])
				}
			})
		}).Label(a.text.Editor.HiddenTabs).Height(panelHeaderHeight).Shrink(1).MinWidth(0)
		if !place.tool {
			view.Grow(1)
		} else {
			// The tool window's tabs keep their width and give way before the buttons do.
			view.Width(max(content, 1))
		}
		view.Draw(s.hook)
		if hiddenNow {
			a.hiddenTabsButton(c, place, s, tabs, current)
		}
		buttons()
	})
	if !hiddenNow {
		s.menu = false
	}
}

// stripReveal scrolls the selected tab into view once, when the selection changed.
func (a *App) stripReveal(s *tabStrip, current string, tabs []shownTab) {
	if current == s.revealed || s.width <= 0 {
		return
	}
	x := float32(0)
	for i, t := range tabs {
		w := s.widths[i]
		if t.member() == current {
			left, right := x, x+w
			at := s.list.ScrollX()
			switch {
			case left < at:
				s.list.ScrollToX(left)
			case right > at+s.width:
				s.list.ScrollToX(right - s.width)
			}
			break
		}
		x += w + chromeGap
	}
	s.revealed = current
}

// stripHidden works out which tabs the strip does not show in full, from the width and the
// scroll of the last paint, and reports whether there are any. The strip asks for another
// paint when the answer changed, since the button that lists them takes room from the tabs.
func (a *App) stripHidden(s *tabStrip, tabs []shownTab) bool {
	s.hiddenScratch = s.hiddenScratch[:0]
	if s.width > 0 {
		at, x := s.list.ScrollX(), float32(0)
		for i, t := range tabs {
			w := s.widths[i]
			if x < at-tabHideSlack || x+w > at+s.width+tabHideSlack {
				s.hiddenScratch = append(s.hiddenScratch, t.member())
			}
			x += w + chromeGap
		}
	}
	if !slices.Equal(s.hiddenScratch, s.hidden) {
		s.hidden = append(s.hidden[:0], s.hiddenScratch...)
	}
	return len(s.hidden) > 0
}

// tabRows declares the tabs wrapped onto as many rows as they need, the strip's buttons at
// the end of the first row.
func (a *App) tabRows(c ui.C, place *groupPlace, s *tabStrip, tabs []shownTab, current string, buttons func()) {
	s.starts = wrapTabs(s.starts[:0], s.widths, s.width, chromeGap)
	s.hidden = s.hidden[:0]
	s.menu = false
	ui.Row(c).FillWidth().Shrink(0).Items(ui.Start).Children(func() {
		view := ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Clip().Children(func() {
			for r, start := range s.starts {
				end := len(tabs)
				if r+1 < len(s.starts) {
					end = s.starts[r+1]
				}
				ui.Row(c.KeyInt(r)).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(chromeGap).Clip().Children(func() {
					for i := start; i < end; i++ {
						a.stripTab(c, place, tabs[i], current, i, len(tabs), s.widths[i])
					}
				})
			}
		})
		view.Draw(s.hook)
		ui.Row(c).Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(chromeGap).Children(buttons)
	})
}

// stripTab declares tab i of the size tabs of a strip: a terminal's or a file's, width wide.
func (a *App) stripTab(c ui.C, place *groupPlace, t shownTab, current string, i, size int, width float32) {
	member := t.member()
	selected := member == current
	k := c.Key(member)
	chip := ui.Row(k).Width(width).Height(rowHeight).Shrink(0).Items(ui.Center).Gap(terminalChipGap).PadSides(0, 2, 0, 8).
		Radius(a.theme.Metrics.RadiusItem())
	id := ui.ID(k)
	label, icon := "", icons.SquareTerminal
	options := gfx.HitOptions{
		Role: gfx.RoleTab, Cursor: gfx.PointerCursorHand, Selected: selected,
		PosInSet: int32(i + 1), SetSize: int32(size),
	}
	if t.doc != nil {
		label, icon = t.doc.name, fileicons.ForFile(t.doc.name, a.colors.Dark)
	} else {
		label = a.terminalTitle(t.term)
		options.Hint = a.text.Tools.DragHint
	}
	chip = chip.HitWith(id, label, options).Pressed(ui.Look{}.Background(a.colors.Active))
	if selected {
		chip = chip.Background(a.colors.Active)
	} else {
		chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	if t.term != nil {
		u := &a.term
		u.tabIDs = append(u.tabIDs, tabID{id: id, term: t.term.id})
		if a.dnd.tab.Dragging() && a.dnd.tab.Source() == id {
			chip = chip.Opacity(chromeDragDim)
		}
		chip = chip.DragSource(&a.dnd.tab)
		place.chips = append(place.chips, tabSlotDecl{term: t.term.id})
		chip = chip.Draw(place.chipHook(len(place.chips) - 1))
	}
	closeLabel := a.text.Terminal.CloseTab
	if t.doc != nil {
		closeLabel = a.text.Editor.CloseTab
	}
	var closeButton ui.Box
	chip.Children(func() {
		ui.Icon(k, icon).Size(terminalChipIcon, terminalChipIcon).Shrink(0).Color(a.colors.Subtle)
		text := ui.Text(k, label).Ellipsis().Grow(1)
		if selected {
			text.Color(a.colors.Text)
		} else {
			text.Color(a.colors.Subtle).StateFrom(chip).Hover(ui.Look{}.Color(a.colors.Text))
		}
		if t.doc != nil && t.doc.dirty() {
			ui.Row(k).Size(documentDirty, documentDirty).Shrink(0).Radius(documentDirty / 2).Background(a.colors.Accent)
		}
		cc := k.Part("close")
		closeButton = ui.Row(cc).Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
			Radius(a.theme.Metrics.RadiusItem()).
			HitWith(ui.ID(cc), closeLabel, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
		closeButton.Children(func() {
			ui.Icon(cc, icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
				StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
		})
	})
	switch {
	case closeButton.Clicked():
		c.After(func() { a.closeTab(t) })
	case chip.Clicked():
		c.After(func() { a.selectTab(t) })
	}
}

// selectTab shows the tab's terminal or file in its group and gives it the keyboard.
func (a *App) selectTab(t shownTab) {
	if t.doc != nil {
		a.selectDocument(a.project, t.doc.id)
		return
	}
	a.selectTerminal(a.project, t.term.id)
}

// closeTab closes the tab's terminal or file.
func (a *App) closeTab(t shownTab) {
	if t.doc != nil {
		a.closeDocument(a.project, t.doc.id)
		return
	}
	a.closeTerminal(a.project, t.term.id)
}

// hiddenTabsButton declares the button that lists the tabs the strip does not show in full,
// and the menu it opens: a row selects its tab and scrolls it into view.
func (a *App) hiddenTabsButton(c ui.C, place *groupPlace, s *tabStrip, tabs []shownTab, current string) {
	icon := icons.ChevronDown
	if place.tool {
		icon = icons.Ellipsis
	}
	button, clicked := a.toolIconButton(c.Part("more"), a.text.Editor.HiddenTabs, icon, s.menu, false)
	wasOpen := s.menu
	if s.menu {
		ui.Menu(c, button, &s.menu, func(menu *ui.MenuItems) {
			menu.WidthRange(tabMenuWidth, tabMenuWidth)
			for _, member := range s.hidden {
				i := slices.IndexFunc(tabs, func(t shownTab) bool { return t.member() == member })
				if i < 0 {
					continue
				}
				t := tabs[i]
				item := menu.Item(a.tabLabel(t)).Icon(a.tabIcon(t)).Chosen(member == current)
				if item.Clicked() {
					c.After(func() {
						a.selectTab(t)
						s.revealed = ""
					})
				}
			}
		})
	}
	if clicked && !wasOpen {
		a.term.closeStripMenus()
		s.menu = true
	}
}

// tabLabel and tabIcon are the name and the icon of a tab.
func (a *App) tabLabel(t shownTab) string {
	if t.doc != nil {
		return t.doc.name
	}
	return a.terminalTitle(t.term)
}

func (a *App) tabIcon(t shownTab) gfx.Icon {
	if t.doc != nil {
		return fileicons.ForFile(t.doc.name, a.colors.Dark)
	}
	return icons.SquareTerminal
}

// wrapTabs appends to dst where the rows start when tabs of the given widths, gap apart,
// are wrapped at width avail, and returns it: the index of each row's first tab. A row holds
// at least one tab however wide it is, and there is always one row, the first starting at 0.
func wrapTabs(dst []int, widths []float32, avail, gap float32) []int {
	dst = append(dst, 0)
	if avail <= 0 {
		return dst
	}
	row := float32(-1)
	for i, width := range widths {
		if row >= 0 && row+gap+width > avail {
			dst = append(dst, i)
			row = -1
		}
		if row < 0 {
			row = width
		} else {
			row += gap + width
		}
	}
	return dst
}

// closeStripMenus closes the list of hidden tabs of every strip and the Terminal tool
// window's new-terminal menu, and reports whether one was open.
func (u *terminalUI) closeStripMenus() bool {
	closed := u.shells.open
	u.shells.open = false
	for _, s := range u.strips {
		closed = closed || s.menu
		s.menu = false
	}
	return closed
}

// endStripFrame forgets the strip of a group that is gone and the width of one the paint did
// not declare, and readies the mark for the next paint.
func (a *App) endStripFrame() {
	for id, s := range a.term.strips {
		switch {
		case a.project == nil || a.project.terms.bench.Group(id) == nil:
			delete(a.term.strips, id)
		case !s.seen:
			s.width, s.menu, s.revealed = 0, false, ""
		}
		s.seen = false
	}
}
