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

// symbolFamily groups the symbol kinds that share a badge color, so a type, a function and a
// field are told apart at a glance whatever letter the kind has.
type symbolFamily int

const (
	familyValue symbolFamily = iota
	familyType
	familyInterface
	familyEnum
	familyFunction
	familyField
	familyModule
)

// symbolFamilies maps the LSP SymbolKind values 1 to 26 to their family.
var symbolFamilies = [...]symbolFamily{
	familyModule, familyModule, familyModule, familyModule, // File, Module, Namespace, Package
	familyType,               // Class
	familyFunction,           // Method
	familyField, familyField, // Property, Field
	familyFunction,           // Constructor
	familyEnum,               // Enum
	familyInterface,          // Interface
	familyFunction,           // Function
	familyField, familyField, // Variable, Constant
	familyValue, familyValue, familyValue, familyValue, // String, Number, Boolean, Array
	familyType,      // Object
	familyField,     // Key
	familyValue,     // Null
	familyEnum,      // EnumMember
	familyType,      // Struct
	familyFunction,  // Event
	familyFunction,  // Operator
	familyInterface, // TypeParameter
}

// symbolFamilyColors are each family's badge color in the light and the dark theme, the hues
// IDEA gives the same kinds.
var symbolFamilyColors = [...][2]uint32{
	familyValue:     {0x6C707E, 0x9DA0A8},
	familyType:      {0x3574F0, 0x548AF7},
	familyInterface: {0x208A3C, 0x5FAD65},
	familyEnum:      {0xC27D04, 0xD6AE58},
	familyFunction:  {0xD1477A, 0xE07FA6},
	familyField:     {0x8452CF, 0xA97BE0},
	familyModule:    {0x2A8C93, 0x4FB3B9},
}

// symbolKindColor is the badge color of a symbol kind.
func symbolKindColor(kind int, dark bool) gfx.Color {
	family := familyValue
	if kind >= 1 && kind <= len(symbolFamilies) {
		family = symbolFamilies[kind-1]
	}
	if dark {
		return gfx.RGB24(symbolFamilyColors[family][1])
	}
	return gfx.RGB24(symbolFamilyColors[family][0])
}

// outlineActions declares the Structure window's header buttons: sort by name, follow the caret,
// unfold all and fold all. They act on the symbols shown, so they wait for an answer; folding
// waits for the filter to be cleared too, because a filter shows every match unfolded.
func (a *App) outlineActions(c ui.C, p *project) {
	language := a.language()
	s := &a.editor.outline
	d := p.selectedDocument(p.docs.group)
	ready := d != nil && s.project == p && s.documentID == d.id && s.loaded && len(s.symbols) > 0
	ui.Row(c).Shrink(0).Items(ui.Center).Gap(2).Children(func() {
		if _, hit := a.toolIconButton(c.Part("sort"), i18n.Shared(language, "desktop.outline.sort"), icons.ArrowUpDown, s.sorted, !ready); hit {
			c.After(func() {
				a.performed("outline.sort", surfaceButton)
				s.sorted, s.rowsDirty = !s.sorted, true
			})
		}
		if _, hit := a.toolIconButton(c.Part("follow"), i18n.Shared(language, "desktop.outline.follow"), icons.Locate, !s.still, !ready); hit {
			c.After(func() {
				a.performed("outline.followCaret", surfaceButton)
				s.still = !s.still
				s.follow = !s.still
			})
		}
		foldable := ready && !s.filtering()
		if _, hit := a.toolIconButton(c.Part("expand"), i18n.Shared(language, "outline.expandAll"), icons.ChevronsUpDown, false, !foldable); hit {
			c.After(func() {
				a.performed("outline.expandAll", surfaceButton)
				s.setAllCollapsed(false)
			})
		}
		if _, hit := a.toolIconButton(c.Part("collapse"), i18n.Shared(language, "outline.collapseAll"), icons.ChevronsDownUp, false, !foldable); hit {
			c.After(func() {
				a.performed("outline.collapseAll", surfaceButton)
				s.setAllCollapsed(true)
			})
		}
	})
}

// outlinePanel declares the Structure tool window: the tree of the selected file's symbols under
// a filter field, or why there is none.
func (a *App) outlinePanel(c ui.C, p *project) {
	language := a.language()
	d := p.selectedDocument(p.docs.group)
	if d == nil {
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.noFile"), "", nil)
		return
	}
	s := &a.editor.outline
	if retry := a.outlineSync(p, d, a.now()); retry > 0 {
		c.Canvas().RequestFrameIn(retry)
	}
	if !s.loaded {
		a.outlineStatus(c, s)
		return
	}
	if len(s.symbols) == 0 {
		empty := i18n.Shared(language, "desktop.outline.empty")
		if s.availability == outlineMarkdown {
			empty = i18n.Shared(language, "desktop.outline.noHeadings")
		}
		a.outlineNotice(c, empty, "", nil)
		return
	}
	if s.view.Node == nil {
		s.view.Node = func(i int) ui.TreeNode {
			row := s.rows[i]
			return ui.TreeNode{Depth: row.depth, Branch: len(row.symbol.Children) > 0, Expanded: s.expanded(row), Selected: i == s.selected}
		}
		s.view.Key = func(i int) int { return s.rows[i].id }
		s.view.RowHeight, s.view.Indent = treelist.RowHeight, treelist.Indent
	}
	a.syncOutlineSelection(c.Canvas())
	ui.Column(c).Fill().Children(func() {
		a.outlineFilter(c, s)
		if len(s.rows) == 0 {
			a.outlineNotice(c, i18n.Shared(language, "outline.noSymbolsFound"), "", nil)
			return
		}
		if !s.still {
			a.followOutlineCaret(c, d)
		}
		s.view.Disclosure = &components.TreeDisclosure{
			Collapsed: fileicons.TreeChevron(false, a.colors.Dark),
			Expanded:  fileicons.TreeChevron(true, a.colors.Dark),
			Size:      16,
		}
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
		c.After(func() {
			s.selected = i
			a.outlineGo(p, d, symbol)
		})
	}
}

// outlineStatus declares why the symbols are not shown yet: no server serves the file, it is
// starting or not running, it lacks document symbols, a Markdown file is too large, the request
// failed, or the answer is on its way.
func (a *App) outlineStatus(c ui.C, s *outlineState) {
	language := a.language()
	switch {
	case s.availability == outlineMarkdown && s.tooLarge:
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.tooLarge"), "", nil)
	case s.failed && (s.availability == outlineAsk || s.availability == outlineMarkdown):
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.failed"), "", func() {
			if ui.Button(c, i18n.Shared(language, "ui.retry")).Outline().Small().Clicked() {
				c.After(func() {
					a.performed("outline.retry", surfaceButton)
					s.retry()
				})
			}
		})
	case s.availability == outlineNoServer:
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.unavailable"), i18n.Shared(language, "desktop.outline.noServerHint"), nil)
	case s.availability == outlineStarting:
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.starting"), "", nil)
	case s.availability == outlineServerDown:
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.serverDown"), i18n.Shared(language, "desktop.outline.serverDownHint"), nil)
	case s.availability == outlineUnsupported:
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.unsupported"), "", nil)
	default:
		a.outlineNotice(c, i18n.Shared(language, "desktop.outline.loading"), "", nil)
	}
}

// outlineNotice declares the centered message that stands in for the tree: the Structure icon,
// the message, an optional hint below it and an optional action below that.
func (a *App) outlineNotice(c ui.C, message, hint string, action func()) {
	ui.Column(c).Fill().Center().Gap(8).PadX(shellContentPad).Children(func() {
		ui.Icon(c, icons.ListTree).Size(28, 28).Shrink(0).Color(a.colors.Subtle).Opacity(0.6)
		ui.Paragraph(c, message, 3).TextCenter().Color(a.colors.Text)
		if hint != "" {
			ui.Paragraph(c, hint, 4).TextCenter().FontSize(treeFontSize - 1).Color(a.colors.Subtle)
		}
		if action != nil {
			action()
		}
	})
}

// outlineFilter declares the field that filters the symbols by name, with the count of matches
// after it while a filter is in effect. The field takes the typed text while it is declared, so
// the rows are rebuilt after it: the tree of this frame already shows what was typed.
func (a *App) outlineFilter(c ui.C, s *outlineState) {
	language := a.language()
	label := i18n.Shared(language, "desktop.outline.filter")
	ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadSides(6, 8, 4, 8).Children(func() {
		field := ui.TextField(c, &s.filter, label, label).Icon(icons.Search).Grow(1).MinWidth(0)
		if s.filter != "" {
			field = field.Action(icons.X, i18n.Shared(language, "native.clearSearch"))
			if field.ActionClicked() {
				c.After(func() {
					a.performed("outline.filter.clear", surfaceButton)
					s.filter = ""
				})
			}
		}
		if s.refresh() && s.view.Selected() != s.selected {
			s.view.Select(s.selected)
		}
		if s.filtering() {
			ui.Text(c, i18n.SharedFormat(language, "desktop.outline.matches", map[string]string{
				"matches": strconv.Itoa(s.matches), "total": strconv.Itoa(s.total),
			})).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Shrink(0)
		}
	})
}

// syncOutlineSelection takes over the row the arrow keys moved the focus to, so the highlight
// follows the keyboard as it does a click. Only the declared rows can hold the focus.
func (a *App) syncOutlineSelection(canvas *gfx.Canvas) {
	s := &a.editor.outline
	focused := canvas.Focused()
	if focused.IsZero() {
		return
	}
	first, last := s.view.Visible()
	for i := max(first-treeOverscan, 0); i <= last+treeOverscan && i < len(s.rows); i++ {
		if s.view.RowID(i) == focused {
			s.selected = i
			return
		}
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

// outlineGo puts the caret on a symbol's name and gives the keyboard back to the editor; a
// Markdown page shown alone also scrolls the heading to its top.
func (a *App) outlineGo(p *project, d *document, symbol *core.DocumentSymbol) {
	start := symbol.SelectionRange.Start
	a.openFileAtPosition(p, d.path, start.Line, start.UTF16Column)
	a.focusDocument(d.id)
	// The editor of a page shown alone is hidden, so the page is what has to move.
	if s := d.markdown; s != nil && d.pageMode == pageOnly {
		s.showLine(d, start.Line)
	}
}

// outlineRowContent declares what a row shows after its chevron: the kind's badge, the name and
// the server's detail. A leaf keeps the chevron's room empty, so its badge lines up with the
// badges of the branches beside it. A deprecated symbol, and a row the filter keeps only for a
// match below it, is drawn muted.
func (a *App) outlineRowContent(c ui.C, row outlineRow) {
	content := func() {
		symbol := row.symbol
		a.symbolBadge(c, symbol.Kind)
		name := ui.Text(c, symbol.Name).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
		if symbol.Deprecated || !row.match {
			name.Color(a.colors.Subtle)
		}
		if symbol.Detail != nil && *symbol.Detail != "" {
			ui.Text(c, *symbol.Detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Shrink(1).Ellipsis()
		}
	}
	if len(row.symbol.Children) > 0 {
		content()
		return
	}
	ui.Row(c).Shrink(1).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(treeChevron).Children(content)
}

// symbolBadge declares the kind's letter on a tinted square of its family's color.
func (a *App) symbolBadge(c ui.C, kind int) {
	color := symbolKindColor(kind, a.colors.Dark)
	tint := float32(0.14)
	if a.colors.Dark {
		tint = 0.22
	}
	ui.Row(c).Size(treelist.Icon, treelist.Icon).Shrink(0).Center().Radius(4).Background(color.WithAlpha(tint)).Children(func() {
		ui.Text(c, symbolKindMark(kind)).FontSize(10).Weight(gfx.WeightBold).Color(color)
	})
}
