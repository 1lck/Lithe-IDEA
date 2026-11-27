package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// searchID is the identity of the sidebar's search field, which the page's own naming does
// not reach: Escape asks whether the focus is in it.
var searchID = gfx.Item(1)

// view declares the whole window: the title bar, the sidebar with the page beside it and
// the footer. It only reads the model, declares what is on screen and writes the values the
// controls were given; what the user did is applied where the control is declared.
func (w *window) view(c ui.C) {
	// The language list and the help open over the page, on a layer of their own.
	ui.PopupLayer(c, 1)
	w.keys(c)
	ui.Column(c).Fill().Children(func() {
		w.title(c)
		ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
			w.sidebar(c)
			ui.Row(c).Width(1).FillHeight().Shrink(0).Background(w.pal.line)
			w.content(c)
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(w.pal.line)
		w.footer(c)
	})
	w.keymapImportDialog(c)
	w.pluginInstallModal(c)
	w.commandInstallModal(c)
	w.declareWork(c)
	w.endRegion()
}

// keys gives Escape its meaning of Cancel, or of emptying the search while the search has
// the text, and Enter its meaning of OK while no control holds the focus. An open list or
// help takes Escape first, as it claims a deeper focus scope; Enter on a control is the
// control's. The platform's Find focuses the search and its Close key closes the window.
// While the Keymap page records a shortcut, every chord is the recording's: none of these
// is declared, and Escape stops the recording.
func (w *window) keys(c ui.C) {
	canvas := c.Canvas()
	escape := ui.ID(c)
	canvas.SetEscapeTarget(escape)
	recording := w.keymap.recording != ""
	if canvas.Clicked(escape) {
		switch decideKey(keyEscape, keyContext{searching: canvas.Focused() == searchID, queryEmpty: w.searchField.Text() == "", recording: recording}) {
		case actionCancel:
			w.cancel()
		case actionClearSearch:
			w.searchField.SetText("")
		case actionEndRecording:
			w.keymap.recording, w.keymap.message = "", ""
		}
	}
	if recording {
		return
	}
	if canvas.Focused().IsZero() && ui.Shortcut(c, 0, "enter") {
		w.accept()
	}
	if ui.Shortcut(c, ui.Primary, "f") {
		w.focusSearch = true
	}
	if ui.Shortcut(c, ui.Primary, "w") {
		w.cancel()
	}
}

// title keeps the native window title beside the system controls.
func (w *window) title(c ui.C) {
	leading, trailing := c.TitlebarInsets()
	ui.Stack(c).FillWidth().Height(titleHeight).Shrink(0).Background(w.pal.titleBar).MovesWindow().Children(func() {
		ui.Row(c).Fill().PadSides(0, max(8, trailing), 0, max(80, leading+10)).Items(ui.Center).Children(func() {
			ui.Text(c, w.text.Settings.Title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
		})
	})
}

// sidebar is the column at the leading side: the search field above the list of pages. A
// page name it cuts short shows in full to its right, over the page beside it.
func (w *window) sidebar(c ui.C) {
	p := &w.pal
	settings := &w.text.Settings
	ui.Column(c).Width(sidebarWidth).FillHeight().Shrink(0).Background(p.sidebar).Clip().
		EllipsisTooltipOn(ui.TooltipRight).Children(func() {
		ui.Row(c).FillWidth().Shrink(0).PadSides(10, 10, 8, 10).Children(func() {
			search := ui.TextField(c, &w.searchField, settings.Search, settings.Search, ui.WithID(searchID)).Icon(icons.Search).FillWidth().Height(searchHeight)
			if w.searchField.Text() != "" {
				search = search.Action(icons.X, i18n.Shared(w.marketLanguage(), "desktop.logs.clearSearch"))
				if search.ActionClicked() {
					w.searchField.SetText("")
				}
			}
			if w.focusSearch {
				w.focusSearch = false
				search.AutoFocus()
			}
		})
		if w.dynamic.failed != nil {
			ui.Wrap(c, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.failed")).FontSize(12).Color(p.danger)
			if ui.Button(c, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.reload")).Outline().Clicked() {
				w.dynamic.invalidate()
				w.rowsValid = false
			}
		}
		if len(w.rows) == 0 {
			// The prototype's empty search: one sentence in the middle of the column's width.
			ui.Row(c).FillWidth().Shrink(0).PadSides(30, 10, 30, 10).Justify(ui.Center).Children(func() {
				ui.Wrap(c, settings.NoMatches).FontSize(buildSmall).Color(w.bp.faint).TextCenter()
			})
			return
		}
		ui.Tree(c, &w.nav, len(w.rows), w.navLabel, func(i int) { w.navContent(c, i) }).Scrollbars().Grow(1).Shrink(1).MinHeight(0).PadSides(12, 12, 0, 12).Label(settings.Categories)
		if i, ok := w.nav.Toggled(); ok && i < len(w.rows) {
			w.toggleRow(w.rows[i])
		}
		if i, ok := w.nav.Chosen(); ok && i < len(w.rows) {
			w.chooseRow(w.rows[i])
		}
	})
}

// chooseRow opens what row r stands for. A group without a page of its own folds; one with a
// page, which Version Control, Build and Languages & Frameworks are and plugins' pages make
// any entry they are under, opens it, and a group that owns its page lists its pages as it opens. A kind's row opens the kind's page. A search ends once its row
// is chosen, with the rows above the page opened so the page's row is on the screen.
func (w *window) chooseRow(r row) {
	if w.chooseSearchRow(r) {
		return
	}
	searching := w.query != ""
	switch {
	case r.kind != "":
		w.openKind(r.kind)
	case r.group && isGroup(r.page) && !ownsPage(r.page) && r.dynamic == "":
		w.toggleRow(r)
		return
	default:
		if ownsPage(r.page) {
			w.sess.open[r.page] = true
		}
		w.selectSettingsPage(r.page, r.dynamic)
	}
	if searching {
		w.revealPage(r)
		w.clearSearch()
	}
}

// revealPage opens every row above the page row r opens.
func (w *window) revealPage(r row) {
	for page := parents[r.page]; page != noPage; page = parents[page] {
		w.sess.open[page] = true
	}
	if r.dynamic != "" {
		w.sess.open[r.page] = true
	}
}

// clearSearch empties the sidebar's search, so it lists every page again.
func (w *window) clearSearch() {
	w.searchField.SetText("")
	w.query = ""
	w.rowsValid = false
}

// toggleRow expands or collapses the group of row r. While searching every group is open.
func (w *window) toggleRow(r row) {
	toggleGroup(&w.sess.open, r.page, r.group, w.query != "")
}

// rowTitle is the words of a sidebar row: a contributed page's own title, else its page's.
func (w *window) rowTitle(r row) string {
	if r.title != "" {
		return r.title
	}
	return titleOf(&w.text.Settings, r.page)
}

// navNode describes row i of the sidebar to its Tree. A search lists its rows flat, under
// the titles of its sections, which are not rows one can choose.
func (w *window) navNode(i int) ui.TreeNode {
	if i < 0 || i >= len(w.rows) {
		return ui.TreeNode{}
	}
	r := w.rows[i]
	if r.special == rowSection {
		return ui.TreeNode{Disabled: true, Height: sectionHeight}
	}
	if w.query != "" {
		return ui.TreeNode{Selected: w.rowSelected(r)}
	}
	return ui.TreeNode{Depth: int(r.level), Branch: r.group, Expanded: r.expanded, Selected: w.rowSelected(r)}
}

// rowSelected says whether row r stands for the page on the screen. A kind's row is chosen
// while its page shows one of its pages, Build's while Build's own page does.
func (w *window) rowSelected(r row) bool {
	switch {
	case r.special != rowPage:
		return false
	case r.kind != "":
		return w.shownKind() == r.kind
	case r.group && isGroup(r.page) && !ownsPage(r.page):
		return false
	}
	return r.page == w.sess.page && r.dynamic == w.dynamicPage
}

// navKey names row i by the page it opens, so a row keeps its focus as the search lists
// other rows around it.
func (w *window) navKey(i int) int {
	if i < 0 || i >= len(w.rows) {
		return i
	}
	return w.rows[i].hitIndex()
}

func (w *window) navLabel(i int) string {
	if i < 0 || i >= len(w.rows) {
		return ""
	}
	return w.rowLabel(w.rows[i])
}

// rowLabel is the words row r reads as: a search's page after where it lives, the row that
// lists what a search leaves out by its count, else the row's title.
func (w *window) rowLabel(r row) string {
	language := w.marketLanguage()
	switch {
	case r.special == rowAllTools:
		return i18n.SharedFormat(language, "desktop.buildSettings.searchAllTools", map[string]string{"count": formatCount(r.overflow)})
	case r.special == rowPage && r.path != "":
		return r.path + " › " + w.rowTitle(r)
	}
	return w.rowTitle(r)
}

// navContent declares what row i holds after its chevron: the page's tile on the top level,
// its title, then what the prototype ends it with: a count of problems, a mark of drafts, a
// kind's count of pages or where a search's match lives.
func (w *window) navContent(c ui.C, i int) {
	if i < 0 || i >= len(w.rows) {
		return
	}
	r := w.rows[i]
	b := &w.bp
	switch {
	case r.special == rowSection:
		ui.Row(c).Grow(1).FillHeight().MinWidth(0).PadSides(10, 0, 3, 0).Items(ui.End).Children(func() {
			ui.Text(c, r.title).FontSize(buildTiny).Weight(gfx.WeightSemibold).Color(b.faint).Ellipsis()
		})
		return
	case r.special == rowAllTools:
		ui.Text(c, w.rowLabel(r)).FontSize(buildSmall).Color(b.accent).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		return
	case w.query != "":
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Items(ui.Center).Children(func() {
			if r.special == rowTool {
				dot(c, 8, b.statusColor(r.status))
			}
			label := w.rowTitle(r)
			if r.special == rowPage {
				label = w.rowLabel(r)
			}
			ui.Text(c, label).FontSize(13).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
			if r.special != rowPage && r.path != "" {
				ui.Spacer(c)
				ui.Text(c, r.path).FontSize(buildTiny).Color(b.faint).PadLeft(6).Shrink(1).MinWidth(0).Ellipsis()
			}
		})
		return
	}
	title := func() {
		ui.Text(c, w.rowTitle(r)).FontSize(13).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
		ui.Spacer(c)
		w.navTrailing(c, r)
	}
	if r.level != 0 {
		pad := childIndent - float32(r.level)*levelIndent
		if r.group {
			pad -= chevronSlot
		}
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).PadLeft(pad).Gap(6).Items(ui.Center).Children(title)
		return
	}
	// The tile and the title are in a row of their own, which spaces them by tileGap rather
	// than by the gap of the Tree's row, so childIndent can name where the title starts. A
	// page that is not a group keeps the room of the chevron, so every tile lines up.
	var lead float32
	if !r.group {
		lead = chevronSlot
	}
	t := tiles[r.page]
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).PadLeft(lead).Gap(tileGap).Items(ui.Center).Children(func() {
		ui.Row(c).Size(tileSize, tileSize).Shrink(0).Radius(tileRadius).Background(t.color).Center().Children(func() {
			ui.Icon(c, t.icon).Size(tileGlyph, tileGlyph).Color(w.pal.white)
		})
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Items(ui.Center).Children(title)
	})
}

// navTrailing ends a row as the prototype does: Build folded and the Toolchains page count the
// tools with a problem, the Debuggers, Trusted Locations and Remote Workspace pages mark drafts and
// a kind counts its pages.
func (w *window) navTrailing(c ui.C, r row) {
	if r.dynamic != "" {
		return
	}
	switch {
	case r.kind != "":
		ui.Text(c, formatCount(r.count)).FontSize(buildTiny).Color(w.bp.faint).Shrink(0)
	case r.page == pageBuild && !r.expanded, r.page == pageToolchains:
		if problems := w.toolchainProblems(); problems > 0 {
			w.badge(c, problems, false)
		}
	case r.page == pageDebuggers:
		if len(w.steppingPending()) > 0 {
			dot(c, 7, w.bp.accent)
		}
	case r.page == pageTrustedLocations:
		if w.toolchains.locations.drafts() > 0 || w.toolchains.remote.drafts() > 0 {
			dot(c, 7, w.bp.accent)
		}
	case r.page == pageRemoteWorkspace:
		if w.toolchains.prefs.drafts() > 0 {
			dot(c, 7, w.bp.accent)
		}
	}
}

// toolchainProblems is how many tools of the scope the Toolchains page shows have a problem,
// once Core projected the list.
func (w *window) toolchainProblems() int {
	if t := w.toolchains; t.available() && t.view.ready {
		return t.view.view.Counts.Problems
	}
	return 0
}

// content is the page beside the sidebar: the breadcrumb above the page itself.
func (w *window) content(c ui.C) {
	if w.sess.page != pagePlugins {
		w.marketIcons.reset(0)
	}
	if w.sess.page != pagePlugins && w.market.status == marketLoading {
		// Leaving the page stops wanting the fetch, which cancels it. A background refresh
		// goes on: its result replaces plugins the page already shows.
		w.market.close()
	}
	if w.sess.page != pagePlugins && w.marketShown {
		w.marketShown, w.marketRecheck = false, true
	}
	if w.sess.page != pageAbout {
		w.about = aboutState{}
	}
	ui.Column(c).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
		if w.sess.page == pagePlugins && w.ctrl.opts.Marketplace != nil {
			w.marketplacePage(c)
			return
		}
		w.breadcrumb(c)
		if kind := w.shownKind(); kind != "" {
			w.buildKindPage(c.Part("kind"), kind)
			return
		}
		if w.dynamicPage != "" {
			w.dynamicSettingsPage(c)
			return
		}
		switch {
		case w.sess.page == pageGeneral:
			w.generalPage(c)
		case w.sess.page == pageEditor:
			w.editorPage(c)
		case w.sess.page == pageFonts:
			w.fontsPage(c)
		case w.sess.page == pageBuild:
			w.buildPage(c.Part("build"))
		case w.sess.page == pageLanguages:
			w.languagesPage(c.Part("languages"))
		case w.sess.page == pageToolchains:
			w.toolchainsPage(c)
		case w.sess.page == pageDebuggers:
			w.debuggersPage(c)
		case w.sess.page == pageConsole:
			w.consolePage(c)
		case w.sess.page == pageTrustedLocations && (w.toolchains.locations.available() || w.toolchains.remote.available()):
			w.trustedLocationsPage(c)
		case w.sess.page == pageRemoteWorkspace && w.toolchains.prefs.available():
			w.remoteWorkspacePage(c)
		case w.sess.page == pageTerminal && w.ctrl.opts.TerminalShells != nil:
			w.terminalPage(c)
		case w.sess.page == pageSearch:
			w.searchPage(c)
		case w.sess.page == pageAIGeneration:
			w.generationPage(c)
		case w.sess.page == pageVersionControl:
			w.versionControlPage(c.Part("versionControl"))
		case w.sess.page == pageGit:
			w.gitPage(c)
		case w.sess.page == pageNetwork && w.ctrl.opts.SetNetwork != nil:
			w.networkPage(c)
		case w.sess.page == pageKeymap:
			w.keymapPage(c)
		case w.sess.page == pageProcessTermination:
			w.processTerminationPage(c)
		case w.sess.page == pageIDEAPI && w.ctrl.opts.IDEAPI != nil:
			w.ideAPIPage(c)
		case w.sess.page == pageAbout:
			w.aboutPage(c)
		default:
			w.unavailablePage(c)
		}
	})
}

// breadcrumb is the prototype's .crumb: where the open page is, its group first and the page
// last in the weight of the text. A title before the last that has a page of its own opens it:
// Build, Execution, Deployment and Languages & Frameworks their directories.
func (w *window) breadcrumb(c ui.C) {
	b := &w.bp
	w.crumbs = w.appendCrumbs(w.crumbs[:0])
	var chosen *crumb
	ui.Row(c).FillWidth().Height(crumbHeight).Shrink(0).PadX(18).Gap(8).Items(ui.Center).Background(b.surface).Children(func() {
		// Keys belong on interactive containers, not leaf Text elements.
		for i := range w.crumbs {
			crumb := &w.crumbs[i]
			if i > 0 {
				ui.Text(c, "›").FontSize(buildFont).Color(b.faint).Shrink(0)
			}
			last := i == len(w.crumbs)-1
			switch {
			case last:
				ui.Text(c, crumb.title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Shrink(1).MinWidth(0).Ellipsis()
			case crumb.link:
				button := ui.ButtonBase(c.KeyInt(i), crumb.title).Shrink(1).MinWidth(0).Items(ui.Center)
				if button.Clicked() {
					chosen = crumb
				}
				button.Children(func() {
					ui.Text(c, crumb.title).FontSize(buildFont).Color(b.sub).Shrink(1).MinWidth(0).Ellipsis().
						StateFrom(button).Hover(ui.Look{}.Color(b.accent))
				})
			default:
				ui.Text(c, crumb.title).FontSize(buildFont).Color(b.sub).Shrink(1).MinWidth(0).Ellipsis()
			}
		}
	})
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
	if chosen != nil {
		w.chooseCrumb(*chosen)
	}
}

// appendCrumbs appends the titles that lead to the open page to dst: the page's group and the
// page. A plugin's page under Build, Execution, Deployment shows on its kind's page, which the
// breadcrumb names as the Toolchains and Debuggers pages are named; one under another entry
// is named after it.
func (w *window) appendCrumbs(dst []crumb) []crumb {
	dst = appendBreadcrumb(dst, &w.text.Settings, w.sess.page)
	parent := &dst[len(dst)-1]
	if w.dynamicPage == "" {
		return dst
	}
	page := w.dynamic.selected(w.dynamicPage)
	if page == nil {
		return dst
	}
	parent.link = ownsPage(parent.page)
	title := page.Title
	if kind := w.shownKind(); kind != "" {
		title = kindTitle(w.marketLanguage(), kind)
	}
	return append(dst, crumb{title: title, page: w.sess.page})
}

// chooseCrumb opens the page a title of the breadcrumb stands for.
func (w *window) chooseCrumb(crumb crumb) {
	if ownsPage(crumb.page) {
		w.sess.open[crumb.page] = true
	}
	w.selectSettingsPage(crumb.page, "")
}

// unavailablePage is the body of a page the new desktop client does not offer yet: an icon
// and a sentence in the middle of the page.
func (w *window) unavailablePage(c ui.C) {
	p := &w.pal
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Center().Gap(10).Children(func() {
		ui.Icon(c, icons.Clock).Size(28, 28).Color(p.subtle)
		ui.Wrap(c, w.text.Settings.PageLater).FontSize(13).Color(p.muted).TextCenter().Width(emptyWidth)
	})
}

// pageScroll is the scroll area of one page. It is named by the page, so it starts at its
// top each time the page is opened.
func (w *window) pageScroll(c ui.C, page pageID, body func()) {
	ui.Scroll(c.KeyInt(int(page))).Scrollbars().Grow(1).Shrink(1).MinHeight(0).PadSides(20, contentPad, 36, contentPad).Gap(cardGap).Children(body)
}

// card puts the section label outside its bounded settings rows, as in the native client.
func (w *window) card(c ui.C, title, help string, body func()) {
	p := &w.pal
	ui.Column(c).FillWidth().Shrink(0).MinWidth(0).Gap(6).Children(func() {
		ui.Row(c).FillWidth().PadX(6).Gap(6).Items(ui.Center).Children(func() {
			ui.Text(c, title).FontSize(12).Weight(gfx.WeightSemibold).Color(p.muted).Ellipsis()
			if help != "" {
				w.infoButton(c, help)
			}
		})
		ui.Column(c).FillWidth().Shrink(0).MinWidth(0).PadX(cardPad).PadY(7).Radius(cardRadius).
			Background(p.card).Stroke(0.5, p.line).Children(body)
	})
}

// settingsRow keeps compact forms on the same label/control columns in every page.
func (w *window) settingsRow(c ui.C, title, help string, body func()) {
	ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
		ui.Row(c).WidthPercent(40).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, title).FontSize(12).Color(w.pal.text).Ellipsis().Shrink(1)
			if help != "" {
				w.infoButton(c, help)
			}
		})
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(body)
	})
}

// infoButton is the information glyph. Resting the pointer on it shows help in the client's
// shared tip, as every ⓘ in the workbench does; pressing it opens nothing else, so the help
// never turns into a second, differently drawn card. The tip opens to the right of the
// glyph, beside the label it ends, so it covers neither the label nor the rows under it;
// without room there it opens on the left. Assistive technology reads the help as the
// glyph's description.
func (w *window) infoButton(c ui.C, help string) {
	ui.Row(c).Size(18, 18).Shrink(0).Center().Children(func() {
		ui.Button(c, i18n.Shared(w.marketLanguage(), "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).
			Tooltip(help).TooltipOn(ui.TooltipRight)
	})
}

// radio is one option of a radio group: a circle, filled with a dot when the option is
// chosen, in front of its words. A click writes option into *value. A disabled option is
// dimmed and ignores clicks. It reports whether this paint delivers a click that chose it.
func (w *window) radio(c ui.C, value *string, option, label string, disabled bool) bool {
	p := &w.pal
	chosen := *value == option
	words, ring, dot := p.text, p.border, p.accent
	if chosen {
		ring = p.accent
	}
	if disabled {
		words, ring, dot = p.subtle, p.subtle, p.subtle
	}
	body := func() {
		ui.Row(c).Size(radioSize, radioSize).Shrink(0).Radius(radioSize/2).Stroke(1, ring).Center().Children(func() {
			if chosen {
				ui.Row(c).Size(radioDot, radioDot).Shrink(0).Radius(radioDot / 2).Background(dot)
			}
		})
		ui.Text(c, label).FontSize(12).Color(words).Ellipsis()
	}
	if disabled {
		// A disabled option is still a radio button for assistive technology, which says
		// it cannot be used.
		inert := ui.Row(c).FillWidth().Height(radioHeight).Gap(8).Items(ui.Center).Justify(ui.Start).Radius(4).Opacity(0.45).
			HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleRadio, Value: label, Checked: chosen, Selected: chosen, Disabled: true})
		inert.Children(body)
		return false
	}
	choice := ui.RadioBase(c, value, option, label).FillWidth().Height(radioHeight).Gap(8).Items(ui.Center).Justify(ui.Start).Radius(4)
	choice.Children(body)
	return choice.Changed()
}

// generalPage is the general page: the cards that edit the look, the language and how
// projects open and save. The version is on the About page.
func (w *window) generalPage(c ui.C) {
	p := &w.pal
	settings := &w.text.Settings
	w.themePick = w.sess.values.Theme
	w.languagePick = languageCode(languageIndex(w.sess.values.Language))
	w.pageScroll(c, pageGeneral, func() {
		w.cliCard(c)
		w.associationsCard(c)
		w.card(c, settings.Appearance, settings.AppearanceHelp, func() {
			choice := func() {
				ui.Choice(c, &w.themePick, themeValues[:], w.themeLabel).Width(420).Shrink(1).MinWidth(0)
			}
			narrow := w.extent-2*contentPad-2*cardPad < 460
			if narrow {
				ui.Column(c).FillWidth().Gap(8).Children(func() {
					ui.Text(c, settings.AppearanceMode).FontSize(12).Color(p.text)
					choice()
				})
			} else {
				ui.Row(c).FillWidth().Height(28).Gap(12).Items(ui.Center).Children(func() {
					ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
						ui.Text(c, settings.AppearanceMode).FontSize(12).Color(p.text).Ellipsis()
					})
					choice()
				})
			}
			w.workbenchBackgroundRows(c, narrow)
		})
		w.card(c, settings.Language, "", func() {
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
				ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(func() {
					ui.Text(c, settings.Language).FontSize(12).Color(p.text)
					w.infoButton(c, settings.LanguageHelp)
				})
				ui.Select(c, &w.languagePick, w.languageCodes, w.languageLabel).Width(selectWidth).Label(settings.Language)
			})
		})
		w.card(c, settings.Workbench, settings.LayoutHint, func() {
			language := w.marketLanguage()
			colors := !w.sess.values.HideProjectColors
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(6).Children(func() {
				if ui.Switch(c.Part("project-colors"), &colors, i18n.Shared(language, "desktop.settings.projectColors")).Changed() {
					w.sess.values.HideProjectColors = !colors
					if w.ctrl.opts.SetHideProjectColors != nil {
						w.ctrl.opts.SetHideProjectColors(!colors)
					}
				}
				w.infoButton(c, i18n.Shared(language, "desktop.settings.projectColorsHelp"))
			})
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
				label := i18n.Shared(language, "desktop.settings.projectOpen")
				ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
					ui.Text(c, label).FontSize(12).Color(p.text).Ellipsis()
				})
				// The control writes into the window's own copy, like the language choice.
				w.projectOpenPick = w.sess.values.ProjectOpenDestination
				ui.Select(c.Part("project-open"), &w.projectOpenPick, projectOpenDestinations, func(value string) string {
					return projectOpenLabel(language, value)
				}).Width(selectWidth).Label(label)
				if destination := w.projectOpenPick; destination != w.sess.values.ProjectOpenDestination {
					w.sess.values.ProjectOpenDestination = destination
					if w.ctrl.opts.SetProjectOpenDestination != nil {
						w.ctrl.opts.SetProjectOpenDestination(destination)
					}
				}
			})
			ui.Row(c).FillWidth().Items(ui.Center).Children(func() {
				// Pressing the button is its own confirmation, so it acts at once.
				if ui.Button(c, settings.ResetLayout).Outline().Clicked() && w.ctrl.opts.ResetLayout != nil {
					w.ctrl.opts.ResetLayout()
				}
			})
		})
		w.autoSaveCard(c)
		if w.ctrl.opts.SetLocalHistory != nil {
			w.localHistoryCard(c)
		}
	})
	// A control wrote into a copy of the value: only what changed is told to the owner.
	if w.themePick != w.sess.values.Theme {
		w.setTheme(w.themePick, false)
	}
	if w.languagePick != languageCode(languageIndex(w.sess.values.Language)) {
		w.setLanguage(w.languagePick, false)
	}
}

// themeLabel and languageLabel are the words of a theme value and of a language code.
func (w *window) themeLabel(value string) string {
	return w.themeLabels[themeIndex(value)]
}

func (w *window) languageLabel(code string) string {
	return w.languageLabels[languageIndex(code)]
}

// editorPage is the editor page. Its card says where an editor group's tabs go when they
// do not all fit, as the IDE's setting does: one row that scrolls, one row whose tabs are
// squeezed, or as many rows as they need. One shared selector presents the three layouts;
// choosing several rows retains the user's last overflow setting.
func (w *window) editorPage(c ui.C) {
	settings := &w.text.Settings
	values := &w.sess.values
	w.tabRowsPick, w.tabOverflowPick = values.EditorTabRows, values.EditorTabOverflow
	w.pageScroll(c, pageEditor, func() {
		w.card(c, settings.EditorTabs, settings.EditorTabsHelp, func() {
			type placement struct{ rows, overflow string }
			pick := placement{w.tabRowsPick, w.tabOverflowPick}
			options := []placement{{"", ""}, {"", TabOverflowSqueeze}, {TabRowsMultiple, w.tabOverflowPick}}
			label := func(option placement) string {
				if option.rows == TabRowsMultiple {
					return settings.TabsMultipleRows
				}
				if option.overflow == TabOverflowSqueeze {
					return settings.TabsSqueeze
				}
				return settings.TabsScroll
			}
			w.settingsRow(c, settings.TabsShowIn, "", func() {
				if ui.Select(c.Part("tab-layout"), &pick, options, label).Width(selectWidth).Label(settings.TabsShowIn).Changed() {
					w.tabRowsPick, w.tabOverflowPick = pick.rows, pick.overflow
				}
			})
		})
		w.editorPresentationCard(c)
		w.editorRainbowCard(c.Part("rainbow-settings"))
		w.tabLimitCard(c)
		semantic := !values.DisableSemanticHighlight
		w.card(c, settings.EditorSemantic, settings.EditorSemanticHelp, func() {
			if ui.Switch(c.Part("semantic"), &semantic, settings.SemanticHighlight).Changed() {
				w.setDisableSemanticHighlight(!semantic, false)
			}
		})
		w.vimCard(c)
	})
	if w.tabRowsPick != values.EditorTabRows {
		w.setTabRows(w.tabRowsPick, false)
	}
	if w.tabOverflowPick != values.EditorTabOverflow {
		w.setTabOverflow(w.tabOverflowPick, false)
	}
}

// footer is the bar along the bottom, after docs/design/build-execution-settings.html:
// Restore Defaults at the leading end, then what Apply would write, then Cancel, Apply and OK.
func (w *window) footer(c ui.C) {
	settings := &w.text.Settings
	language := w.marketLanguage()
	applying := w.apply.active()
	count, targets := w.buildDrafts(language)
	ui.Row(c).FillWidth().Height(footerHeight).Shrink(0).Background(w.bp.surface).PadX(footerPad).Gap(8).Items(ui.Center).Children(func() {
		if w.button(c.Part("restore"), buttonPlain, settings.RestoreDefaults, applying) {
			// Reset is explicit even when an unknown stored value is displayed as the
			// system default. Forward it so the owner's real setting is cleared.
			w.setLanguage("", true)
			w.setTheme("", true)
			w.setTabRows("", true)
			w.setTabOverflow("", true)
			w.setDisableSemanticHighlight(false, true)
			w.setDisableAutoCompletion(false)
			w.setVimMode(false, true)
			w.resetEditorPresentation()
			w.setProcessTermination(ProcessTermination{}, true)
			w.setConsoleEncoding("", true)
			w.resetSteppingFilters()
			w.setTerminalShell("", true)
			w.setTerminalBehavior(TerminalBehavior{}, true)
			w.setTerminalScrollback(DefaultScrollback, true)
			w.setTerminalCursor(CursorShapeBlock, CursorThicknessNormal, true)
			w.setFonts(fontprefs.Default(), true)
			w.setGitConsole(core.GitConsolePreferences{}, true)
			w.setGitLogLimits(DefaultGitLogLimit, DefaultGitLogMergedLimit)
		}
		w.footerMessage(c.Part("message"), language, applying, count, targets)
		if w.button(c.Part("cancel"), buttonPlain, settings.Cancel, applying) {
			w.cancel()
		}
		// Apply writes the Build pages' drafts. Other pages apply their own cards, so the
		// footer offers it only on a Build page or while Build drafts wait.
		onBuild := w.sess.page == pageBuild || parents[w.sess.page] == pageBuild
		if (onBuild || count > 0 || applying) && w.button(c.Part("apply"), buttonPlain, i18n.Shared(language, "desktop.buildSettings.apply"), count == 0 || applying) {
			w.startApply(false)
		}
		if w.button(c.Part("ok"), buttonPrimary, settings.OK, false) {
			w.accept()
		}
	})
}

// footerMessage is the footer's words between its buttons: that an apply is out, why the last
// one stopped, or how many edits Apply would write and where.
func (w *window) footerMessage(c ui.C, language i18n.Language, applying bool, count int, targets []string) {
	b := &w.bp
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Items(ui.Center).Children(func() {
		switch {
		case applying:
			ui.Text(c, i18n.Shared(language, "desktop.buildSettings.applying")).FontSize(buildSmall).Color(b.sub).Ellipsis()
		case w.apply.failed != nil:
			ui.Icon(c, icons.CircleX).Size(13, 13).Color(b.err).Shrink(0)
			ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.applyFailed", map[string]string{"reason": toolchainFailureMessage(language, w.apply.failed)})).
				FontSize(buildSmall).Color(b.err).Shrink(1).Ellipsis()
		case count > 0:
			dot(c, 7, b.accent)
			ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.pending", map[string]string{"count": formatCount(count)})).
				FontSize(buildSmall).Weight(gfx.WeightMedium).Color(b.text).Shrink(0)
			separator := i18n.Shared(language, "desktop.buildSettings.listSeparator")
			ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.writes", map[string]string{"targets": strings.Join(targets, separator)})).
				FontSize(buildSmall).Color(b.sub).Shrink(1).Ellipsis()
			w.infoButton(c.Part("help"), i18n.Shared(language, "desktop.buildSettings.applyHelp"))
		}
	})
}

// projectOpenLabel is the words of one project open destination.
func projectOpenLabel(language i18n.Language, value string) string {
	switch value {
	case ProjectOpenThisWindow:
		return i18n.Shared(language, "native.thisWindow")
	case ProjectOpenNewWindow:
		return i18n.Shared(language, "native.newWindow")
	}
	return i18n.Shared(language, "desktop.settings.projectOpenAsk")
}
