package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
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
	w.declareWork(c)
}

// keys gives Escape its meaning of Cancel, or of emptying the search while the search has
// the text, and Enter its meaning of OK while no control holds the focus. An open list or
// help takes Escape first, as it claims a deeper focus scope; Enter on a control is the
// control's. The platform's Find focuses the search and its Close key closes the window.
func (w *window) keys(c ui.C) {
	canvas := c.Canvas()
	escape := ui.ID(c)
	canvas.SetEscapeTarget(escape)
	if canvas.Clicked(escape) {
		switch decideKey(keyEscape, keyContext{searching: canvas.Focused() == searchID, queryEmpty: w.searchField.Text() == ""}) {
		case actionCancel:
			w.cancel()
		case actionClearSearch:
			w.searchField.SetText("")
		}
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
	leading, trailing := app.TitlebarInsets()
	ui.Stack(c).FillWidth().Height(titleHeight).Shrink(0).Background(w.pal.titleBar).MovesWindow().Children(func() {
		ui.Row(c).Fill().PadSides(0, max(8, trailing), 0, max(80, leading+10)).Items(ui.Center).Children(func() {
			ui.Text(c, w.text.Settings.Title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
		})
	})
}

// sidebar is the column at the leading side: the search field above the list of pages.
func (w *window) sidebar(c ui.C) {
	p := &w.pal
	settings := &w.text.Settings
	ui.Column(c).Width(sidebarWidth).FillHeight().Shrink(0).Background(p.sidebar).Clip().Children(func() {
		ui.Row(c).FillWidth().Shrink(0).PadSides(10, 12, 8, 12).Children(func() {
			search := ui.TextFieldID(c, searchID, &w.searchField, settings.Search, settings.Search).Icon(icons.Search).FillWidth().Height(searchHeight)
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
			ui.Row(c).FillWidth().Shrink(0).PadX(16).PadY(8).Children(func() {
				ui.Wrap(c, settings.NoMatches).FontSize(12).Color(p.muted)
			})
			return
		}
		ui.Tree(c, &w.nav, len(w.rows), w.navLabel, func(i int) { w.navContent(c, i) }).Grow(1).Shrink(1).MinHeight(0).Label(settings.Categories)
		if i, ok := w.nav.Toggled(); ok && i < len(w.rows) {
			w.toggleRow(w.rows[i])
		}
		if i, ok := w.nav.Chosen(); ok && i < len(w.rows) {
			if r := w.rows[i]; r.group {
				w.toggleRow(r)
			} else {
				w.selectSettingsPage(r.page, r.dynamic)
			}
		}
	})
}

// toggleRow expands or collapses the group of row r. While searching every group is open.
func (w *window) toggleRow(r row) {
	toggleGroup(&w.sess.open, r.page, w.query != "")
}

// rowTitle is the words of a sidebar row: a contributed page's own title, else its page's.
func (w *window) rowTitle(r row) string {
	if r.title != "" {
		return r.title
	}
	return titleOf(&w.text.Settings, r.page)
}

// navNode describes row i of the sidebar to its Tree.
func (w *window) navNode(i int) ui.TreeNode {
	if i < 0 || i >= len(w.rows) {
		return ui.TreeNode{}
	}
	r := w.rows[i]
	return ui.TreeNode{
		Depth: int(r.level), Branch: r.group, Expanded: r.expanded,
		Selected: !r.group && r.page == w.sess.page && r.dynamic == w.dynamicPage,
	}
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
	return w.rowTitle(w.rows[i])
}

// navContent declares what row i holds after its chevron: the page's tile on the top level
// and its title.
func (w *window) navContent(c ui.C, i int) {
	if i < 0 || i >= len(w.rows) {
		return
	}
	r := w.rows[i]
	if r.level == 0 {
		if !r.group {
			// A page that is not a group keeps the room of the chevron, so every tile lines up.
			ui.Row(c).Width(chevronSlot - 8).Shrink(0)
		}
		t := tiles[r.page]
		ui.Row(c).Size(tileSize, tileSize).Shrink(0).Radius(tileRadius).Background(t.color).Center().Children(func() {
			ui.Icon(c, t.icon).Size(tileGlyph, tileGlyph).Color(w.pal.white)
		})
	}
	ui.Text(c, w.rowTitle(r)).FontSize(13).Color(w.pal.text).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
}

// content is the page beside the sidebar: the breadcrumb above the page itself.
func (w *window) content(c ui.C) {
	if w.sess.page != pagePlugins && w.market.status == marketLoading {
		// Leaving the page stops wanting the fetch, which cancels it.
		w.market.close()
	}
	ui.Column(c).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
		if w.sess.page == pagePlugins && w.ctrl.opts.Marketplace != nil {
			w.marketplacePage(c)
			return
		}
		w.breadcrumb(c)
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
		case w.sess.page == pageBuild && (w.ctrl.opts.Toolchains != nil || w.stepping.available()):
			w.toolchainsPage(c)
		case w.sess.page == pageTerminal && w.ctrl.opts.TerminalShells != nil:
			w.terminalPage(c)
		case w.sess.page == pageAIAgents:
			w.agentsPage(c)
		case w.sess.page == pageAIInstructions:
			w.instructionsPage(c)
		case w.sess.page == pageAISkills:
			w.skillsPage(c)
		case w.sess.page == pageAIHooks:
			w.hooksPage(c)
		case w.sess.page == pageVersionControl:
			w.versionControlPage(c)
		case w.sess.page == pageKeymap:
			w.keymapPage(c)
		case w.sess.page == pageProcessTermination:
			w.processTerminationPage(c)
		case w.sess.page == pageMCP && w.ctrl.opts.MCP != nil:
			w.mcpPage(c)
		case w.sess.page == pageIDEAPI && w.ctrl.opts.IDEAPI != nil:
			w.ideAPIPage(c)
		default:
			w.unavailablePage(c)
		}
	})
}

// breadcrumb names where the open page is: its group, then the page. The last title is
// the page itself and is set apart by its weight; a page on the top level has only that.
func (w *window) breadcrumb(c ui.C) {
	p := &w.pal
	w.crumbs = appendBreadcrumb(w.crumbs[:0], &w.text.Settings, w.sess.page)
	if page := w.dynamic.selected(w.dynamicPage); page != nil {
		w.crumbs = append(w.crumbs, page.Title)
	}
	ui.Row(c).FillWidth().Height(46).Shrink(0).PadX(contentPad).Gap(6).Items(ui.Center).Background(p.card).Children(func() {
		for i, crumb := range w.crumbs {
			if i > 0 {
				ui.Icon(c, icons.ChevronRight).Size(chevronGlyph, chevronGlyph).Color(p.subtle).Shrink(0)
			}
			if i == len(w.crumbs)-1 {
				ui.Text(c, crumb).FontSize(13).Weight(gfx.WeightSemibold).Color(p.text).Ellipsis()
			} else {
				ui.Text(c, crumb).FontSize(13).Color(p.muted).Ellipsis()
			}
		}
	})
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(p.line)
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
	ui.Scroll(c.KeyInt(int(page))).Grow(1).Shrink(1).MinHeight(0).PadSides(18, contentPad, contentPad, contentPad).Gap(cardGap).Children(body)
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
			Background(p.card).Stroke(1, p.line).Children(body)
	})
}

// infoButton is the information glyph: hovering it shows help in a tip, and pressing it
// pins the help open in a popover until a press elsewhere or Escape.
func (w *window) infoButton(c ui.C, help string) {
	ui.Row(c).Size(18, 18).Shrink(0).Center().Children(func() {
		open := ui.State[bool](c, "info")
		button := ui.Button(c, i18n.Shared(w.marketLanguage(), "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).Tooltip(help)
		if button.Clicked() {
			*open = !*open
		}
		ui.PopoverWith(c, button, ui.PopoverSpec{Align: ui.Start}, open, func() {
			ui.Wrap(c, help).FontSize(12).Color(w.pal.text).MaxWidth(320).Pad(8)
		})
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

// generalPage is the general page: the cards that edit settings, then the one that
// reports the version.
func (w *window) generalPage(c ui.C) {
	p := &w.pal
	settings := &w.text.Settings
	w.themePick = w.sess.values.Theme
	w.languagePick = languageCode(languageIndex(w.sess.values.Language))
	w.pageScroll(c, pageGeneral, func() {
		w.card(c, settings.Appearance, settings.AppearanceHelp, func() {
			choice := func() {
				ui.Choice(c, &w.themePick, themeValues[:], w.themeLabel).Width(420).Shrink(1).MinWidth(0).Label(settings.AppearanceMode)
			}
			if w.extent-2*contentPad-2*cardPad < 590 {
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
			ui.Row(c).FillWidth().Items(ui.Center).Children(func() {
				// Pressing the button is its own confirmation, so it acts at once.
				if ui.Button(c, settings.ResetLayout).Outline().Clicked() && w.ctrl.opts.ResetLayout != nil {
					w.ctrl.opts.ResetLayout()
				}
			})
		})
		w.card(c, settings.About, "", func() {
			ui.Column(c).FillWidth().Gap(2).Children(func() {
				ui.Text(c, w.text.App.Name).FontSize(13).Weight(gfx.WeightSemibold).Color(p.text).Ellipsis()
				ui.Text(c, w.text.App.Version(w.ctrl.opts.Version)).FontSize(12).Color(p.muted).Ellipsis()
			})
		})
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
// squeezed, or as many rows as they need. The two choices for one row refine the first
// option and are set in under it; they are dimmed while several rows are chosen, which
// keeps what was picked for one row for when the user goes back to it.
func (w *window) editorPage(c ui.C) {
	p := &w.pal
	settings := &w.text.Settings
	values := &w.sess.values
	w.tabRowsPick, w.tabOverflowPick = values.EditorTabRows, values.EditorTabOverflow
	w.pageScroll(c, pageEditor, func() {
		w.card(c, settings.EditorTabs, settings.EditorTabsHelp, func() {
			ui.Column(c).FillWidth().Gap(2).Children(func() {
				ui.Row(c).FillWidth().Height(radioHeight).Items(ui.Center).Children(func() {
					ui.Text(c, settings.TabsShowIn).FontSize(12).Color(p.text).Ellipsis()
				})
				multiple := values.EditorTabRows == TabRowsMultiple
				w.radio(c.Part("one-row"), &w.tabRowsPick, "", settings.TabsOneRow, false)
				ui.Column(c).FillWidth().PadSides(0, 0, 0, radioIndent).Gap(2).Children(func() {
					w.radio(c.Part("scroll"), &w.tabOverflowPick, "", settings.TabsScroll, multiple)
					w.radio(c.Part("squeeze"), &w.tabOverflowPick, TabOverflowSqueeze, settings.TabsSqueeze, multiple)
				})
				w.radio(c.Part("several-rows"), &w.tabRowsPick, TabRowsMultiple, settings.TabsMultipleRows, false)
			})
		})
		semantic := !values.DisableSemanticHighlight
		w.card(c, settings.EditorSemantic, settings.EditorSemanticHelp, func() {
			if ui.Switch(c.Part("semantic"), &semantic, settings.SemanticHighlight).Changed() {
				w.setDisableSemanticHighlight(!semantic, false)
			}
		})
	})
	if w.tabRowsPick != values.EditorTabRows {
		w.setTabRows(w.tabRowsPick, false)
	}
	if w.tabOverflowPick != values.EditorTabOverflow {
		w.setTabOverflow(w.tabOverflowPick, false)
	}
}

// footer is the bar along the bottom: Restore Defaults at the leading end, Cancel and OK
// at the trailing one.
func (w *window) footer(c ui.C) {
	settings := &w.text.Settings
	ui.Row(c).FillWidth().Height(footerHeight).Shrink(0).PadX(footerPad).Gap(8).Items(ui.Center).Children(func() {
		if ui.Button(c, settings.RestoreDefaults).Outline().Clicked() {
			// Reset is explicit even when an unknown stored value is displayed as the
			// system default. Forward it so the owner's real setting is cleared.
			w.setLanguage("", true)
			w.setTheme("", true)
			w.setTabRows("", true)
			w.setTabOverflow("", true)
			w.setDisableSemanticHighlight(false, true)
			w.setProcessTermination(ProcessTermination{}, true)
			w.resetSteppingFilters()
			w.setTerminalShell("", true)
			w.setFonts(fontprefs.Default(), true)
		}
		ui.Spacer(c)
		if ui.Button(c, settings.Cancel).Outline().Clicked() {
			w.cancel()
		}
		if ui.Button(c, settings.OK).Clicked() {
			w.accept()
		}
	})
}
