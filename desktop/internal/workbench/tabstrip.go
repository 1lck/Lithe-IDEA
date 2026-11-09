package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/hscroll"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file lays out the strip of tabs over an editor group when its tabs do not all fit in
// one row, in the way the editor setting asks for:
//
//   - tabsScroll keeps the tabs at their own width in one row that scrolls sideways, with a
//     thin bar along the strip's top that shows where the row is, and a button at the end
//     that lists the tabs the strip does not show in full. The selected tab is scrolled into
//     view whenever the selection changes.
//   - tabsSqueeze makes the tabs narrower, down to a least width, so more of them fit; past
//     that the row scrolls and lists its hidden tabs as tabsScroll does.
//   - tabsRows wraps the tabs onto as many rows as they need, the strip's buttons at the end
//     of the first row.
//
// The width of the strip and of the tabs are only known once a frame is laid out, so
// captureStrips reads them afterwards and asks for another frame when they change what the
// strip shows, as the file tree's sideways scroll does.

// tabLayout is how an editor group's strip lays out tabs that do not fit in one row.
type tabLayout uint8

const (
	tabsScroll tabLayout = iota
	tabsSqueeze
	tabsRows
)

// The identities of the strip's own controls. tabMore.At(n) is the button that lists the
// hidden tabs of the n-th group the frame declares. tabHidden.At(k) is the row of a hidden
// tab in that list and tabHiddenClose.At(k) its close button, k being shownTab.key of the
// tab; tabMenu is the list itself, tabMenuDismiss the backdrop that closes it and
// tabMenuScroll its scroll area.
var (
	tabMore        = tree.Sub(shellPage, tree.Name("editor-tab-more"))
	tabHidden      = tree.Sub(shellPage, tree.Name("editor-tab-hidden"))
	tabHiddenClose = tree.Sub(shellPage, tree.Name("editor-tab-hidden-close"))
	tabMenu        = tree.ID(shellPage, "editor-tab-menu")
	tabMenuDismiss = tree.ID(shellPage, "editor-tab-menu-dismiss")
	tabMenuScroll  = tree.ID(shellPage, "editor-tab-menu-scroll")
)

const (
	// tabWheelStep is the least distance a wheel that turns in steps scrolls a strip.
	tabWheelStep = 64
	// tabChrome is the width of a tab besides its title: the padding at both ends, the icon,
	// the close button and the gaps between them. A file's tab that has unsaved changes adds
	// its dot and one more gap. It must match drawTerminalTab and drawDocumentTab.
	tabChrome = 8 + terminalChipIcon + terminalChipGap + terminalChipGap + terminalCloseSize + 2
	// tabMenuWidth is the width of the list of hidden tabs and tabMenuMaxHeight the most it
	// grows to before it scrolls.
	tabMenuWidth     = 300
	tabMenuMaxHeight = 360
	// tabHideSlack is how far a tab may poke out of the strip and still count as shown, for
	// the rounding of the layout.
	tabHideSlack = 0.5
)

// tabStrip is what the window remembers about one editor group's strip between frames.
type tabStrip struct {
	// scroll is the sideways scroll of the row of tabs. scroll.Area is the part of the strip
	// the tabs are shown in; in tabsRows it is the width the tabs are wrapped at.
	scroll hscroll.State
	// revealed is the member that was last scrolled into view, so the strip scrolls to the
	// selected tab once when the selection changes and leaves the user's own scrolling alone
	// after that.
	revealed string
	// hidden are the members whose tabs the strip does not show in full, in the group's
	// order; the strip lists them behind its button.
	hidden []string
	// menu says the list of hidden tabs is open.
	menu bool
	// seen says the frame being drawn declared the strip.
	seen bool
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

// key is the item of the scopes tabHidden and tabHiddenClose for a tab: the id of its
// terminal or file, with the low bit telling the two apart.
func (s shownTab) key() int {
	if s.doc != nil {
		return s.doc.id<<1 | 1
	}
	return s.term.id << 1
}

// chipDecl is one tab of a strip as the frame declared it, for captureStrips.
type chipDecl struct {
	member string
	box    ui.Box
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

// tabSettingChanged saves the settings and starts every strip afresh, so the next frame lays
// its tabs out in the new way from the left with the selected tab in view.
func (a *App) tabSettingChanged() {
	for _, s := range a.term.strips {
		s.scroll.Offset, s.revealed, s.menu = 0, "", false
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

// drawStripTab declares tab i of the size tabs of a strip and records it in decl: every tab
// for captureStrips, and a terminal's for the drag as well. squeeze lets a file's tab give
// up width, down to the least width of a tab, with its name cut short.
func (a *App) drawStripTab(f *ui.Frame, decl *groupDecl, s shownTab, current string, i, size int, squeeze bool) {
	member := s.member()
	var box ui.Box
	if s.doc != nil {
		box = a.drawDocumentTab(f, s.doc, member == current, i, size, squeeze)
	} else {
		t := a.drawTerminalTab(f, s.term, member == current, i, size)
		decl.tabs = append(decl.tabs, t)
		box = t.box
	}
	decl.chips = append(decl.chips, chipDecl{member: member, box: box})
}

// stripControls are the identities of a strip's own controls, the button that lists its
// hidden tabs and its scrollbar, and the icon of that button.
type stripControls struct {
	more, bar gfx.ID
	moreIcon  gfx.Icon
}

// editorStripControls are the controls of the strip of the index-th editor group the frame
// declares.
func editorStripControls(index int) stripControls {
	return stripControls{more: tabMore.At(index), bar: tabScrollbar.At(index), moreIcon: icons.ChevronDown}
}

// drawGroupStrip declares the strip of tabs of group decl in layout: tabs are the group's
// tabs and, for tabsRows, rows where each row of them starts (see tabRows). It is called
// inside the box of the strip; buttons declares the strip's own buttons, which end its first
// row. An editor group's tabs fill the strip, so its buttons are at the strip's end; the
// Terminal tool window's take only the room they need, up to what the strip has, and its
// buttons follow them.
func (a *App) drawGroupStrip(f *ui.Frame, decl *groupDecl, ids stripControls, tabs []shownTab, layout tabLayout, rows []int, buttons func()) {
	s, current := decl.state, decl.current
	if layout == tabsRows {
		decl.view = f.Column().Fill().Clip()
		decl.view.Children(func() {
			for r, start := range rows {
				end := len(tabs)
				if r+1 < len(rows) {
					end = rows[r+1]
				}
				// A row gives its tabs a little less room when the measured widths were a
				// point short, rather than pushing the last of them out of sight.
				f.Row().FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(chromeGap).Clip().Children(func() {
					for i := start; i < end; i++ {
						a.drawStripTab(f, decl, tabs[i], current, i, len(tabs), true)
					}
				})
			}
		})
		decl.viewSet = true
		f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(chromeGap).Children(buttons)
		return
	}
	squeeze := layout == tabsSqueeze
	decl.view = f.Row().FillHeight().Items(ui.Center).Clip()
	switch {
	case !decl.tool:
		decl.view.FillWidth()
	case s.scroll.Content > 0:
		// The view is as wide as the row of tabs the last frame measured, and gives way
		// when the strip is narrower. Its own content, moved left by the offset, would make
		// it narrower by the offset and keep it from widening again.
		decl.view.Width(s.scroll.Content).Shrink(1).MinWidth(0)
	default:
		decl.view.Shrink(1).MinWidth(0)
	}
	decl.view.Children(func() {
		// The row of tabs is moved left by the offset and clipped to the view. Squeezed, it
		// is as wide as the view was in the last frame, so the tabs give up their width to
		// fit it and moving it does not change what they get.
		decl.content = f.Row().FillHeight().Items(ui.Center).Gap(chromeGap).MarginSides(0, 0, 0, -s.scroll.Offset)
		switch {
		case !squeeze:
			decl.content.Shrink(0)
		case s.scroll.Viewport() > 0:
			decl.content.Width(s.scroll.Viewport()).Shrink(0)
		default:
			decl.content.Grow(1).Shrink(1).MinWidth(0)
		}
		decl.content.Children(func() {
			for i, t := range tabs {
				a.drawStripTab(f, decl, t, current, i, len(tabs), squeeze)
			}
		})
		a.drawSidewaysThumb(f, ids.bar, &s.scroll, true)
	})
	decl.viewSet = true
	f.Row().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(chromeGap).Children(func() {
		if len(s.hidden) > 0 {
			if a.toolIconButton(f, ids.more, a.text.Editor.HiddenTabs, ids.moreIcon, s.menu, false, &decl.more) {
				open := !s.menu
				a.term.closeStripMenus()
				s.menu = open
			}
			decl.moreSet = true
		}
		buttons()
	})
	if !decl.moreSet {
		s.menu = false
	}
	if s.menu {
		a.drawHiddenTabs(f, decl, tabs)
	}
}

// tabRows is where the rows of tabs start when tabs are wrapped at width avail: the index
// of the first tab of each row. Before the strip has been measured it is one row.
func (a *App) tabRows(f *ui.Frame, tabs []shownTab, avail float32) []int {
	u := &a.term
	u.tabWidths = u.tabWidths[:0]
	canvas := f.Canvas()
	if canvas == nil || avail <= 0 {
		u.tabStarts = append(u.tabStarts[:0], 0)
		return u.tabStarts
	}
	size := a.theme.Metrics.FontSizeM
	for _, s := range tabs {
		if s.doc != nil {
			width := tabChrome + canvas.TextWidth(s.doc.name, size)
			if s.doc.dirty() {
				width += terminalChipGap + documentDirty
			}
			u.tabWidths = append(u.tabWidths, width)
			continue
		}
		width := tabChrome + canvas.TextWidth(a.text.Terminal.Tab(s.term.number), size)
		u.tabWidths = append(u.tabWidths, min(max(width, terminalChipMinWidth), terminalChipMaxWidth))
	}
	u.tabStarts = wrapTabs(u.tabStarts[:0], u.tabWidths, avail, chromeGap)
	return u.tabStarts
}

// wrapTabs appends to dst where the rows start when tabs of the given widths, gap apart,
// are wrapped at width avail, and returns it: the index of each row's first tab. A row holds
// at least one tab however wide it is, and there is always one row, the first starting at 0.
func wrapTabs(dst []int, widths []float32, avail, gap float32) []int {
	dst = append(dst, 0)
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

// drawHiddenTabs declares the list of the tabs group decl's strip does not show in full,
// under the strip's button and over a backdrop that closes it. A row selects its tab and
// scrolls it into view; its close button closes the tab and keeps the list open.
func (a *App) drawHiddenTabs(f *ui.Frame, decl *groupDecl, tabs []shownTab) {
	s, u := decl.state, &a.term
	if f.Popup().At(0, 0).Fill().HitWith(tabMenuDismiss, a.text.Errors.Dismiss, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true}).Clicked() {
		s.menu = false
		return
	}
	f.Popup().BelowBox(decl.more, chromeMenuOffset, ui.End).Width(tabMenuWidth).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(gfx.ShadowMD).
		HitWith(tabMenu, a.text.Editor.HiddenTabs, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
		Children(func() {
			f.ScrollArea(tabMenuScroll).FillWidth().MaxHeight(tabMenuMaxHeight).Pad(chromeMenuPadding).Gap(chromeMenuItems).Children(func() {
				for _, member := range s.hidden {
					i := slices.IndexFunc(tabs, func(t shownTab) bool { return t.member() == member })
					if i < 0 {
						continue
					}
					switch a.drawHiddenTab(f, tabs[i], member == decl.current) {
					case hiddenSelect:
						if tabs[i].doc != nil {
							u.actions = append(u.actions, tabAction{kind: actionSelectDocument, term: tabs[i].doc.id})
						} else {
							u.actions = append(u.actions, tabAction{kind: actionSelect, term: tabs[i].term.id})
						}
						s.menu, s.revealed = false, ""
					case hiddenClose:
						if tabs[i].doc != nil {
							u.actions = append(u.actions, tabAction{kind: actionCloseDocument, term: tabs[i].doc.id})
						} else {
							u.actions = append(u.actions, tabAction{kind: actionClose, term: tabs[i].term.id})
						}
					}
				}
			})
		})
}

// hiddenClick is what a click on a row of the list of hidden tabs asks for.
type hiddenClick uint8

const (
	hiddenNone hiddenClick = iota
	hiddenSelect
	hiddenClose
)

// drawHiddenTab declares the row of one hidden tab: its icon, its name and a close button.
// The selected tab's name is in the text color and the others' in the subtle one, as on
// the strip.
func (a *App) drawHiddenTab(f *ui.Frame, t shownTab, selected bool) hiddenClick {
	name, icon := "", icons.SquareTerminal
	if t.doc != nil {
		name, icon = t.doc.name, fileicons.ForFile(t.doc.name, a.colors.Dark)
	} else {
		name = a.text.Terminal.Tab(t.term.number)
	}
	row := a.chromeHover(f.Row().FillWidth().Height(chromeMenuRow).Shrink(0).Items(ui.Center).Gap(chromeMenuGap).
		PadSides(0, 4, 0, chromeEdge).Radius(a.theme.Metrics.RadiusItem()).
		HitWith(tabHidden.At(t.key()), name, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand, Selected: selected}))
	var closeButton ui.Box
	row.Children(func() {
		f.Icon(icon).Size(terminalChipIcon, terminalChipIcon).Shrink(0).Color(a.colors.Subtle)
		label := f.Text(name).Ellipsis().Grow(1).LineHeight(chromeLineHeight)
		if selected {
			label.Color(a.colors.Text)
		} else {
			label.Color(a.colors.Subtle).StateFrom(row).Hover(ui.Look{}.Color(a.colors.Text))
		}
		if t.doc != nil && t.doc.dirty() {
			f.Row().Size(documentDirty, documentDirty).Shrink(0).Radius(documentDirty / 2).Background(a.colors.Accent)
		}
		closeLabel := a.text.Terminal.CloseTab
		if t.doc != nil {
			closeLabel = a.text.Editor.CloseTab
		}
		closeButton = f.Row().Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
			Radius(a.theme.Metrics.RadiusItem()).
			HitWith(tabHiddenClose.At(t.key()), closeLabel, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
		closeButton.Children(func() {
			f.Icon(icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
				StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
		})
	})
	switch {
	case closeButton.Clicked():
		return hiddenClose
	case row.Clicked():
		return hiddenSelect
	}
	return hiddenNone
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

// stripWheel scrolls the strip the wheel event is over. A strip whose tabs fit does not take
// the event.
func (u *terminalUI) stripWheel(event gfx.ScrollEvent) (gfx.EventResult, bool) {
	for _, s := range u.strips {
		if result, ok := s.scroll.Wheel(event, tabWheelStep, true); ok {
			return result, true
		}
	}
	return gfx.EventResult{}, false
}

// captureStrips reads where the frame that was just laid out put the tabs of each editor
// group and of the Terminal tool window (see captureStrip). A strip the frame did not declare
// forgets where it was and closes its list, and the strip of a group that is gone is
// dropped. It reports whether what a strip shows changed, so the caller asks for another
// frame.
func (a *App) captureStrips() bool {
	u := &a.term
	again := false
	rows := a.tabLayout() == tabsRows
	for i := range u.groups {
		again = a.captureStrip(&u.groups[i], rows) || again
	}
	// The tool window's tabs always scroll in one row: the editor's setting is not theirs.
	again = a.captureStrip(&u.tool, false) || again
	for id, s := range u.strips {
		switch {
		case a.project == nil || a.project.terms.bench.Group(id) == nil:
			delete(u.strips, id)
		case !s.seen:
			s.scroll.Area, s.menu, s.revealed = gfx.Rect{}, false, ""
		}
		s.seen = false
	}
	return again
}

// captureStrip reads where the frame put group g's tabs: how wide the row of them is
// against the part of the strip that shows it, which of them it does not show in full, and
// where the selected one is, which is scrolled into view when the selection has changed.
// rows says the tabs were wrapped onto rows. It reports whether what the strip shows changed.
func (a *App) captureStrip(g *groupDecl, rows bool) bool {
	if g.state == nil || !g.viewSet {
		return false
	}
	u, s, again := &a.term, g.state, false
	view := g.view.Rect()
	if rows {
		// The tabs are wrapped at the width of the strip, so there is nothing to scroll; a
		// change of width wraps them again in the next frame.
		again = s.scroll.Fit(view, view.Width)
		if len(s.hidden) > 0 {
			s.hidden, again = s.hidden[:0], true
		}
		return again
	}
	content := g.content.Rect()
	width := float32(0)
	if n := len(g.chips); n > 0 {
		width = g.chips[n-1].box.Rect().Right() - content.X
	}
	again = s.scroll.Fit(view, width)
	u.hiddenScratch = u.hiddenScratch[:0]
	for _, c := range g.chips {
		r := c.box.Rect()
		if r.X < view.X-tabHideSlack || r.Right() > view.Right()+tabHideSlack {
			u.hiddenScratch = append(u.hiddenScratch, c.member)
		}
	}
	if !slices.Equal(u.hiddenScratch, s.hidden) {
		s.hidden = append(s.hidden[:0], u.hiddenScratch...)
		again = true
	}
	if g.current != s.revealed && view.Width > 0 {
		for _, c := range g.chips {
			if c.member == g.current {
				r := c.box.Rect()
				again = s.scroll.Reveal(r.X-content.X, r.Right()-content.X) || again
				break
			}
		}
		s.revealed = g.current
	}
	return again
}
