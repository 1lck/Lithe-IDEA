package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// symbolKindMarks are the letters that stand for the LSP SymbolKind values 1 to 26.
var symbolKindMarks = [...]string{
	"F", "M", "N", "P", "C", "m", "p", "f", "c", "E", "I", "ƒ", "v", "K", "S", "#", "B", "[", "O", "k", "0", "e", "S", "!", "±", "T",
}

// symbolKindMark is the letter of a symbol kind.
func symbolKindMark(kind int) string {
	if kind < 1 || kind > len(symbolKindMarks) {
		return "?"
	}
	return symbolKindMarks[kind-1]
}

// outlinePanel declares the Structure tool window: the tree of the selected file's symbols.
func (a *App) outlinePanel(c ui.C, p *project) {
	language := a.language()
	d := p.selectedDocument(p.docs.group)
	if d == nil {
		a.panelMessage(c, i18n.Shared(language, "desktop.outline.noFile"), a.colors.Subtle)
		return
	}
	s := &a.editor.outline
	if retry := a.outlineSync(p, d, a.now()); retry > 0 {
		c.Canvas().RequestFrameIn(retry)
	}
	switch {
	case !s.loaded && s.failed:
		a.panelMessage(c, i18n.Shared(language, "desktop.outline.unavailable"), a.colors.Subtle)
		return
	case !s.loaded:
		a.panelMessage(c, i18n.Shared(language, "desktop.outline.loading"), a.colors.Subtle)
		return
	case len(s.symbols) == 0:
		a.panelMessage(c, i18n.Shared(language, "desktop.outline.empty"), a.colors.Subtle)
		return
	}
	if s.view.Node == nil {
		s.view.Node = func(i int) ui.TreeNode {
			row := s.rows[i]
			return ui.TreeNode{Depth: row.depth, Branch: len(row.symbol.Children) > 0, Expanded: !s.collapsed[row.key], Selected: i == s.selected}
		}
		s.view.RowHeight, s.view.Indent = treelist.RowHeight, treelist.Indent
	}
	if s.rowsDirty || s.rows == nil {
		s.buildRows()
	}
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).FillWidth().Height(28).Shrink(0).Items(ui.Center).Gap(4).PadX(8).Children(func() {
			ui.Spacer(c)
			if _, clicked := a.toolIconButton(c, i18n.Shared(language, "desktop.outline.sort"), icons.ArrowUpDown, s.sorted, false); clicked {
				c.After(func() { s.sorted = !s.sorted; s.rowsDirty = true })
			}
		})
		a.followOutlineCaret(c, d)
		ui.Tree(c, &s.view, len(s.rows),
			func(i int) string { return s.rows[i].symbol.Name },
			func(i int) { a.outlineRowContent(c, s.rows[i]) },
		).Label(a.text.Tools.Structure).Grow(1).FillWidth().PadY(treelist.PadY)
	})
	if i, ok := s.view.Toggled(); ok && i < len(s.rows) {
		key := s.rows[i].key
		c.After(func() { s.collapsed[key] = !s.collapsed[key]; s.rowsDirty = true })
	}
	if i, ok := s.view.Chosen(); ok && i < len(s.rows) {
		symbol := s.rows[i].symbol
		c.After(func() { a.outlineGo(p, d, symbol) })
	}
}

// followOutlineCaret selects the row of the symbol the caret is in, once the caret has moved
// or a new answer came, and brings it into view.
func (a *App) followOutlineCaret(c ui.C, d *document) {
	s := &a.editor.outline
	line, column := d.view.CaretUTF16()
	if !s.follow && line == s.caretLine && column == s.caretColumn {
		return
	}
	s.caretLine, s.caretColumn, s.follow = line, column, false
	row := s.caretRow(line, column)
	if row == s.selected {
		return
	}
	s.selected = row
	s.view.Select(row)
	if row >= 0 {
		if first, last := s.view.Visible(); row < first || row > last {
			s.view.ScrollTo(row, ui.ListCenter)
			c.Canvas().RequestFrame()
		}
	}
}

// outlineGo puts the caret on a symbol's name and gives the keyboard back to the editor.
func (a *App) outlineGo(p *project, d *document, symbol *core.DocumentSymbol) {
	start := symbol.SelectionRange.Start
	a.openFileAtPosition(p, d.path, start.Line, start.UTF16Column)
	a.focusDocument(d.id)
}

// outlineRowContent declares what a row shows after its chevron: the kind's mark, the name and
// the server's detail. A deprecated symbol is struck through.
func (a *App) outlineRowContent(c ui.C, row outlineRow) {
	symbol := row.symbol
	ui.Text(c, symbolKindMark(symbol.Kind)).FontSize(11).Bold().Width(16).TextCenter().Shrink(0).Color(a.colors.Subtle)
	name := ui.Text(c, symbol.Name).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
	if symbol.Deprecated {
		name.Color(a.colors.Subtle)
	}
	if symbol.Detail != nil && *symbol.Detail != "" {
		ui.Text(c, *symbol.Detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Shrink(1).Ellipsis()
	}
}

var _ = gfx.Color{}
