package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// referencesPanel declares the References tool window: the toolbar, the tree of usages and,
// beside it, the preview of the selected usage's file.
func (a *App) referencesPanel(c ui.C, p *project) {
	s := &a.editor.refs
	if s.project != p || len(s.targets) == 0 {
		a.panelMessage(c, i18n.Shared(a.language(), "desktop.references.empty"), a.colors.Subtle)
		return
	}
	lang := a.language()
	ui.Row(c).Fill().Clip().Children(func() {
		a.referencesToolbar(c, p, lang)
		ui.Divider(c)
		if s.hidePreview {
			ui.Column(c).Grow(1).Basis(0).Shrink(1).MinWidth(0).FillHeight().MinHeight(0).Children(func() { a.referencesTree(c, lang) })
			return
		}
		a.syncReferencePreview(p)
		if s.split.Pos <= 0 {
			s.split.Pos = referenceTreeWidth
		}
		ui.Row(c).Grow(1).Basis(0).Shrink(1).MinWidth(0).FillHeight().MinHeight(0).Children(func() {
			ui.Column(c).Width(s.split.Pos).Shrink(0).FillHeight().MinHeight(0).Children(func() { a.referencesTree(c, lang) })
			ui.Splitter(c, &s.split).Mins(referenceTreeMin, referencePreviewMin).Label(a.text.Panel.Resize)
			a.referencesPreviewPane(c, lang)
		})
	})
}

// referencesToolbar declares the column of actions left of the tree, as IDEA's Find tool window
// puts them: ask again, step to the previous or next usage, open or close every file's node, and
// turn the preview on or off.
func (a *App) referencesToolbar(c ui.C, p *project, lang i18n.Language) {
	s := &a.editor.refs
	ui.Column(c).FillHeight().Shrink(0).Gap(2).Pad(4).Children(func() {
		if _, clicked := a.toolIconButton(c.Part("rerun"), i18n.Shared(lang, "native.rerun"), icons.RotateCcw, false, s.queryDocument(p) == nil); clicked {
			c.After(func() {
				a.performed("editor.references.rerun", surfaceButton)
				a.rerunReferences(p)
			})
		}
		_, hasPrevious := s.stepTarget(false)
		if _, clicked := a.toolIconButton(c.Part("previous"), i18n.Shared(lang, "desktop.references.previousUsage"), icons.ArrowUp, false, !hasPrevious); clicked {
			c.After(func() {
				a.performed("editor.references.previous", surfaceButton)
				a.stepReference(false)
			})
		}
		_, hasNext := s.stepTarget(true)
		if _, clicked := a.toolIconButton(c.Part("next"), i18n.Shared(lang, "desktop.references.nextUsage"), icons.ArrowDown, false, !hasNext); clicked {
			c.After(func() {
				a.performed("editor.references.next", surfaceButton)
				a.stepReference(true)
			})
		}
		if _, clicked := a.toolIconButton(c.Part("expand"), i18n.Shared(lang, "outline.expandAll"), icons.ChevronsUpDown, false, false); clicked {
			c.After(func() { a.expandReferences(true) })
		}
		if _, clicked := a.toolIconButton(c.Part("collapse"), i18n.Shared(lang, "outline.collapseAll"), icons.ChevronsDownUp, false, false); clicked {
			c.After(func() { a.expandReferences(false) })
		}
		if _, clicked := a.toolIconButton(c.Part("preview"), i18n.Shared(lang, "desktop.references.showPreview"), icons.PanelRight, !s.hidePreview, false); clicked {
			show := s.hidePreview
			c.After(func() {
				a.performed("editor.references.preview", surfaceButton)
				a.setReferencePreview(show)
			})
		}
	})
}

// referencesTree declares the tree of usages. A click selects a row, and the preview follows it;
// a double click or Enter opens a usage, or opens or closes a node. With the preview off, a click
// on a usage opens it, as there is nothing else to show it.
func (a *App) referencesTree(c ui.C, lang i18n.Language) {
	s := &a.editor.refs
	if s.view.Node == nil {
		s.view.Node = s.node
		s.view.Key = s.key
		s.view.Label = func(i int) string { return a.referenceRowLabel(i) }
		s.view.RowHeight = treelist.RowHeight
		s.view.Indent = treelist.Indent
	}
	s.view.Disclosure = &components.TreeDisclosure{
		Collapsed: fileicons.TreeChevron(false, a.colors.Dark),
		Expanded:  fileicons.TreeChevron(true, a.colors.Dark),
		Size:      16,
	}
	a.syncReferenceSelection(c.Canvas())
	ui.Tree(c, &s.view, len(s.rows), s.view.Label, func(i int) {
		a.drawReferenceRow(c, i, lang)
	}).Scrollbars().Label(i18n.Shared(lang, "desktop.semantics.references")).Grow(1).FillWidth().MinHeight(0).PadY(treelist.PadY)
	if i, ok := s.view.Toggled(); ok && i < len(s.rows) {
		key := s.rows[i].Key
		c.After(func() { a.toggleReference(key) })
	}
	i, ok := s.view.Chosen()
	if !ok || i >= len(s.rows) {
		return
	}
	info, clicked := c.Canvas().ClickInfo()
	repeated := clicked && info.Clicks >= 2
	row := s.rows[i]
	// The row a click chose takes the keyboard, so the arrow keys go on from it.
	c.Canvas().RequestFocus(s.view.RowID(i))
	c.After(func() {
		if !s.selectRow(row.Key) {
			return // a node above it closed in this frame
		}
		if clicked && !repeated && (row.Kind != core.ReferenceRowUsage || !s.hidePreview) {
			return // a single click only selects
		}
		if row.Kind == core.ReferenceRowUsage {
			a.performed("editor.references.open", surfaceButton)
			a.openReference(s.targets[row.Shows])
			return
		}
		a.toggleReference(row.Key)
	})
}

// syncReferenceSelection makes the selection follow the keyboard: a row the arrow keys moved the
// focus to is selected. Only a move of the focus selects, so a selection the toolbar made stays
// while the focus is on another row. A selection asked to show is scrolled into view, and takes
// the keyboard when the tree has it.
func (a *App) syncReferenceSelection(canvas *gfx.Canvas) {
	s := &a.editor.refs
	focused := canvas.Focused()
	inTree := false
	if focused != s.focus || s.reveal {
		i, found := treelist.FocusedRow(&s.view, len(s.rows), focused)
		inTree = found
		if found && focused != s.focus {
			s.selected, s.selectedRow = s.rows[i].Key, i
		}
		s.focus = focused
	}
	selected := s.selectedRow
	if selected >= len(s.rows) {
		selected = -1
	}
	if s.reveal && selected >= 0 {
		if first, last := s.view.Visible(); selected < first || selected > last {
			s.view.ScrollTo(selected, ui.ListCenter)
			canvas.RequestFrame()
		}
		if inTree {
			canvas.RequestFocus(s.view.RowID(selected))
		}
		s.reveal = false
	}
	if s.view.Selected() != selected {
		s.view.Select(selected)
	}
}

// referenceRowLabel names row i to assistive technology: the Usages node with the number found, a
// file with its path and number of usages, or a usage with its file, line and text.
func (a *App) referenceRowLabel(i int) string {
	s := &a.editor.refs
	if i < 0 || i >= len(s.rows) {
		return ""
	}
	lang := a.language()
	switch r := s.rows[i]; r.Kind {
	case core.ReferenceRowRoot:
		return i18n.Shared(lang, "desktop.references.usages") + " " + referenceResults(lang, len(s.targets))
	case core.ReferenceRowFile:
		g := s.groups[referenceRowGroup(r)]
		return g.DisplayPath + " " + referenceUsages(lang, len(g.Indices))
	default:
		at := s.targets[r.Shows].Range.Start.Line + 1
		return s.groups[referenceRowGroup(r)].DisplayPath + ":" + strconv.Itoa(at) + " " + s.lines[r.Shows].Text
	}
}

// referenceResults is how many usages were found, as the Usages node and the preview say it.
func referenceResults(lang i18n.Language, n int) string {
	if n == 1 {
		return i18n.Shared(lang, "desktop.references.resultCountOne")
	}
	return i18n.SharedFormat(lang, "desktop.references.resultCount", map[string]string{"count": strconv.Itoa(n)})
}

// referenceUsages is how many usages a file holds.
func referenceUsages(lang i18n.Language, n int) string {
	if n == 1 {
		return i18n.Shared(lang, "desktop.references.usageCountOne")
	}
	return i18n.SharedFormat(lang, "desktop.references.usageCount", map[string]string{"count": strconv.Itoa(n)})
}

// drawReferenceRow declares what row i shows after its chevron: the Usages node in bold with the
// number found; a file's icon, name, folder and number of usages; or a usage's line number and
// line, the usage in bold. A usage row has no chevron, so it keeps the chevron's room empty and
// its text lines up under its file's icon.
func (a *App) drawReferenceRow(c ui.C, i int, lang i18n.Language) {
	s := &a.editor.refs
	switch r := s.rows[i]; r.Kind {
	case core.ReferenceRowRoot:
		ui.Text(c, i18n.Shared(lang, "desktop.references.usages")).FontSize(treeFontSize).Bold().Color(a.colors.Text).Shrink(0)
		ui.Text(c, referenceResults(lang, len(s.targets))).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0)
	case core.ReferenceRowFile:
		g := s.groups[referenceRowGroup(r)]
		ui.Icon(c, fileicons.ForFile(g.Name, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, g.Name).FontSize(treeFontSize).Color(a.colors.Text).Shrink(0)
		if g.Folder != "" {
			ui.Text(c, g.Folder).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(1).MinWidth(0).Ellipsis()
		}
		ui.Text(c, referenceUsages(lang, len(g.Indices))).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0)
	default:
		line := strconv.Itoa(s.targets[r.Shows].Range.Start.Line + 1)
		ui.Row(c).Shrink(1).MinWidth(0).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(treeChevron).Children(func() {
			ui.Text(c, line).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0)
			a.referenceLineText(c, s.lines[r.Shows])
		})
	}
}

// referenceLineText declares a usage's line in the editor's font, the usage in bold (semibold barely
// shows in a fixed-pitch face), cut short at the row's end.
func (a *App) referenceLineText(c ui.C, line core.ReferenceLine) {
	spans := utf16Spans(line.Text, line.Ranges)
	part := func(text string, bold bool) {
		if text == "" {
			return
		}
		t := ui.Text(c, text).Mono().FontSize(treeFontSize).Color(a.colors.Text)
		if bold {
			t.Weight(gfx.WeightBold).Shrink(0)
		} else {
			t.Shrink(1).MinWidth(0).Ellipsis()
		}
	}
	ui.Row(c).Shrink(1).MinWidth(0).Clip().Children(func() {
		cursor := 0
		for _, span := range spans {
			part(line.Text[cursor:span[0]], false)
			part(line.Text[span[0]:span[1]], true)
			cursor = span[1]
		}
		part(line.Text[cursor:], false)
	})
}

// referencesPreviewPane declares the preview of the selected usage's file: its name and how many
// usages it holds over the read-only source.
func (a *App) referencesPreviewPane(c ui.C, lang i18n.Language) {
	s := &a.editor.refs
	ui.Column(c).Grow(1).Basis(0).Shrink(1).MinWidth(0).FillHeight().MinHeight(0).Children(func() {
		if target, ok := s.shownTarget(); ok {
			g := s.groups[s.groupOf[target]]
			ui.Row(c).FillWidth().Height(treelist.RowHeight + 6).Shrink(0).Items(ui.Center).Gap(6).PadX(10).Children(func() {
				ui.Icon(c, fileicons.ForFile(g.Name, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
				ui.Text(c, g.Name).FontSize(treeFontSize).Color(a.colors.Accent).Shrink(0)
				if g.Folder != "" {
					ui.Text(c, g.Folder).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(1).MinWidth(0).Ellipsis()
				}
				ui.Spacer(c)
				ui.Text(c, referenceUsages(lang, len(g.Indices))).FontSize(treeFontSize).Color(a.colors.Subtle).Shrink(0)
			})
			ui.Divider(c)
		}
		a.sourcePreviewPane(c, &s.preview, "referencesPreview", i18n.Shared(lang, "desktop.references.previewEmpty"))
	})
}

// referencesSearchTab declares the header's tab of the shown answer, named for the symbol it was
// asked for, as IDEA's Find tool window names its tab, with the × that closes it. Closing the
// only tab closes the tool window, as IDEA does. The row takes the room a spacer would.
func (a *App) referencesSearchTab(c ui.C, p *project) {
	s := &a.editor.refs
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Height(panelHeaderHeight).Items(ui.Center).Gap(2).Clip().Children(func() {
		if s.project == p && len(s.targets) > 0 {
			lang := a.language()
			name := s.symbol
			if name == "" {
				name = i18n.Shared(lang, "desktop.references.usages")
			}
			k := c.Key("referencesSearch")
			chip := ui.Row(k).Height(rowHeight).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).PadSides(0, 2, 0, toolTabPad).
				Background(a.colors.TabIdle).Stroke(1, a.colors.TabIdleBorder).Radius(6).
				HitWith(ui.ID(k), name, gfx.HitOptions{Role: gfx.RoleTab, Selected: true, PosInSet: 1, SetSize: 1}).
				Tooltip(name)
			var closeButton ui.Box
			chip.Children(func() {
				ui.Text(c, name).Color(a.colors.Text).Ellipsis().Shrink(1)
				cc := k.Part("close")
				label := i18n.Shared(lang, "desktop.references.closeSearch")
				closeButton = ui.Row(cc).Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
					Radius(a.theme.Metrics.RadiusItem()).
					HitWith(ui.ID(cc), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
					Tooltip(label).
					Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
				closeButton.Children(func() {
					ui.Icon(cc, icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
						StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
				})
			})
			if closeButton.Clicked() {
				c.After(func() {
					a.performed("editor.references.close", surfaceButton)
					a.closeReferences()
					a.reduceChrome(core.SetChromeOpen(itemReferences, false))
				})
			}
		}
		ui.Spacer(c)
	})
}
