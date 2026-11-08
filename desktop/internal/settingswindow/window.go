package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// The identities of the window's frame. A control the window paints must have one, and a
// text field must also be listed in config's TextInput.
var (
	tree = ui.Tree{}
	root = tree.Feature("settings")

	searchID      = tree.ID(root, "search")
	sidebarListID = tree.ID(root, "sidebar-list")
	restoreID     = tree.ID(root, "restore-defaults")
	cancelID      = tree.ID(root, "cancel")
	okID          = tree.ID(root, "ok")
	resetLayoutID = tree.ID(root, "reset-layout")

	// rowScope holds the sidebar's rows, one item per pageID, groups included. A page keeps
	// its item whether or not a search is listing it, so the focus stays on the row.
	rowScope = tree.Sub(root, tree.Name("rows"))
	// pageScrollScope holds the scroll area of each page, one item per pageID. The toolkit
	// keeps a scroll offset for every id that is declared and drops it for one that is
	// not, so a page starts at its top each time it is opened.
	pageScrollScope = tree.Sub(root, tree.Name("page-scroll"))
	// themeScope and languageScope are the options of the appearance choice and of the
	// language list.
	themeScope    = tree.Sub(root, tree.Name("theme"))
	languageScope = tree.Sub(root, tree.Name("language"))
)

// The metrics of the window, after the macOS client's settings window and the log window.
const (
	windowWidth, windowHeight = 960, 680
	windowMinWidth            = 760
	windowMinHeight           = 520

	// titleHeight is the height of the title bar, which the system's window buttons sit in.
	titleHeight = 28
	// sidebarWidth is the width of the column of pages.
	sidebarWidth = 240
	// searchHeight is the height of the search field itself and searchIcon the size of the
	// magnifier in front of it.
	searchHeight = 28
	searchIcon   = 16

	// rowHeight is the height of a row of the sidebar. The highlight of a selected row is
	// rowInset in from the sidebar's edges and rowLift short of the row's top and bottom, so
	// the focus ring drawn around it stays inside the row.
	rowHeight = 28
	rowInset  = 8
	rowLift   = 2
	rowRadius = 6
	rowGap    = 8
	// chevronSlot is the room in front of a top-level row for the chevron of a group; the
	// rows that are not groups keep it empty so every tile lines up.
	chevronSlot  = 16
	chevronGlyph = 12
	// tileSize is the rounded square in front of a top-level row, tileGlyph the white glyph
	// in it.
	tileSize   = 18
	tileRadius = 4
	tileGlyph  = 12
	// childIndent is what a row inside a group is indented by, so its title lines up with
	// the title of the group.
	childIndent = chevronSlot + rowGap + tileSize

	// contentPad is the margin of the page at its sides.
	contentPad = 24
	// The cards of a page.
	cardRadius = 8
	cardPad    = 16
	cardGap    = 12
	// selectWidth is the width of the language list.
	selectWidth = 260
	// emptyWidth is the width the sentence of a page that is not available yet wraps at.
	emptyWidth = 360
	// footerHeight is the height of the bar with the buttons.
	footerHeight = 52
	// footerPad is the margin of the bar's buttons at its sides.
	footerPad = 16
)

// window is one open settings window. Everything in it runs on its window thread, but for
// the fields that say so.
type window struct {
	ctrl *Controller
	sess *session

	// win, stopWatch and gone are guarded by ctrl.mu: Controller.Open fills them in from the
	// thread that opened the window, and the window's own thread reads and clears them.
	win       *app.Window
	stopWatch func()
	gone      bool

	inv  app.Invalidator
	view flex.View

	search flex.Field
	// focusSearch asks the next paint to focus the search field (⌘F).
	focusSearch bool
	// language is the state of the language list: whether it is open and the first option
	// it shows.
	language flex.SelectState

	// What the current paint works from.
	text  *i18n.Messages
	dark  bool
	pal   palette
	theme ui.Theme
	// themed says theme has been built and themedDark which look it was built for, so it
	// is built again only when the look changes.
	themed      bool
	themedDark  bool
	query       string
	treeFocused bool

	// rows is the sidebar as listed for rowsFor, rebuilt only when what it depends on has
	// changed.
	rows      []row
	rowsFor   rowsKey
	rowsValid bool
	crumbs    []string

	// The words of the two lists, built for labelsFor.
	themeLabels    []string
	languageLabels []string
	labelsFor      labelsKey
	labelsValid    bool

	// listBox is the scroll area of the sidebar's rows and listRect where it was in the last
	// frame, which the accessibility container of the list is declared with.
	listBox  flex.Box
	listRect ui.Rect
}

// rowsKey is everything the sidebar's rows are computed from.
type rowsKey struct {
	text  *i18n.Messages
	query string
	open  [pageCount]bool
}

// labelsKey is everything the words of the two lists are computed from.
type labelsKey struct {
	text       *i18n.Messages
	systemDark bool
}

// newWindow returns a window whose draft starts from the settings in force.
func newWindow(c *Controller, current Values) *window {
	return &window{ctrl: c, sess: newSession(current)}
}

// config is the native window's configuration.
func (w *window) config() app.Config {
	return app.Config{
		Title:          w.ctrl.text().Settings.Title,
		Width:          windowWidth,
		Height:         windowHeight,
		MinWidth:       windowMinWidth,
		MinHeight:      windowMinHeight,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleHeight,
		Tree:           &tree,
		Paint:          w.paint,
		OnKey:          w.onKey,
		OnShortcut:     w.onShortcut,
		OnScroll:       w.onScroll,
		TextInput:      flex.Fields(&w.search),
		Invalidator:    &w.inv,
		OnClosed:       w.closed,
	}
}

// watchSystem makes the window repaint when the system switches between its light and dark
// looks, because a draft that follows the system is painted in the system's look. A window
// that is already gone is not watched.
func (w *window) watchSystem() {
	stop := app.WatchSystemAppearance(w.inv.Invalidate)
	c := w.ctrl
	c.mu.Lock()
	gone := w.gone
	if !gone {
		w.stopWatch = stop
	}
	c.mu.Unlock()
	if gone && stop != nil {
		stop()
	}
}

// native is the native window, nil until Controller.Open has it.
func (w *window) native() *app.Window {
	w.ctrl.mu.Lock()
	defer w.ctrl.mu.Unlock()
	return w.win
}

// closed runs once the native window is gone, however it was closed: the session is over,
// the system look is no longer watched and the controller forgets the window, so the next
// Open makes a new one.
func (w *window) closed() {
	w.sess.finished.Store(true)
	c := w.ctrl
	c.mu.Lock()
	w.gone = true
	stop := w.stopWatch
	w.stopWatch = nil
	if c.current == w {
		c.current = nil
	}
	c.mu.Unlock()
	if stop != nil {
		stop()
	}
}

// accept is OK: it applies the draft and closes the window. A second OK, such as an Enter
// that arrives with a click, does nothing.
func (w *window) accept() {
	if w.sess.accept(w.ctrl.opts.Apply) {
		w.closeNative()
	}
}

// cancel is Cancel: it closes the window and leaves the settings in force as they were.
func (w *window) cancel() {
	if w.sess.cancel() {
		w.closeNative()
	}
}

// closeNative closes the native window. Closing is safe from inside a paint or a key
// handler, which is where OK and Cancel are chosen.
func (w *window) closeNative() {
	if win := w.native(); win != nil {
		win.Close()
	}
}

// paint draws the window for the draft as it is now.
func (w *window) paint(canvas *ui.Canvas, size ui.Size) {
	w.text = w.ctrl.text()
	w.dark = windowDark(w.sess.draft.Theme, w.ctrl.systemDark())
	w.pal = paletteFor(w.dark)
	if !w.themed || w.themedDark != w.dark {
		w.theme, w.themed, w.themedDark = windowTheme(w.dark, w.pal), true, w.dark
	}
	w.query = foldQuery(w.search.Text())
	w.refreshRows()
	w.refreshLabels()
	if w.sess.page != pageGeneral {
		// The language list lives on the general page. One left open there would go on
		// taking Enter and Escape from the window with nothing on the screen to show why.
		w.language.Open = false
	}

	bounds := ui.Rect{Width: size.Width, Height: size.Height}
	canvas.Fill(bounds, w.pal.window)
	if w.focusSearch {
		w.focusSearch = false
		canvas.RequestFocus(searchID)
	}
	_, w.treeFocused = canvas.Focused().In(rowScope)

	w.view.Draw(canvas, w.theme, bounds, func(f *flex.Frame) {
		// The language list opens over the page, on a layer of its own.
		f.PopupLayer(1)
		f.Column().Fill().Children(func() {
			w.drawTitle(f)
			f.Row().FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
				w.drawSidebar(f)
				f.Row().Width(1).FillHeight().Shrink(0).Background(w.pal.line)
				w.drawContent(f)
			})
			f.Row().FillWidth().Height(1).Shrink(0).Background(w.pal.line)
			w.drawFooter(f)
		})
	})
	w.listRect = w.listBox.Rect()
}

// refreshRows rebuilds the sidebar's rows when the language, the search or the expanded
// groups have changed since they were built.
func (w *window) refreshRows() {
	key := rowsKey{text: w.text, query: w.query, open: w.sess.open}
	if w.rowsValid && key == w.rowsFor {
		return
	}
	w.rows = appendVisible(w.rows[:0], &w.text.Settings, &key.open, w.query)
	w.rowsFor, w.rowsValid = key, true
}

// refreshLabels rebuilds the words of the appearance choice and the language list when the
// language or the system's look has changed since they were built.
func (w *window) refreshLabels() {
	systemDark := w.ctrl.systemDark()
	key := labelsKey{text: w.text, systemDark: systemDark}
	if w.labelsValid && key == w.labelsFor {
		return
	}
	w.themeLabels = themeLabelsFor(&w.text.Settings, systemDark)
	w.languageLabels = languageLabelsFor(&w.text.Settings, w.ctrl.opts.SystemLanguage)
	w.labelsFor, w.labelsValid = key, true
}

// drawTitle is the title bar: the window's name, centered between the system's window
// buttons and the far edge. The whole bar moves the window.
func (w *window) drawTitle(f *flex.Frame) {
	leading, trailing := app.TitlebarInsets()
	f.Stack().FillWidth().Height(titleHeight).Shrink(0).Background(w.pal.titleBar).MovesWindow().Children(func() {
		// The window buttons sit at the leading end, so the title keeps clear of them on that
		// side and is centered in what is left.
		f.Row().Fill().PadSides(0, max(60, trailing+60), 0, max(80, leading+10)).Center().Children(func() {
			f.Text(w.text.Settings.Title).FontSize(13).Weight(ui.WeightSemibold).Color(w.pal.text).Ellipsis()
		})
	})
}

// drawSidebar is the column at the leading side: the search field above the list of pages.
func (w *window) drawSidebar(f *flex.Frame) {
	p := &w.pal
	settings := &w.text.Settings
	f.Column().Width(sidebarWidth).FillHeight().Shrink(0).Background(p.sidebar).Clip().Children(func() {
		// Viva's field paints its own frame, so the magnifier sits beside the frame and not
		// inside it, as in the log window.
		f.Row().FillWidth().Shrink(0).PadSides(10, 12, 8, 12).Gap(8).Items(flex.Center).Children(func() {
			f.Icon(icons.Search).Size(searchIcon, searchIcon).Color(p.muted).Shrink(0)
			f.Field(&w.search, searchID, settings.Search, settings.Search).Grow(1).MinWidth(0).Height(searchHeight)
		})
		// The list's container is declared with the rectangle the list had in the last frame,
		// ahead of the rows, so assistive technology finds the rows inside it. The first frame
		// has no rectangle yet and declares nothing.
		f.Canvas().Container(w.listRect, ui.RoleListBox, settings.Categories)
		w.listBox = f.ScrollArea(sidebarListID).Grow(1).Shrink(1).MinHeight(0).PadSides(2, 0, 8, 0).Children(func() {
			for _, r := range w.rows {
				w.drawRow(f, r)
			}
			if len(w.rows) == 0 {
				f.Row().FillWidth().Shrink(0).PadX(rowInset + 8).PadY(8).Children(func() {
					f.Wrap(settings.NoMatches).FontSize(12).Color(p.muted)
				})
			}
		})
	})
}

// drawRow declares one row of the sidebar. A group expands and collapses; any other row
// opens its page. The hit spans the whole width of the list, as the log window's rows do,
// while the highlight and the content keep the list's inset.
func (w *window) drawRow(f *flex.Frame, r row) {
	p := &w.pal
	title := titleOf(&w.text.Settings, r.page)
	selected := !r.group && r.page == w.sess.page
	options := ui.HitOptions{Role: ui.RoleOption, Selected: selected, Level: r.level + 1}
	if r.group {
		// The toolkit has no tree role, so a group is a button that expands.
		options = ui.HitOptions{Role: ui.RoleButton, Expandable: true, Expanded: r.expanded, Level: r.level + 1}
	}
	outer := f.Row().FillWidth().Height(rowHeight).Shrink(0).HitWith(rowScope.At(int(r.page)), title, options)
	outer.Children(func() {
		// The look of the pointer and of the keyboard focus belongs to the highlight, which
		// follows the hit's state.
		inner := f.Row().Grow(1).MarginSides(rowLift, rowInset, rowLift, rowInset).PadX(8).Gap(rowGap).Items(flex.Center).
			Radius(rowRadius).StateFrom(outer).Focus(flex.Look{}.Ring(2, p.accent))
		if selected {
			inner = inner.Background(p.selectionColor(w.treeFocused))
		} else {
			inner = inner.Hover(flex.Look{}.Background(p.hover))
		}
		inner.Children(func() {
			if r.level > 0 {
				f.Row().Width(childIndent).Shrink(0)
			} else {
				w.drawRowLead(f, r)
			}
			f.Text(title).FontSize(13).Color(p.text).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		})
	})
	if outer.Clicked() {
		if r.group {
			toggleGroup(&w.sess.open, r.page, w.query != "")
		} else {
			w.sess.page = r.page
		}
	}
}

// drawRowLead declares what leads a top-level row: the chevron of a group in its slot, and
// the page's tile.
func (w *window) drawRowLead(f *flex.Frame, r row) {
	p := &w.pal
	f.Row().Size(chevronSlot, tileSize).Shrink(0).Center().Children(func() {
		if !r.group {
			return
		}
		chevron := icons.ChevronRight
		if r.expanded {
			chevron = icons.ChevronDown
		}
		f.Icon(chevron).Size(chevronGlyph, chevronGlyph).Color(p.subtle)
	})
	t := tiles[r.page]
	f.Row().Size(tileSize, tileSize).Shrink(0).Radius(tileRadius).Background(t.color).Center().Children(func() {
		f.Icon(t.icon).Size(tileGlyph, tileGlyph).Color(p.white)
	})
}

// drawContent is the page beside the sidebar: the breadcrumb above the page itself.
func (w *window) drawContent(f *flex.Frame) {
	f.Column().Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
		w.drawBreadcrumb(f)
		if w.sess.page == pageGeneral {
			w.drawGeneral(f)
		} else {
			w.drawUnavailable(f)
		}
	})
}

// drawBreadcrumb names where the open page is: its group, then the page. The last title is
// the page itself and is set apart by its weight; a page on the top level has only that.
func (w *window) drawBreadcrumb(f *flex.Frame) {
	p := &w.pal
	w.crumbs = appendBreadcrumb(w.crumbs[:0], &w.text.Settings, w.sess.page)
	f.Row().FillWidth().Shrink(0).PadSides(16, contentPad, 8, contentPad).Gap(6).Items(flex.Center).Children(func() {
		for i, crumb := range w.crumbs {
			if i > 0 {
				f.Icon(icons.ChevronRight).Size(chevronGlyph, chevronGlyph).Color(p.subtle).Shrink(0)
			}
			if i == len(w.crumbs)-1 {
				f.Text(crumb).FontSize(13).Weight(ui.WeightSemibold).Color(p.text).Ellipsis()
			} else {
				f.Text(crumb).FontSize(13).Color(p.muted).Ellipsis()
			}
		}
	})
}

// drawUnavailable is the body of a page the new desktop client does not offer yet: an icon
// and a sentence in the middle of the page.
func (w *window) drawUnavailable(f *flex.Frame) {
	p := &w.pal
	f.Column().FillWidth().Grow(1).Shrink(1).MinHeight(0).Center().Gap(10).Children(func() {
		f.Icon(icons.Clock).Size(28, 28).Color(p.subtle)
		f.Wrap(w.text.Settings.PageLater).FontSize(13).Color(p.muted).TextCenter().Width(emptyWidth)
	})
}

// drawGeneral is the general page: the cards that edit the draft, then the one that
// reports the version.
func (w *window) drawGeneral(f *flex.Frame) {
	p := &w.pal
	settings := &w.text.Settings
	scroll := pageScrollScope.At(int(pageGeneral))
	f.ScrollArea(scroll).Grow(1).Shrink(1).MinHeight(0).PadSides(4, contentPad, contentPad, contentPad).Gap(cardGap).Children(func() {
		w.card(f, settings.Appearance, settings.AppearanceHelp, func() {
			f.Row().FillWidth().Gap(12).Items(flex.Center).Children(func() {
				f.Text(settings.AppearanceMode).FontSize(12).Color(p.text).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
				choice := f.Choice(themeScope, w.themeLabels, themeIndex(w.sess.draft.Theme)).Label(settings.AppearanceMode)
				if index, ok := choice.ChosenIndex(); ok {
					w.sess.draft.Theme = themeValue(index)
				}
			})
		})
		w.card(f, settings.Language, settings.LanguageHelp, func() {
			f.Row().FillWidth().Items(flex.Center).Children(func() {
				pick := f.Select(languageScope, &w.language, w.languageLabels, languageIndex(w.sess.draft.Language)).
					Width(selectWidth).Label(settings.Language)
				if index, ok := pick.Picked(); ok {
					w.sess.draft.Language = languageCode(index)
				}
			})
		})
		w.card(f, settings.Workbench, settings.LayoutHint, func() {
			f.Row().FillWidth().Items(flex.Center).Children(func() {
				// Putting the layout back is not part of the draft: pressing the button is its
				// own confirmation, so it acts at once.
				if f.Button(resetLayoutID, settings.ResetLayout).Outline().Clicked() && w.ctrl.opts.ResetLayout != nil {
					w.ctrl.opts.ResetLayout()
				}
			})
		})
		w.card(f, settings.About, "", func() {
			f.Column().FillWidth().Gap(2).Children(func() {
				f.Text(w.text.App.Name).FontSize(13).Weight(ui.WeightSemibold).Color(p.text).Ellipsis()
				f.Text(w.text.App.Version(w.ctrl.opts.Version)).FontSize(12).Color(p.muted).Ellipsis()
			})
		})
	})
}

// card declares one card of a page: a title and, when there is one, the sentence that
// explains it, then whatever body declares.
func (w *window) card(f *flex.Frame, title, help string, body func()) {
	p := &w.pal
	f.Column().FillWidth().Shrink(0).MinWidth(0).Pad(cardPad).Gap(cardGap).Radius(cardRadius).
		Background(p.card).Stroke(1, p.line).Children(func() {
		f.Column().FillWidth().Gap(4).Children(func() {
			f.Text(title).FontSize(13).Weight(ui.WeightSemibold).Color(p.text).Ellipsis()
			if help != "" {
				f.Wrap(help).FontSize(12).Color(p.subtle)
			}
		})
		body()
	})
}

// drawFooter is the bar along the bottom: Restore Defaults at the leading end, Cancel and OK
// at the trailing one.
func (w *window) drawFooter(f *flex.Frame) {
	settings := &w.text.Settings
	f.Row().FillWidth().Height(footerHeight).Shrink(0).PadX(footerPad).Gap(8).Items(flex.Center).Children(func() {
		if f.Button(restoreID, settings.RestoreDefaults).Ghost().Clicked() {
			w.sess.restoreDefaults()
		}
		f.Spacer()
		if f.Button(cancelID, settings.Cancel).Outline().Clicked() {
			w.cancel()
		}
		if f.Button(okID, settings.OK).Clicked() {
			w.accept()
		}
	})
}

// ownsEnter says the control with the focus acts on Enter itself, so Enter must not also
// press OK. A page row of the page that is already open is the one exception: Enter there
// would only open the page again, so it means OK, as the default button does in a dialog.
func (w *window) ownsEnter(target ui.ID) bool {
	if target.IsZero() {
		return false
	}
	if index, ok := target.In(rowScope); ok {
		return index != int(w.sess.page)
	}
	return true
}

// onKey gives Enter its meaning of OK and Escape its meaning of Cancel, unless the control
// with the focus needs the key. Whatever it does not handle is left to the toolkit.
func (w *window) onKey(event ui.KeyEvent) ui.EventResult {
	if event.Release {
		return ui.EventResult{}
	}
	// The type-ahead of the language list goes first, as the toolkit asks.
	if result := w.language.Key(event); result.Handled {
		return result
	}
	// Only a plain press of Enter or Escape means OK or Cancel. A held key repeats, and
	// one pressed with a modifier belongs to the platform or to a control.
	if event.Repeat || event.Modifiers != 0 {
		return ui.EventResult{}
	}
	key := keyOther
	switch event.Key {
	case ui.KeyEnter:
		key = keyEnter
	case ui.KeyEscape:
		key = keyEscape
	}
	switch decideKey(key, keyContext{
		selectOpen: w.language.Open,
		searching:  event.Target == searchID,
		queryEmpty: w.search.Text() == "",
		ownsEnter:  w.ownsEnter(event.Target),
	}) {
	case actionAccept:
		w.accept()
	case actionCancel:
		w.cancel()
	case actionClearSearch:
		w.search.SetText("")
	default:
		return ui.EventResult{}
	}
	return ui.EventResult{Handled: true, Repaint: true}
}

// onShortcut handles the window's command shortcuts: ⌘F focuses the search field and ⌘W
// closes the window as Cancel does.
func (w *window) onShortcut(event ui.KeyEvent) ui.EventResult {
	if event.Release || event.Modifiers != ui.ModifierMeta {
		return ui.EventResult{}
	}
	switch event.Text {
	case "f":
		w.focusSearch = true
	case "w":
		w.cancel()
	default:
		return ui.EventResult{}
	}
	return ui.EventResult{Handled: true, Repaint: true}
}

// onScroll scrolls the open language list when there is one, and otherwise the area under
// the pointer.
func (w *window) onScroll(event ui.ScrollEvent) ui.EventResult {
	if result := w.language.Wheel(event); result.Handled {
		return result
	}
	return w.view.Wheel(event)
}
