package workbench

import (
	"path/filepath"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/ui"
)

// searchPanel is the Find in Files tool window: the query and file mask fields,
// the option and refresh buttons and the list of matches.
func (a *App) searchPanel(c ui.C) {
	p, v := a.project, &a.searchView
	if p == nil {
		return
	}
	language := a.language()
	query := searchQuery{text: v.query.Text(), mask: v.mask.Text(), scope: v.scope.Text(), includeIgnored: v.includeIgnored, matchCase: v.matchCase, wholeWords: v.wholeWords, regex: v.regex}
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
			a.searchReplaceToggle(c)
			a.searchOptions(c, language)
			refresh := ui.Button(c, i18n.Shared(language, "ui.refresh")).Icon(icons.RefreshCw).IconOnly().Ghost().
				Disabled(strings.TrimSpace(p.search.want.text) == "").Tooltip(i18n.Shared(language, "ui.refresh"))
			if refresh.Clicked() {
				a.performed("workspace.search.refresh", surfaceButton)
				c.After(func() { a.refreshProjectSearch(p) })
			}
		})
		scopeReady := a.searchScopeControls(c, p, language)
		query.scope = v.scope.Text()
		if !scopeReady {
			query.text = ""
		}
		a.updateProjectSearch(p, query)
		a.searchReplaceRow(c, query)
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
		case p.search.loading && len(p.search.matches) == 0:
			ui.Column(c).Fill().Center().Children(func() { ui.Text(c, i18n.Shared(language, "quickOpen.searching")).Muted() })
		case p.search.failed && len(p.search.matches) == 0:
			ui.Column(c).Fill().Center().Children(func() {
				ui.Text(c, i18n.Shared(language, "search.failed")).Color(a.theme.Danger)
				a.projectSearchRetry(c, p, language)
			})
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
	button := ui.Button(c, i18n.Shared(language, "native.searchOptions")).Icon(icons.Settings).IconOnly().Ghost().
		Tooltip(i18n.Shared(language, "native.searchOptions"))
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
		option(i18n.Shared(language, "desktop.search.includeIgnored"), "workspace.search.includeIgnored", &v.includeIgnored)
	})
}

// searchResults is the virtualized list of matches: a click or Enter opens one,
// and the arrows move between them.
func (a *App) searchResults(c ui.C, p *project, language i18n.Language) {
	v := &a.searchView
	results := p.search.matches
	projection := p.search.presentation
	rows := projection.Rows
	summary := i18n.SharedFormat(language, "desktop.search.count", map[string]string{"count": strconv.Itoa(projection.Lines), "files": strconv.Itoa(projection.Files)})
	if p.search.cursor != nil {
		summary = i18n.SharedFormat(language, "desktop.search.loadedCount", map[string]string{"count": strconv.Itoa(projection.Lines), "files": strconv.Itoa(projection.Files)})
	}
	ui.Text(c, summary).FontSize(12).Color(a.colors.Subtle).PadX(11)
	v.list.Label = func(i int) string {
		if rows[i].MatchIndex == nil {
			return rows[i].Path
		}
		return searchMatchLabel(results[*rows[i].MatchIndex])
	}
	opened := -1
	resultList := ui.List(c, &v.list, len(rows), func(row ui.ListRow) {
		item := rows[row.Index]
		if item.MatchIndex == nil {
			row.Element.FillWidth().Height(searchResultHeight).PadX(11).Items(ui.Center).Gap(6).Children(func() {
				icon := icons.ChevronDown
				if p.search.collapsed[item.Path] {
					icon = icons.ChevronRight
				}
				ui.Icon(row.C, icon).Size(14, 14)
				ui.Text(row.C, i18n.SharedFormat(language, "desktop.search.group", map[string]string{"path": item.Path, "count": strconv.Itoa(item.Count)})).FontSize(12).Ellipsis()
			})
			if row.Element.Clicked() {
				p.search.collapsed[item.Path] = !p.search.collapsed[item.Path]
				a.projectSearchPresentation(p)
			}
			return
		}
		result := results[*item.MatchIndex]
		row.Element.FillWidth().Height(searchResultHeight).PadX(11).PadY(6).Gap(2).Hover(ui.Look{}.Background(a.colors.Hover)).Children(func() {
			ui.Column(row.C).FillWidth().Gap(2).Children(func() {
				ui.Row(row.C).FillWidth().Items(ui.Center).Gap(6).Children(func() {
					name := filepath.Base(filepath.FromSlash(result.Path))
					ui.Icon(row.C, fileicons.ForFile(name, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
					ui.Text(row.C, name).Grow(1).Shrink(1).FontSize(12.5).Ellipsis()
					if result.Line != nil {
						ui.Text(row.C, searchLinePosition(result)).FontSize(12).Color(a.colors.Subtle)
					}
				})
				// Core gives the line as a result row shows it, and the matches in it.
				preview, ranges := result.Preview, result.PreviewRanges
				ui.Row(row.C).FillWidth().MinWidth(0).Clip().Children(func() {
					a.highlightedText(row.C, preview, ranges, a.colors.Subtle, 11.5, true)
				})
			})
		})
		if row.Element.Clicked() {
			opened = row.Index
		}
		a.searchResultMenu(row.C, row.Element, p, result, language, "workspace.search", nil)
	}).Scrollbars().Label(i18n.Shared(language, "native.searchAcrossTheProject")).FillWidth().Grow(1).MinHeight(0)
	if row, ok := v.list.Submitted(); ok {
		opened = row
	}
	// Open Selected File (F4 unless the user rebinds it) opens the selected match at its line, as
	// Enter does; the match keeps its place.
	if a.elementShortcut(resultList, shortcuts.OpenSelected) && v.list.Selected() >= 0 {
		opened = v.list.Selected()
	}
	if opened >= 0 && opened < len(rows) && rows[opened].MatchIndex == nil {
		path := rows[opened].Path
		if p.search.collapsed == nil {
			p.search.collapsed = map[string]bool{}
		}
		p.search.collapsed[path] = !p.search.collapsed[path]
		a.projectSearchPresentation(p)
	}
	if opened >= 0 && opened < len(rows) && rows[opened].MatchIndex != nil {
		result := results[*rows[opened].MatchIndex]
		c.After(func() {
			a.performed("workspace.search.openResult", surfaceButton)
			a.openSearchResult(p, result)
		})
	}
	if p.search.failed {
		a.projectSearchRetry(c, p, language)
	}
	if p.search.cursor != nil && !p.search.running && !p.search.failed {
		if _, last := v.list.Visible(); last >= len(rows)-8 {
			a.post(func(a *App) { a.loadMoreProjectSearch(p) })
		}
	}
}

// searchMatchLabel names a match by its path, line and column.
func searchMatchLabel(match core.WorkspaceSearchMatch) string {
	if match.Line == nil {
		return match.Path
	}
	return match.Path + searchLinePosition(match)
}

// searchLinePosition is ":line" or ":line:column" of a content match.
func searchLinePosition(match core.WorkspaceSearchMatch) string {
	position := ":" + strconv.Itoa(*match.Line)
	if column := searchMatchColumn(match); column > 0 {
		position += ":" + strconv.Itoa(column)
	}
	return position
}
