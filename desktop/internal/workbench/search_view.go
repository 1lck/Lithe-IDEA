package workbench

import (
	"path/filepath"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/ui"
)

// searchPanelPage makes the Find in Files page on first use.
func (a *App) searchPanelPage() *ui.Page {
	v := &a.searchView
	if v.page == nil {
		v.page = ui.NewPage(ui.PageConfig{
			View: a.searchPanel, Tree: &tree, Root: "project-search",
			Theme: &a.theme, Invalidator: &a.invalidator,
		})
	}
	return v.page
}

// drawProjectSearch puts the Find in Files page in the region of the tool window
// the shell laid out for it.
func (a *App) drawProjectSearch(f *ui.Frame, p *project) {
	page := a.searchPanelPage()
	f.Slot().FillWidth().Grow(1).Shrink(1).MinHeight(0).Draw(func(d *ui.DrawContext) {
		page.Draw(d.Canvas, d.Rect, a.searchPanel)
	})
}

// closeSearchPanel ends the page with the window.
func (a *App) closeSearchPanel() {
	if a.searchView.page != nil {
		a.searchView.page.Close()
		a.searchView.page = nil
	}
}

// searchPanel is the Find in Files tool window: the query and file mask fields,
// the option and refresh buttons and the list of matches.
func (a *App) searchPanel(c ui.C) {
	p, v := a.project, &a.searchView
	if p == nil {
		return
	}
	language := a.language()
	query := searchQuery{text: v.query.Text(), mask: v.mask.Text(), matchCase: v.matchCase, wholeWords: v.wholeWords, regex: v.regex}
	a.updateProjectSearch(p, query)
	if v.focus {
		c.Canvas().RequestFocus(searchQueryID)
		v.focus = false
	}
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).FillWidth().PadSides(3, 10, 6, 10).Items(ui.Center).Gap(6).Children(func() {
			label := i18n.Shared(language, "native.searchFilesAndContents")
			field := ui.TextFieldID(c, searchQueryID, &v.query, label, label).Icon(icons.Search).
				Action(icons.X, i18n.Shared(language, "native.clearSearch")).Grow(1).MinWidth(0)
			if field.ActionClicked() {
				a.performed("workspace.search.clear", surfaceButton)
				v.query.SetText("")
				c.Canvas().RequestFocus(searchQueryID)
			}
			a.searchOptions(c, language)
			refresh := ui.Button(c, i18n.Shared(language, "ui.refresh")).Icon(icons.RefreshCw).IconOnly().Ghost().
				Disabled(strings.TrimSpace(p.search.want.text) == "")
			if refresh.Clicked() {
				a.performed("workspace.search.refresh", surfaceButton)
				c.After(func() { a.refreshProjectSearch(p) })
			}
		})
		ui.Row(c).FillWidth().PadX(10).PadSides(0, 10, 10, 10).Children(func() {
			label := i18n.Shared(language, "native.fileMask")
			mask := ui.TextFieldID(c, searchMaskID, &v.mask, label, i18n.Shared(language, "desktop.search.fileMaskPlaceholder")).
				Icon(icons.Search).Action(icons.X, i18n.Shared(language, "native.clearSearch")).Grow(1).MinWidth(0)
			if mask.ActionClicked() {
				a.performed("workspace.search.clear", surfaceButton)
				v.mask.SetText("")
				c.Canvas().RequestFocus(searchMaskID)
			}
		})
		ui.Divider(c)
		switch {
		case strings.TrimSpace(query.text) == "":
			ui.Column(c).Fill().Center().Gap(9).Children(func() {
				ui.Icon(c, icons.Search).Size(28, 28).Color(a.colors.Subtle)
				ui.Text(c, i18n.Shared(language, "native.searchAcrossTheProject")).Color(a.colors.Subtle)
			})
		case p.search.loading:
			ui.Column(c).Fill().Center().Children(func() { ui.Text(c, i18n.Shared(language, "quickOpen.searching")).Muted() })
		case p.search.failed:
			ui.Column(c).Fill().Center().Children(func() { ui.Text(c, i18n.Shared(language, "search.failed")).Color(a.theme.Danger) })
		case len(p.search.matches) == 0:
			ui.Column(c).Fill().Center().Children(func() { ui.Text(c, i18n.Shared(language, "native.noMatches")).Muted() })
		default:
			a.searchResults(c, p, language)
		}
	})
}

// searchOptions is the button that opens the match case, whole word and regular
// expression switches.
func (a *App) searchOptions(c ui.C, language i18n.Language) {
	v := &a.searchView
	button := ui.Button(c, i18n.Shared(language, "native.searchOptions")).Icon(icons.Settings).IconOnly().Ghost()
	if button.Clicked() {
		v.optionsOpen = !v.optionsOpen
	}
	ui.PopoverWith(c, button, ui.PopoverSpec{Align: ui.End, Width: 210}, &v.optionsOpen, func() {
		option := func(label, action string, value *bool) {
			before := *value
			ui.Checkbox(c, value, label)
			if *value != before {
				a.performed(action, surfaceButton)
			}
		}
		option(i18n.Shared(language, "native.matchCase"), "workspace.search.matchCase", &v.matchCase)
		option(i18n.Shared(language, "native.wholeWords"), "workspace.search.wholeWords", &v.wholeWords)
		option(i18n.Shared(language, "native.regularExpression"), "workspace.search.regularExpression", &v.regex)
	})
}

// searchResults is the virtualized list of matches: a click or Enter opens one,
// and the arrows move between them.
func (a *App) searchResults(c ui.C, p *project, language i18n.Language) {
	v := &a.searchView
	results := p.search.matches
	v.list.Label = func(i int) string { return searchMatchLabel(results[i]) }
	opened := -1
	ui.List(c, &v.list, len(results), func(row ui.ListRow) {
		result := results[row.Index]
		row.Element.FillWidth().Height(searchResultHeight).PadX(11).PadY(6).Gap(2).Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
			ui.Row(row.C).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				name := filepath.Base(filepath.FromSlash(result.Path))
				ui.Icon(row.C, fileicons.ForFile(name, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
				ui.Text(row.C, name).Grow(1).Shrink(1).FontSize(12.5).Ellipsis()
				if result.Line != nil {
					ui.Text(row.C, ":"+strconv.Itoa(*result.Line)).FontSize(12).Color(a.colors.Subtle)
				}
			})
			ui.Text(row.C, result.Preview).FontSize(11.5).Mono().Color(a.colors.Subtle).Ellipsis()
		})
		if row.Element.Clicked() {
			opened = row.Index
		}
	}).Label(i18n.Shared(language, "native.searchAcrossTheProject")).FillWidth().Grow(1).MinHeight(0)
	if row, ok := v.list.Submitted(); ok {
		opened = row
	}
	if opened >= 0 && opened < len(results) {
		result := results[opened]
		c.After(func() {
			a.performed("workspace.search.openResult", surfaceButton)
			a.openSearchResult(p, result)
		})
	}
	if len(results) == searchMaxResults {
		ui.Paragraph(c, i18n.Shared(language, "desktop.search.first200"), 2).PadX(11).PadY(8).Color(a.colors.Subtle)
	}
}

// searchMatchLabel names a match by its path and line.
func searchMatchLabel(match core.WorkspaceSearchMatch) string {
	label := match.Path
	if match.Line != nil {
		label += ":" + strconv.Itoa(*match.Line)
	}
	return label
}
