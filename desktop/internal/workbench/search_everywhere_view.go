package workbench

import (
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// everywherePrefetch is how close to the last loaded row the list may scroll
	// before the next page is asked for.
	everywherePrefetch = 8
	// everywherePreviewList is the list's height above the preview until the user
	// drags the splitter.
	everywherePreviewList = 180
)

// everywherePopup declares the Search Everywhere dialog while it is open: the
// scope tabs in its header, the query field and the results in its body.
func (a *App) everywherePopup(c ui.C) {
	p, v := a.project, &a.everywhereView
	if p == nil || !v.open {
		return
	}
	s := &p.everywhere
	scope := v.effectiveScope()
	a.updateEverywhere(p, v.query.Text(), scope)
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
	if strings.TrimSpace(v.query.Text()) != "" || scope == everywhereScopeActions {
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
			field := ui.TextFieldID(c, everywhereQueryID, &v.query, i18n.Shared(language, "desktop.everywhere.title"),
				i18n.Shared(language, "native.typeToSeeCommands")).
				Icon(icons.Search).Action(icons.X, i18n.Shared(language, "native.clearSearch"))
			if field.ActionClicked() {
				a.performed("workspace.search.clear", surfaceButton)
				v.query.SetText("")
				a.focusEverywhere(p)
			}
			if scope == everywhereScopeActions {
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
				ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
					ui.Text(c, i18n.Shared(language, "search.failed")).Color(a.theme.Danger)
					a.everywhereRetry(c, p, language)
				})
			case len(s.matches) == 0:
				ui.Text(c, i18n.Shared(language, "native.noMatches")).Muted()
			case v.preview:
				a.everywhereWithPreview(c, p, language)
			default:
				a.everywhereResults(c, p, language)
			}
		})
	})
	if closed {
		a.closeEverywhere(p)
	}
}

// everywhereScopes are the tabs that narrow the search, then the preview switch and
// the filter of the tab. Actions lists commands (commands.go).
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
	ui.Row(c).FillWidth().Gap(4).Items(ui.Center).Children(func() {
		for index, label := range labels {
			tab := ui.Button(c.KeyInt(index), label).Ghost()
			if index == v.scope {
				tab.Secondary()
			}
			if tab.Clicked() {
				a.performed("workspace.searchEverywhere.scope", surfaceButton)
				v.scope = index
				a.focusEverywhere(p)
			}
		}
		ui.Spacer(c).Grow(1)
		preview := ui.Button(c.Key("everywherePreview"), i18n.Shared(language, "native.showPreview")).Icon(icons.Eye).IconOnly().Ghost()
		if v.preview {
			preview.Secondary()
		}
		if preview.Clicked() {
			a.performed("workspace.searchEverywhere.preview", surfaceButton)
			v.preview = !v.preview
			if !v.preview {
				v.source.close()
			}
			a.focusEverywhere(p)
		}
		if v.scope == 0 || v.scope == 5 {
			a.everywhereFilter(c, p, language)
		}
	})
}

// everywhereFilter is the filter of the All tab (which kinds of names it lists) and
// the text options of the Text tab.
func (a *App) everywhereFilter(c ui.C, p *project, language i18n.Language) {
	v := &a.everywhereView
	label := i18n.Shared(language, "native.filterResults")
	if v.scope == 5 {
		label = i18n.Shared(language, "native.searchOptions")
	}
	button := ui.Button(c.Key("everywhereFilter"), label).Icon(icons.Settings).IconOnly().Ghost()
	if v.filtered() {
		button.Secondary()
	}
	if button.Clicked() {
		v.filterOpen = !v.filterOpen
	}
	ui.PopoverWith(c, button, ui.PopoverSpec{Align: ui.End, Width: 230}, &v.filterOpen, func() {
		if v.scope == 5 {
			option := func(label, action string, value *bool) {
				before := *value
				ui.Checkbox(c, value, label)
				if *value != before {
					a.performed(action, surfaceButton)
				}
			}
			option(i18n.Shared(language, "native.matchCase"), "workspace.searchEverywhere.matchCase", &v.matchCase)
			option(i18n.Shared(language, "native.wholeWords"), "workspace.searchEverywhere.wholeWords", &v.wholeWords)
			option(i18n.Shared(language, "native.regularExpression"), "workspace.searchEverywhere.regularExpression", &v.regex)
			return
		}
		if v.hiddenKinds == nil {
			v.hiddenKinds = map[string]bool{}
		}
		names := map[string]string{
			"file":   i18n.Shared(language, "desktop.everywhere.files"),
			"type":   i18n.Shared(language, "desktop.everywhere.classes"),
			"symbol": i18n.Shared(language, "desktop.everywhere.symbols"),
		}
		for _, kind := range everywhereKinds {
			shown := !v.hiddenKinds[kind]
			if ui.Checkbox(c.Key("kind-"+kind), &shown, names[kind]).Changed() {
				a.performed("workspace.searchEverywhere.filter", surfaceButton)
				v.hiddenKinds[kind] = !shown
			}
		}
		ui.Row(c).Gap(6).Children(func() {
			if ui.Button(c.Key("kindsAll"), i18n.Shared(language, "native.all")).Outline().Clicked() {
				v.hiddenKinds = map[string]bool{}
			}
			if ui.Button(c.Key("kindsNone"), i18n.Shared(language, "native.none")).Outline().Clicked() {
				for _, kind := range everywhereKinds {
					v.hiddenKinds[kind] = true
				}
			}
			if ui.Button(c.Key("kindsInvert"), i18n.Shared(language, "native.invert")).Outline().Clicked() {
				for _, kind := range everywhereKinds {
					v.hiddenKinds[kind] = !v.hiddenKinds[kind]
				}
			}
		})
	})
}

// everywhereWithPreview puts the results above a read-only view of the selected
// result's file. A click then only selects; a double click or Enter opens.
func (a *App) everywhereWithPreview(c ui.C, p *project, language i18n.Language) {
	v, s := &a.everywhereView, &p.everywhere
	if v.split.Pos <= 0 {
		v.split.Pos = everywherePreviewList
	}
	if s.selected >= 0 && s.selected < len(s.matches) {
		result := s.matches[s.selected]
		if path, ok := everywhereResultPath(p, result); ok {
			line := 0
			if result.Line != nil {
				line = *result.Line
			}
			a.showSourcePreview(p, &v.source, path, line, func(a *App) bool {
				return a.everywhereView.open && a.everywhereView.preview
			})
		}
	}
	ui.Column(c).FillWidth().Grow(1).Basis(0).MinHeight(0).Children(func() {
		ui.Column(c).FillWidth().Height(v.split.Pos).Shrink(0).MinHeight(0).Children(func() {
			a.everywhereResults(c, p, language)
		})
		ui.Splitter(c, &v.split).Mins(72, 100).Label(a.text.Panel.Resize)
		a.sourcePreviewPane(c, &v.source, "everywherePreview", i18n.Shared(language, "native.selectAFileToPreview"))
	})
}

// everywhereResults is the virtualized list of matches. The arrows in the query
// field move its selection (everywhereKey), and a click or Enter opens a match;
// with the preview on, a click selects and a double click opens. Scrolling near the
// end of what was loaded asks for the next page.
func (a *App) everywhereResults(c ui.C, p *project, language i18n.Language) {
	v, s := &a.everywhereView, &p.everywhere
	rowHeight := float32(everywhereFileHeight)
	if s.scope == 5 {
		rowHeight = everywhereTextHeight
	}
	v.list.Label = func(i int) string { return searchMatchLabel(s.matches[i]) }
	// The list learns its row count when it is declared, so the first paint with matches
	// cannot select one yet and the next does. Only a selection that moved scrolls the list;
	// otherwise that later selection would undo a wheel scroll made in between.
	if s.selected != v.list.Selected() {
		v.list.Select(s.selected)
	}
	if s.selected != v.scrolledTo {
		v.scrolledTo = s.selected
		v.list.ScrollIntoView(s.selected)
	}
	opened := -1
	ui.List(c, &v.list, len(s.matches), func(row ui.ListRow) {
		result := s.matches[row.Index]
		selected := row.Index == s.selected
		row.Element.FillWidth().Height(rowHeight).Items(ui.Center).PadX(10).Gap(8).Children(func() {
			a.everywhereRow(row.C, p, result, selected)
		})
		a.searchResultMenu(row.C, row.Element, p, result, language, "workspace.searchEverywhere", func() { a.closeEverywhere(p) })
		switch {
		case v.preview && row.Element.DoubleClicked():
			opened = row.Index
		case v.preview && row.Element.Clicked():
			s.selected = row.Index
		case !v.preview && row.Element.Clicked():
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
		ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, i18n.Shared(language, "search.failed")).Color(a.theme.Danger)
			a.everywhereRetry(c, p, language)
		})
		return
	}
	if s.cursor != nil && len(s.matches) >= everywhereMaxResults {
		ui.Paragraph(c, i18n.Shared(language, "desktop.everywhere.limit"), 2).Muted()
		return
	}
	if s.cursor != nil && !s.loading && !s.running {
		// A wheel scroll paints without an event pass, which drops c.After, so the next page is
		// asked for through the window's queue.
		if _, last := v.list.Visible(); last >= len(s.matches)-everywherePrefetch {
			a.post(func(a *App) { a.runEverywhere(p, true) })
		}
	}
}

// everywhereRow declares one match: the name, with Core's matched fragments marked
// on the selected row, the line of a type or symbol, the folder, and the module.
// A content match shows its line with the matches marked, above the file and line.
func (a *App) everywhereRow(c ui.C, p *project, result core.WorkspaceSearchMatch, selected bool) {
	name := path.Base(result.Path)
	ui.Icon(c, fileicons.ForFile(name, a.colors.Dark)).Size(16, 16).Color(a.colors.Subtle).Shrink(0)
	folder := path.Dir(result.Path)
	if folder == "." {
		folder = ""
	}
	if result.Kind == "content" {
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
			text, ranges := result.Preview, []core.SearchNameRange(nil)
			if result.SourceLine != nil {
				text, ranges = trimHighlightedLine(*result.SourceLine, result.ContentMatchRanges)
			}
			a.highlightedText(c, text, ranges, a.colors.Text, 12, true)
			location := name
			if result.Line != nil {
				location += ":" + strconv.Itoa(*result.Line)
			}
			if folder != "" {
				location += "  " + folder
			}
			ui.Text(c, location).FontSize(11).Color(a.colors.Subtle).Ellipsis()
		})
		return
	}
	label := name
	if result.SymbolName != nil && *result.SymbolName != "" {
		label = *result.SymbolName
	}
	var ranges []core.SearchNameRange
	if selected {
		ranges = result.NameMatchRanges
	}
	ui.Row(c).Shrink(0).Children(func() { a.highlightedText(c, label, ranges, a.colors.Text, 13, false) })
	if result.Kind != "file" && result.Line != nil {
		ui.Text(c, ":"+strconv.Itoa(*result.Line)).Mono().FontSize(11).Color(a.colors.Subtle).Shrink(0)
	}
	if result.Kind != "file" {
		folder = result.Path
	}
	ui.Text(c, folder).Grow(1).Shrink(1).MinWidth(0).FontSize(13).Color(a.colors.Subtle).Ellipsis()
	if module := a.moduleName(p, result.Path); module != "" {
		ui.Text(c, module).FontSize(13).Color(a.colors.Subtle).Shrink(0)
	}
}

// highlightedText declares text as runs, the ranges Core marked (UTF-16 units) on
// the match color. Ranges that overlap, run backwards or leave the text are skipped.
func (a *App) highlightedText(c ui.C, text string, ranges []core.SearchNameRange, color gfx.Color, size float32, mono bool) {
	spans := utf16Spans(text, ranges)
	declare := func(part string, marked bool) {
		if part == "" {
			return
		}
		t := ui.Text(c, part).FontSize(size).Color(color)
		if mono {
			t.Mono()
		}
		if marked {
			t.Background(a.colors.Warning.WithAlpha(0.35))
		}
	}
	ui.Row(c).Shrink(1).MinWidth(0).Children(func() {
		cursor := 0
		for _, span := range spans {
			declare(text[cursor:span[0]], false)
			declare(text[span[0]:span[1]], true)
			cursor = span[1]
		}
		declare(text[cursor:], false)
	})
}

// utf16Spans turns ranges in UTF-16 code units into byte ranges of text, in order,
// dropping the ones that overlap an earlier range or do not fit.
func utf16Spans(text string, ranges []core.SearchNameRange) [][2]int {
	if len(ranges) == 0 {
		return nil
	}
	// offsets[u] is the byte offset of UTF-16 unit u, or -1 inside a surrogate pair.
	offsets := make([]int, 0, len(text)+1)
	for i, r := range text {
		offsets = append(offsets, i)
		if r >= 0x10000 {
			offsets = append(offsets, -1)
		}
	}
	offsets = append(offsets, len(text))
	var spans [][2]int
	last := 0
	for _, r := range ranges {
		start, end := r.Start, r.Start+r.Length
		if r.Length <= 0 || start < 0 || end >= len(offsets) || offsets[start] < 0 || offsets[end] < 0 || offsets[start] < last {
			continue
		}
		spans = append(spans, [2]int{offsets[start], offsets[end]})
		last = offsets[end]
	}
	return spans
}

// trimHighlightedLine drops the line's leading whitespace and moves the ranges with it.
func trimHighlightedLine(line string, ranges []core.SearchNameRange) (string, []core.SearchNameRange) {
	trimmed := strings.TrimLeft(line, " \t")
	removed := len(line) - len(trimmed) // spaces and tabs are one UTF-16 unit each
	out := make([]core.SearchNameRange, 0, len(ranges))
	for _, r := range ranges {
		if r.Start >= removed {
			out = append(out, core.SearchNameRange{Start: r.Start - removed, Length: r.Length})
		}
	}
	return strings.TrimRight(trimmed, "\r\n"), out
}

// searchResultMenu is the context menu of a search result, in Search Everywhere and in the
// Find in Files results: open it, show it in the file manager, or copy its path. The actions
// are recorded under surface; leave, when set, runs before the result opens.
func (a *App) searchResultMenu(c ui.C, target ui.Box, p *project, result core.WorkspaceSearchMatch, language i18n.Language, surface string, leave func()) {
	full, ok := everywhereResultPath(p, result)
	if !ok {
		return
	}
	ui.ContextMenu(c, target, func(menu *ui.MenuItems) {
		if menu.Item(i18n.Shared(language, "desktop.files.open")).Clicked() {
			c.After(func() {
				a.performed(surface+".openResult", surfaceMenu)
				if leave != nil {
					leave()
				}
				a.openSearchResult(p, result)
			})
		}
		if menu.Item(revealLabel(language)).Clicked() {
			c.After(func() {
				a.performed(surface+".reveal", surfaceMenu)
				a.revealPath(full)
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.files.copyPath")).Clicked() {
			a.performed(surface+".copyPath", surfaceMenu)
			a.copyTreePath(full, false)
		}
		if menu.Item(i18n.Shared(language, "desktop.files.copyRelativePath")).Clicked() {
			a.performed(surface+".copyRelativePath", surfaceMenu)
			a.copyTreePath(full, true)
		}
	})
}

// everywhereRetry asks again after a failure: the page that failed when results
// are already listed, the whole query otherwise.
func (a *App) everywhereRetry(c ui.C, p *project, language i18n.Language) {
	if !ui.Button(c.Key("everywhereRetry"), i18n.Shared(language, "desktop.everywhere.retry")).Outline().Disabled(p.everywhere.running).Clicked() {
		return
	}
	a.performed("workspace.searchEverywhere.retry", surfaceButton)
	c.After(func() {
		s := &p.everywhere
		if len(s.matches) > 0 && s.cursor != nil {
			s.failed = false
			a.runEverywhere(p, true)
		} else {
			// A changed identity makes the next declaration search again.
			s.query, s.scope = "", -1
		}
		a.focusEverywhere(p)
	})
}

// everywhereResultPath is the absolute path of a result inside the project.
func everywhereResultPath(p *project, result core.WorkspaceSearchMatch) (string, bool) {
	relative := filepath.FromSlash(result.Path)
	if relative == "" || filepath.IsAbs(relative) {
		return "", false
	}
	full := filepath.Join(p.root, relative)
	if _, inside := projectRelative(p.root, full); !inside {
		return "", false
	}
	return full, true
}

// everywhereKey moves the selection with the arrows, opens it with Enter and moves
// between the tabs with Tab and Shift-Tab while the keyboard is in the query field.
// A plain key typed in a text field is the field's, so the page cannot declare
// these as shortcuts.
func (a *App) everywhereKey(p *project, event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Target != everywhereQueryID {
		return gfx.EventResult{}
	}
	if input := a.root.TextInput(app.TextInputContext{ID: everywhereQueryID}); input != nil && input.Editor != nil {
		if _, composing := input.Editor.Composition(); composing {
			return gfx.EventResult{}
		}
	}
	v := &a.everywhereView
	if event.Key == gfx.KeyTab && (event.Modifiers == 0 || event.Modifiers == gfx.ModifierShift) {
		step := 1
		if event.Modifiers == gfx.ModifierShift {
			step = -1
		}
		v.scope = (v.scope + step + everywhereScopeCount) % everywhereScopeCount
		a.performed("workspace.searchEverywhere.scope", surfaceShortcut)
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers != 0 {
		return gfx.EventResult{}
	}
	if v.effectiveScope() == everywhereScopeActions {
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
