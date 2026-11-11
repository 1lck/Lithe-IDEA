package workbench

import (
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// everywherePopup declares the Search Everywhere dialog while it is open: the
// scope tabs in its header, the query field and the results in its body.
func (a *App) everywherePopup(c ui.C) {
	p, v := a.project, &a.everywhereView
	if p == nil || !v.open {
		return
	}
	s := &p.everywhere
	a.updateEverywhere(p, v.query.Text(), v.scope)
	if v.focus {
		c.Canvas().RequestFocus(everywhereQueryID)
		v.focus = false
	}
	language := a.language()
	// The panel hangs from a point at the top of the window, as it always has:
	// centered, 84 high, without a scrim. A press outside closes it and goes on
	// to whatever is under the pointer.
	bounds := c.Bounds()
	width := min(float32(670), max(0, bounds.Width-32))
	var height float32 = 84 - 2*8
	if strings.TrimSpace(v.query.Text()) != "" || v.scope == everywhereScopeActions {
		height = min(684, max(84, bounds.Height-100)) - 16
	}
	var anchor ui.Box
	ui.Stack(c).Fill().Children(func() {
		anchor = ui.Row(c).Absolute().Left((bounds.Width - width) / 2).Top(84).Width(width).Height(1)
	})
	closed := ui.PopoverWith(c, anchor, ui.PopoverSpec{
		Width: width, Offset: 1, Align: ui.Start, KeepOpenOnAnchor: true,
	}, &v.open, func() {
		ui.Column(c).FillWidth().Height(height).Gap(8).Children(func() {
			a.everywhereScopes(c, p, language)
			field := ui.TextFieldID(c, everywhereQueryID, &v.query, i18n.Shared(language, "desktop.everywhere.title"), "").
				Icon(icons.Search).Action(icons.X, i18n.Shared(language, "native.clearSearch"))
			if field.ActionClicked() {
				a.performed("workspace.search.clear", surfaceButton)
				v.query.SetText("")
				a.focusEverywhere(p)
			}
			if v.scope == everywhereScopeActions {
				a.everywhereActions(c)
				return
			}
			if strings.TrimSpace(v.query.Text()) == "" {
				return
			}
			switch {
			case s.loading && len(s.matches) == 0:
				ui.Text(c, i18n.Shared(language, "quickOpen.searching")).Muted()
			case s.failed && len(s.matches) == 0:
				ui.Text(c, i18n.Shared(language, "search.failed")).Color(a.theme.Danger)
			case len(s.matches) == 0:
				ui.Text(c, i18n.Shared(language, "native.noMatches")).Muted()
			default:
				a.everywhereResults(c, p, language)
			}
		})
	})
	if closed {
		a.closeEverywhere(p)
	}
}

// everywhereScopes are the tabs that narrow the search. The classes and symbols
// tabs are shown but not available yet; Actions lists commands (commands.go).
func (a *App) everywhereScopes(c ui.C, p *project, language i18n.Language) {
	v := &a.everywhereView
	labels := [...]string{
		i18n.Shared(language, "desktop.everywhere.all"),
		i18n.Shared(language, "desktop.everywhere.classes"),
		i18n.Shared(language, "desktop.everywhere.files"),
		i18n.Shared(language, "desktop.everywhere.symbols"),
		i18n.Shared(language, "desktop.everywhere.actions"),
		i18n.Shared(language, "desktop.everywhere.text"),
	}
	ui.Row(c).FillWidth().Gap(4).Children(func() {
		for index, label := range labels {
			disabled := false
			tab := ui.Button(c.KeyInt(index), label).Ghost().Disabled(disabled)
			if index == v.scope {
				tab.Secondary()
			}
			if !disabled && tab.Clicked() {
				a.performed("workspace.searchEverywhere.scope", surfaceButton)
				v.scope = index
				a.focusEverywhere(p)
			}
		}
	})
}

// everywhereResults is the virtualized list of matches. The arrows in the query
// field move its selection (everywhereKey), and a click or Enter opens a match.
func (a *App) everywhereResults(c ui.C, p *project, language i18n.Language) {
	v, s := &a.everywhereView, &p.everywhere
	rowHeight := float32(everywhereFileHeight)
	if s.scope == 5 {
		rowHeight = everywhereTextHeight
	}
	v.list.Label = func(i int) string { return searchMatchLabel(s.matches[i]) }
	if s.selected != v.list.Selected() {
		v.list.Select(s.selected)
		v.list.ScrollIntoView(s.selected)
	}
	opened := -1
	ui.List(c, &v.list, len(s.matches), func(row ui.ListRow) {
		result := s.matches[row.Index]
		label := searchMatchLabel(result)
		row.Element.FillWidth().Height(rowHeight).Items(ui.Center).PadX(10).Gap(8).Children(func() {
			name := filepath.Base(filepath.FromSlash(result.Path))
			ui.Icon(row.C, fileicons.ForFile(name, a.colors.Dark)).Size(16, 16).Color(a.colors.Subtle)
			if result.Kind == "content" {
				ui.Column(row.C).Grow(1).Shrink(1).MinWidth(0).Children(func() {
					ui.Text(row.C, result.Preview).Mono().FontSize(12).Ellipsis()
					ui.Text(row.C, label).FontSize(11).Color(a.colors.Subtle).Ellipsis()
				})
			} else {
				ui.Text(row.C, name).Grow(1).Shrink(1).MinWidth(0).FontSize(13).Ellipsis()
				subtitle := result.Path
				if module := a.moduleName(p, result.Path); module != "" {
					subtitle += " · " + module
				}
				ui.Text(row.C, subtitle).FontSize(12).Color(a.colors.Subtle).Ellipsis()
			}
		})
		if row.Element.Clicked() {
			opened = row.Index
		}
	}).Label(i18n.Shared(language, "desktop.everywhere.title")).Grow(1).MinHeight(0)
	if opened >= 0 {
		s.selected = opened
		result := s.matches[opened]
		c.After(func() {
			a.performed("workspace.searchEverywhere.openResult", surfaceButton)
			a.closeEverywhere(p)
			a.openSearchResult(p, result)
		})
		return
	}
	if v.list.Changed() {
		s.selected = max(v.list.Selected(), 0)
	}
	if s.failed {
		ui.Text(c, i18n.Shared(language, "search.failed")).Color(a.theme.Danger)
	}
	if s.cursor != nil && len(s.matches) >= everywhereMaxResults {
		ui.Paragraph(c, i18n.Shared(language, "desktop.everywhere.limit"), 2).Muted()
	} else if s.cursor != nil {
		if ui.Button(c, i18n.Shared(language, "desktop.everywhere.more")).Outline().Disabled(s.loading).Clicked() {
			a.performed("workspace.searchEverywhere.more", surfaceButton)
			c.After(func() {
				a.runEverywhere(p, true)
				a.focusEverywhere(p)
			})
		}
	}
}

// everywhereKey moves the selection with the arrows and opens it with Enter while
// the keyboard is in the query field. A plain key typed in a text field is the
// field's, so the page cannot declare these as shortcuts.
func (a *App) everywhereKey(p *project, event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Modifiers != 0 || event.Target != everywhereQueryID {
		return gfx.EventResult{}
	}
	if input := a.root.TextInput(app.TextInputContext{ID: everywhereQueryID}); input != nil && input.Editor != nil {
		if _, composing := input.Editor.Composition(); composing {
			return gfx.EventResult{}
		}
	}
	if a.everywhereView.scope == everywhereScopeActions {
		v := &a.everywhereView
		switch event.Key {
		case gfx.KeyUp:
			v.actionSelected = max(0, v.actionSelected-1)
		case gfx.KeyDown:
			v.actionSelected = min(max(0, v.actionCount-1), v.actionSelected+1)
		case gfx.KeyEnter:
			a.runSelectedAction()
		default:
			return gfx.EventResult{}
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	s := &p.everywhere
	switch event.Key {
	case gfx.KeyUp:
		s.selected = max(0, s.selected-1)
	case gfx.KeyDown:
		s.selected = min(max(0, len(s.matches)-1), s.selected+1)
	case gfx.KeyEnter:
		if s.selected >= 0 && s.selected < len(s.matches) {
			result := s.matches[s.selected]
			a.performed("workspace.searchEverywhere.openResult", surfaceShortcut)
			a.closeEverywhere(p)
			a.openSearchResult(p, result)
		}
	default:
		return gfx.EventResult{}
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}
