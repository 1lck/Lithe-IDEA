package logwindow

import (
	"errors"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// The identities of the table: the table itself, its scrolling area and its header, and
// one scope for each kind of control that is repeated.
var (
	tableScope    = tree.Sub(page, tree.Name("table"))
	tableID       = tree.ID(tableScope, "table")
	tableScrollID = tree.ID(tableScope, "scroll")
	tableHeaderID = tree.ID(tableScope, "header")

	// tableResizeScope holds the drag handle at the trailing edge of each header cell,
	// numbered by column. tableRowsScope holds the rows, numbered by their position in the
	// displayed rows. tableMessagesScope and tableRunsScope hold the parts of a folded run's
	// message cell, numbered like the rows. tableFieldsScope holds the clickable field
	// values; its number is the row position times tableFieldSlots plus the field's place
	// among the row's sorted keys.
	tableResizeScope   = tree.Sub(tableScope, tree.Name("resize"))
	tableRowsScope     = tree.Sub(tableScope, tree.Name("rows"))
	tableMessagesScope = tree.Sub(tableScope, tree.Name("messages"))
	tableRunsScope     = tree.Sub(tableScope, tree.Name("runs"))
	tableFieldsScope   = tree.Sub(tableScope, tree.Name("fields"))

	// The items of the table's context menus.
	tableMenuScope        = tree.Sub(page, tree.Name("table-menu"))
	tableMenuCopyLine     = tree.ID(tableMenuScope, "copy-line")
	tableMenuCopyMarkdown = tree.ID(tableMenuScope, "copy-markdown")
	tableMenuShowEvent    = tree.ID(tableMenuScope, "show-event")
	tableMenuHideEvent    = tree.ID(tableMenuScope, "hide-event")
	tableMenuShowChannel  = tree.ID(tableMenuScope, "show-channel")
	tableMenuTrace        = tree.ID(tableMenuScope, "trace")
	tableMenuCopyField    = tree.ID(tableMenuScope, "copy-field")
	tableColumnItems      = tree.Sub(tableMenuScope, tree.Name("columns"))
	tableFieldItems       = tree.Sub(tableMenuScope, tree.Name("field-values"))
)

// The metrics of the table, after the macOS table: rows are 22 points tall, the header 26,
// and columns are 10 points apart, which is 5 points of padding on each side of a cell.
const (
	tableRowHeight    = 22
	tableHeaderHeight = 26
	tableCellSpacing  = 10
	tableCellPad      = 5
	// tableMinCell is the narrowest a cell gets when the table is narrower than its
	// columns: the smallest column plus its spacing.
	tableMinCell = minColumnWidth + tableCellSpacing
	// tableOverscan is how many rows are declared above and below the visible ones.
	tableOverscan = 2
	// tableFallbackViewport is the height assumed for the scrolling area before it has been
	// laid out once.
	tableFallbackViewport = 1200
	// tableHandleWidth is the width of the strip at a header cell's trailing edge that
	// resizes the column.
	tableHandleWidth = 8

	// The text sizes.
	tableCellFont   = 12.5
	tableSmallFont  = 11.5
	tableHeaderFont = 11

	// The channel chip.
	tableChipHeight = 16
	tableChipRadius = 3
	tableChipFill   = 0.15

	// The badge of a folded run, the offset of the message after it, and the width of the
	// zone at the start of the cell in which a click folds or unfolds the run.
	tableBadgeWidth  = 43
	tableBadgeHeight = 16
	tableBadgeRadius = 8
	tableTextOffset  = 48
	tableFoldWidth   = 65

	// tableStripeWidth is the width of the bar at the start of a selected or related row.
	tableStripeWidth = 2
	// tableHighlightAlpha is the opacity of the mark behind a matched filter text.
	tableHighlightAlpha = 0.3
	// tableFieldSlots bounds the fields of one row that can be clicked.
	tableFieldSlots = 256

	// The widths of the context menus.
	tableHeaderMenuWidth = 150
	tableRowMenuWidth    = 220
	tableSubmenuWidth    = 140
)

// The columns of the table, in the order of the columns variable.
const (
	tableColSeq = iota
	tableColTime
	tableColLevel
	tableColChannel
	tableColEvent
	tableColMessage
	tableColFields
	tableColumnCount
)

// tableDefaultWidths are the widths of the columns the user never resized.
var tableDefaultWidths = [tableColumnCount]float32{52, 96, 62, 170, 230, 160, 300}

// tableState is what the table keeps from one frame to the next.
type tableState struct {
	// A drag of a header cell's resize handle. The columns keep the widths they had when the
	// drag began (frozen) except the dragged one, which follows the pointer; the widths are
	// adopted when the drag ends.
	dragging       bool
	dragColumn     int
	dragStartX     float32
	dragStartWidth float32
	dragWidth      float32
	frozen         [tableColumnCount]float32

	// revision is the scroll revision of the model the table has acted on, valid once
	// revisionSeen is set.
	revisionSeen bool
	revision     int
	// toEnd asks the next frame to scroll to the end (the End key).
	toEnd bool

	// cursor is the row the arrow keys move from, and reveal the row the next frame scrolls
	// into view after a key moved to it.
	cursor string
	reveal string

	// topID is the row at the top of the area, topIndex its position and topFrac how far its
	// top is scrolled out of view. When rows appear or disappear above it the area scrolls to
	// keep it where it was. topID is empty while the area follows the end.
	topIndex int
	topID    string
	topFrac  float32
}

// tableGrid is the columns the table shows and their base widths, read from the model's
// preferences. A base width is the width the user chose; the columns that expand show it
// plus a share of the width the table has left over.
type tableGrid struct {
	// visible lists the shown columns left to right, by index into columns; count is how
	// many there are.
	visible [tableColumnCount]int
	count   int
	// base is the base width of each column.
	base [tableColumnCount]float32
	// expanding marks the columns that share the spare width.
	expanding [tableColumnCount]bool
}

// gridOfColumns reads the visible columns and their widths. Event, message and fields
// expand; with all three hidden the last visible column does.
func (w *window) gridOfColumns() tableGrid {
	var grid tableGrid
	flexible := false
	for i := 0; i < tableColumnCount && i < len(columns); i++ {
		if w.model.columnHidden(columns[i]) {
			continue
		}
		grid.visible[grid.count] = i
		grid.count++
		grid.base[i] = float32(columnWidth(w.model.columnWidthOf(columns[i], float64(tableDefaultWidths[i]))))
		if i == tableColEvent || i == tableColMessage || i == tableColFields {
			grid.expanding[i] = true
			flexible = true
		}
	}
	if !flexible && grid.count > 0 {
		grid.expanding[grid.visible[grid.count-1]] = true
	}
	return grid
}

// fit is the width each visible column shows in a table viewport wide. A fixed column shows
// its base width; the expanding columns share what the viewport has left after every base
// width and spacing, in proportion to their base widths. A table narrower than its columns
// shows the base widths.
func (g *tableGrid) fit(viewport float32) [tableColumnCount]float32 {
	var widths [tableColumnCount]float32
	var baseline, weight float32
	for _, i := range g.visible[:g.count] {
		baseline += g.base[i] + tableCellSpacing
		if g.expanding[i] {
			weight += g.base[i]
		}
	}
	spare := max(0, viewport-baseline)
	for _, i := range g.visible[:g.count] {
		widths[i] = g.base[i]
		if g.expanding[i] {
			widths[i] += spare * g.base[i] / max(1, weight)
		}
	}
	return widths
}

// adopt turns the width a drag left a column at into base widths, so the next fit shows the
// column where the user released it. It returns the base widths that changed; a column that
// did not change is zero. Saving the released width of an expanding column as its base would
// add its share of the spare width again on top, so for those the base is solved from the
// released width and the other expanding bases.
func (g *tableGrid) adopt(column int, released, viewport float32) [tableColumnCount]float32 {
	var changed [tableColumnCount]float32
	if !g.expanding[column] {
		changed[column] = released
		return changed
	}
	var otherBases float32
	shared := viewport
	for _, i := range g.visible[:g.count] {
		shared -= tableCellSpacing
		if !g.expanding[i] {
			shared -= g.base[i]
		} else if i != column {
			otherBases += g.base[i]
		}
	}
	// With base b, shared width S and the other expanding bases B, the column shows
	// b*S/(b+B) while b+B is below S, and b otherwise. A lone expanding column always fills
	// the row, and a release past S-B leaves no spare width: in both cases the base is the
	// released width.
	if otherBases <= 0 || released >= shared-otherBases {
		changed[column] = released
		return changed
	}
	exact := released * otherBases / (shared - released)
	if exact >= minColumnWidth {
		changed[column] = exact
		return changed
	}
	// The base cannot go below the minimum width. Keep the released layout by giving the
	// other expanding columns proportionally larger bases.
	scale := minColumnWidth / exact
	changed[column] = minColumnWidth
	for _, i := range g.visible[:g.count] {
		if i != column && g.expanding[i] {
			changed[i] = g.base[i] * scale
		}
	}
	return changed
}

// applyColumnWidths remembers the widths a drag adopted. The preferences file is written once,
// with the last of them.
func (w *window) applyColumnWidths(changed [tableColumnCount]float32) {
	last := -1
	for i, width := range changed {
		if width > 0 {
			last = i
		}
	}
	for i, width := range changed {
		if width > 0 {
			w.model.setColumnWidth(columns[i], float64(width), i == last)
		}
	}
}

// tableWidths are the widths the columns show now: the frozen ones while a header drag is
// in progress, and the fitted ones otherwise.
func (w *window) tableWidths(grid *tableGrid, viewport float32) [tableColumnCount]float32 {
	t := &w.table
	if t.dragging {
		widths := t.frozen
		widths[t.dragColumn] = t.dragWidth
		return widths
	}
	return grid.fit(viewport)
}

// tableColumnTitle is the title of a column. The title of the sequence column is the same
// in every language.
func (w *window) tableColumnTitle(column int) string {
	m := w.text.Logs
	switch column {
	case tableColSeq:
		return "#"
	case tableColTime:
		return m.Time
	case tableColLevel:
		return m.Level
	case tableColChannel:
		return m.Channel
	case tableColEvent:
		return m.Event
	case tableColMessage:
		return m.Message
	}
	return m.Fields
}

// sizeTableCell sizes a cell of a header or of a row the way the columns lay out: a cell is
// its column's base width plus the spacing, and the expanding columns also grow in
// proportion to their base widths to fill the table, which is the share fit computes. While
// a header drag is in progress every cell keeps a fixed width.
func (w *window) sizeTableCell(cell ui.Box, grid *tableGrid, column int, height float32) ui.Box {
	cell = cell.Height(height).PadX(tableCellPad).Clip().Items(ui.Center)
	if t := &w.table; t.dragging {
		width := t.frozen[column]
		if column == t.dragColumn {
			width = t.dragWidth
		}
		return cell.Width(width + tableCellSpacing).Grow(0).Shrink(0)
	}
	cell = cell.Width(grid.base[column] + tableCellSpacing)
	if grid.expanding[column] {
		return cell.Grow(grid.base[column]).Shrink(1).MinWidth(tableMinCell)
	}
	return cell.Shrink(0)
}

// drawTable is the table: the header and the rows of the model, which are virtualized so
// only the visible ones are declared. The area follows the end of the log while the model
// follows it, scrolls to the row the model asks for, and keeps the row at its top where it
// was when rows appear above it.
func (w *window) drawTable(f *ui.Frame) {
	m := w.model
	t := &w.table
	canvas := f.Canvas()
	// The table is the window less the channel list and its divider. The layout does not
	// say how wide an element was in an earlier frame, so the widths the columns show are
	// worked out from this.
	viewport := f.Bounds().Width - sidebarWidth - 1

	grid := w.gridOfColumns()
	w.trackHeader(canvas, &grid, viewport)
	w.trackRows(canvas)
	grid = w.gridOfColumns()
	widths := w.tableWidths(&grid, viewport)
	rows := m.displayRows()
	n := len(rows)

	// Scroll before the area is declared: it reads its offset when declared.
	s := w.view.ScrollState(tableScrollID)
	toEnd, scrolled := false, false
	if t.toEnd {
		t.toEnd = false
		s.ScrollToEnd()
		toEnd = true
	}
	if !t.revisionSeen || t.revision != m.scrollRevision {
		t.revisionSeen, t.revision = true, m.scrollRevision
		if m.scrollTarget == "" {
			s.ScrollToEnd()
			toEnd = true
		} else if i := tableRowIndex(rows, m.scrollTarget); i >= 0 {
			scrolled = tableReveal(s, i) || scrolled
		}
	}
	if t.reveal != "" {
		id := t.reveal
		t.reveal = ""
		if i := tableRowIndex(rows, id); i >= 0 {
			scrolled = tableReveal(s, i) || scrolled
		}
	}
	atEnd := toEnd || (m.follows && (s.AtEnd() || s.Content <= 0))
	if !atEnd && !scrolled && t.topID != "" && !(t.topIndex < n && rows[t.topIndex].id == t.topID) {
		if i := tableRowIndex(rows, t.topID); i >= 0 {
			s.ScrollTo(float32(i)*tableRowHeight + t.topFrac)
		}
	}
	// A table that follows the log and finds itself away from its end was scrolled by
	// something other than the wheel, such as the scroll bar: following stops.
	if !toEnd && m.follows && s.Viewport > 0 && s.Content > 0 && !s.AtEnd() {
		m.userScrolledUp()
		atEnd = false
	}

	height := s.Viewport
	if height <= 0 {
		height = tableFallbackViewport
	}
	offset := s.Offset
	if atEnd && m.follows || toEnd {
		// The area is about to sit at its end, with rows the last layout did not have.
		offset = max(0, float32(n)*tableRowHeight-height)
	}
	if atEnd && m.follows || toEnd || n == 0 {
		t.topID = ""
	} else {
		top := min(n-1, max(0, int(offset/tableRowHeight)))
		t.topIndex, t.topID = top, rows[top].id
		t.topFrac = min(tableRowHeight, max(0, offset-float32(top)*tableRowHeight))
	}
	first := max(0, int(offset/tableRowHeight)-tableOverscan)
	last := min(n, int((offset+height)/tableRowHeight)+tableOverscan+1)
	first = min(first, last)

	paint := tableRowPaint{}
	paint.cellW, _ = canvas.MonoCellSize(tableCellFont, gfx.MonoSystem)
	if record, ok := m.selectedRecord(); ok {
		paint.hasSelected, paint.selectedOp, paint.selectedEpoch = true, record.Op, record.EpochMs
	}
	for _, term := range m.terms {
		if term.Kind == "text" && !term.Negate && term.Value != "" {
			paint.needles = append(paint.needles, []rune(term.Value))
		}
	}

	f.Column().Fill().HitWith(tableID, w.text.Logs.Logs, gfx.HitOptions{Role: gfx.RoleGrid, SkipFocus: true}).Children(func() {
		w.drawTableHeader(f, &grid)
		f.ScrollArea(tableScrollID).Grow(1).Shrink(1).MinHeight(0).FillWidth().Follow(m.follows).Children(func() {
			if first > 0 {
				f.Row().Height(float32(first) * tableRowHeight).Shrink(0)
			}
			for i := first; i < last; i++ {
				w.drawTableRow(f, i, rows, &grid, &widths, &paint)
			}
			if rest := n - last; rest > 0 {
				f.Row().Height(float32(rest) * tableRowHeight).Shrink(0)
			}
		})
	})
}

// tableReveal scrolls the area the least that shows the whole row at index, the way a native
// table scrolls a row to visible. It reports whether it scrolled.
func tableReveal(s *ui.ScrollState, index int) bool {
	top := float32(index) * tableRowHeight
	bottom := top + tableRowHeight
	switch {
	case s.Viewport <= 0 || top < s.Offset:
		s.ScrollTo(top)
	case bottom > s.Offset+s.Viewport:
		s.ScrollTo(bottom - s.Viewport)
	default:
		return false
	}
	return true
}

// tableRowIndex is the position of the row with the given id, or -1.
func tableRowIndex(rows []displayRow, id string) int {
	for i, row := range rows {
		if row.id == id {
			return i
		}
	}
	return -1
}

// tableScrolled follows a scroll of the wheel: a table that follows the log and is no longer
// at its end pauses following. Scrolling back down does not resume it; the capsule over the
// table does.
func (w *window) tableScrolled() {
	if !w.model.follows {
		return
	}
	if !w.view.ScrollState(tableScrollID).AtEnd() {
		w.model.userScrolledUp()
	}
}

// trackHeader handles the pointer on the header: a press of the secondary button opens the
// menu of columns, and the primary button on a cell's handle drags the column's width.
func (w *window) trackHeader(canvas *gfx.Canvas, grid *tableGrid, viewport float32) {
	t := &w.table
	if ev, ok := canvas.PointerOn(tableHeaderID); ok && ev.Kind == gfx.PointerDown && ev.Button == gfx.PointerButtonSecondary {
		w.openContextMenu(menuHeader, ev.X, ev.Y, "")
		canvas.Consume()
	}
	column, ev, ok := canvas.PointerIn(tableResizeScope)
	if !ok || column < 0 || column >= tableColumnCount {
		return
	}
	switch ev.Kind {
	case gfx.PointerDown:
		switch ev.Button {
		case gfx.PointerButtonPrimary:
			t.dragging = true
			t.dragColumn = column
			t.dragStartX = ev.X
			t.frozen = grid.fit(viewport)
			t.dragStartWidth = t.frozen[column]
			t.dragWidth = t.dragStartWidth
			canvas.Consume()
		case gfx.PointerButtonSecondary:
			w.openContextMenu(menuHeader, ev.X, ev.Y, "")
			canvas.Consume()
		}
	case gfx.PointerMove:
		if t.dragging && column == t.dragColumn {
			t.dragWidth = min(maxColumnWidth, max(minColumnWidth, t.dragStartWidth+ev.X-t.dragStartX))
			canvas.Consume()
		}
	case gfx.PointerUp, gfx.PointerExit:
		if !t.dragging {
			return
		}
		t.dragging = false
		if t.dragWidth != t.dragStartWidth {
			w.applyColumnWidths(grid.adopt(t.dragColumn, t.dragWidth, viewport))
		}
		canvas.Consume()
	}
}

// trackRows handles the pointer on the rows. A press of the primary button on the fold zone
// of a run folds or unfolds it, on a field value adds the field to the filter, and elsewhere
// on a row selects it (⌘ or Ctrl adds the row, ⇧ extends from the anchor). A press of the
// secondary button selects a row that is not selected and opens its menu.
func (w *window) trackRows(canvas *gfx.Canvas) {
	m := w.model
	if i, ev, ok := canvas.PointerIn(tableRowsScope); ok {
		w.pressRow(canvas, i, ev)
	}
	if i, ev, ok := canvas.PointerIn(tableMessagesScope); ok {
		w.pressRow(canvas, i, ev)
	}
	if i, ev, ok := canvas.PointerIn(tableRunsScope); ok && ev.Kind == gfx.PointerDown {
		rows := m.displayRows()
		if i >= 0 && i < len(rows) && ev.Button == gfx.PointerButtonPrimary {
			m.toggleRun(rows[i].id)
			canvas.Consume()
		} else {
			w.pressRow(canvas, i, ev)
		}
	}
	if slot, ev, ok := canvas.PointerIn(tableFieldsScope); ok && ev.Kind == gfx.PointerDown {
		i := slot / tableFieldSlots
		rows := m.displayRows()
		if i < 0 || i >= len(rows) || rows[i].index >= len(m.records) {
			return
		}
		if ev.Button != gfx.PointerButtonPrimary {
			w.pressRow(canvas, i, ev)
			return
		}
		record := &m.records[rows[i].index]
		keys := slices.Sorted(maps.Keys(record.Fields))
		if k := slot % tableFieldSlots; k < len(keys) && !tableRedacted(record.Fields[keys[k]]) {
			m.compose(core.LogFilterTerm{Kind: "field", Key: keys[k], Value: record.Fields[keys[k]]})
			canvas.Consume()
		}
	}
}

// pressRow selects the row at position i or opens its menu, for a press of the primary or
// the secondary button.
func (w *window) pressRow(canvas *gfx.Canvas, i int, ev gfx.PointerEvent) {
	m := w.model
	rows := m.displayRows()
	if ev.Kind != gfx.PointerDown || i < 0 || i >= len(rows) {
		return
	}
	id := rows[i].id
	switch ev.Button {
	case gfx.PointerButtonPrimary:
		m.selectRow(id, ev.Modifiers&(gfx.ModifierMeta|gfx.ModifierControl) != 0, ev.Modifiers&gfx.ModifierShift != 0)
		w.table.cursor = id
		canvas.Consume()
	case gfx.PointerButtonSecondary:
		if !m.selection[id] {
			m.selectRow(id, false, false)
		}
		w.table.cursor = id
		w.openContextMenu(menuRow, ev.X, ev.Y, id)
		canvas.Consume()
	}
}

// drawTableHeader is the header: a title for each visible column on the secondary
// background, a short divider at the end of each cell, and the line under the whole header.
func (w *window) drawTableHeader(f *ui.Frame, grid *tableGrid) {
	f.Row().FillWidth().Height(tableHeaderHeight).Shrink(0).Items(ui.Center).Background(w.pal.bg2).
		HitWith(tableHeaderID, w.text.Logs.Columns, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true}).
		Children(func() {
			for _, column := range grid.visible[:grid.count] {
				title := w.tableColumnTitle(column)
				cell := w.sizeTableCell(f.Row(), grid, column, tableHeaderHeight)
				if column == tableColSeq {
					cell = cell.Justify(ui.End)
				}
				cell.Children(func() {
					w.mono(f, title, tableHeaderFont, w.pal.tx3).Ellipsis()
					f.Row().Absolute().Top(4).Bottom(4).Right(0).Width(1).Background(w.pal.bd)
					f.Row().Absolute().Top(0).Bottom(0).Right(0).Width(tableHandleWidth).
						HitWith(tableResizeScope.At(column), title, gfx.HitOptions{
							Role:      gfx.RoleSeparator,
							Cursor:    gfx.PointerCursorResizeHorizontal,
							SkipFocus: true,
						})
				})
			}
			f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
		})
}

// tableRowPaint is what the rows of one frame share.
type tableRowPaint struct {
	// cellW is the width of one character cell of the table's text.
	cellW float32
	// selectedOp and selectedEpoch belong to the selected record, which marks the rows of its
	// operation and is the reference of the time since the selected row. hasSelected says
	// there is one.
	hasSelected   bool
	selectedOp    string
	selectedEpoch int64
	// needles are the filter's text terms, which are marked in the messages.
	needles [][]rune
}

// drawTableRow declares the row at position i: its background, which tells an error, a
// selected row and a row of the selected record's operation apart, its cells, the bar at its
// start and the line under it.
func (w *window) drawTableRow(f *ui.Frame, i int, rows []displayRow, grid *tableGrid, widths *[tableColumnCount]float32, p *tableRowPaint) {
	m := w.model
	row := rows[i]
	if row.index < 0 || row.index >= len(m.records) {
		f.Row().FillWidth().Height(tableRowHeight).Shrink(0)
		return
	}
	record := &m.records[row.index]
	selected := m.selection[row.id]
	isError := record.Level == core.LevelError
	isOperation := record.Op != "" && p.hasSelected && record.Op == p.selectedOp

	background := w.pal.bg
	stripe := gfx.Color{}
	hasStripe := false
	switch {
	case selected:
		background = w.pal.hl
		if isError {
			background = w.pal.errSel
		}
		stripe, hasStripe = w.pal.blu, true
	case isError:
		background = w.pal.errRow
	case isOperation:
		background = w.pal.opRow
	}
	if !selected && isOperation {
		stripe, hasStripe = w.pal.pur, true
	}

	label := strings.TrimSpace(record.Event + " " + truncateRunes(record.Msg, 120))
	box := f.Row().FillWidth().Height(tableRowHeight).Shrink(0).Items(ui.Center).Background(background).
		HitWith(tableRowsScope.At(i), label, gfx.HitOptions{Role: gfx.RoleOption, Selected: selected, SkipFocus: true})
	box.Children(func() {
		for _, column := range grid.visible[:grid.count] {
			cell := w.sizeTableCell(f.Row(), grid, column, tableRowHeight)
			if column == tableColSeq {
				cell = cell.Justify(ui.End)
			}
			cell.Children(func() {
				w.drawTableCell(f, column, i, rows, widths[column], p)
			})
		}
		f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
		if hasStripe {
			f.Row().Absolute().Left(0).Top(0).Bottom(0).Width(tableStripeWidth).Background(stripe)
		}
	})
}

// drawTableCell declares the content of one cell of the row at position i, whose column
// shows width points of text.
func (w *window) drawTableCell(f *ui.Frame, column, i int, rows []displayRow, width float32, p *tableRowPaint) {
	m := w.model
	row := rows[i]
	record := &m.records[row.index]
	switch column {
	case tableColSeq:
		w.mono(f, strconv.FormatUint(record.Seq, 10), tableCellFont, w.pal.tx3).Ellipsis()
	case tableColTime:
		w.mono(f, w.tableTime(i, rows, record, p), tableCellFont, w.pal.tx3).Ellipsis()
	case tableColLevel:
		w.mono(f, levelSymbol(record.Level)+" "+string(record.Level), tableSmallFont, w.pal.levelColor(record.Level)).
			Weight(gfx.WeightSemibold).Ellipsis()
	case tableColChannel:
		color := channelColor(record.Channel)
		f.Row().Height(tableChipHeight).PadX(tableCellPad).Items(ui.Center).Radius(tableChipRadius).
			Background(color.WithAlpha(tableChipFill)).Children(func() {
			w.mono(f, record.Channel, tableSmallFont, color).Ellipsis()
		})
	case tableColEvent:
		w.mono(f, record.Event, tableCellFont, w.pal.pur).Ellipsis()
	case tableColMessage:
		w.drawMessageCell(f, i, row, record, width, p)
	case tableColFields:
		w.drawFieldsCell(f, i, record, width, p)
	}
}

// tableTime is the text of a row's time cell: the clock time of the record, or, in the
// relative modes, the milliseconds since the previous row or since the selected row, which
// is the row itself when nothing is selected.
func (w *window) tableTime(i int, rows []displayRow, record *core.LogRecord, p *tableRowPaint) string {
	mode := w.model.prefs.TimeMode
	if mode == 0 {
		return time.UnixMilli(record.EpochMs).Format("15:04:05.000")
	}
	reference := record.EpochMs
	switch {
	case mode == 1 && i > 0:
		if previous := rows[i-1].index; previous >= 0 && previous < len(w.model.records) {
			reference = w.model.records[previous].EpochMs
		}
	case mode == 2 && p.hasSelected:
		reference = p.selectedEpoch
	}
	return fmt.Sprintf("%+.0f ms", float64(record.EpochMs-reference))
}

// drawMessageCell declares the message of a row. The head of a folded run starts with a
// badge that counts the run, and a click on the start of the cell folds or unfolds it; the
// cell tells how many records the run holds and when the last one arrived in a tooltip. The
// parts of the message that match a text term of the filter are marked.
func (w *window) drawMessageCell(f *ui.Frame, i int, row displayRow, record *core.LogRecord, width float32, p *tableRowPaint) {
	avail := width
	if row.isRun {
		avail -= tableTextOffset
		f.Row().Size(tableBadgeWidth, tableBadgeHeight).Shrink(0).PadSides(0, 0, 0, 4).Items(ui.Center).
			Radius(tableBadgeRadius).Background(w.pal.bg3).Border(1, w.pal.bd).Children(func() {
			w.mono(f, "×"+strconv.Itoa(row.count), tableHeaderFont, w.pal.tx2).Shrink(0)
		})
		f.Row().Width(tableTextOffset - tableBadgeWidth).Shrink(0)
	}
	cells := 0
	if p.cellW > 0 {
		cells = int(avail / p.cellW)
	}
	text, _, _ := tableFit(record.Msg, cells)
	text = tableFlatten(text)
	runs := tableHighlight(text, p.needles)
	if len(runs) == 1 && !runs[0].hit {
		if text != "" {
			w.mono(f, text, tableCellFont, w.pal.tx).Ellipsis()
		}
	} else {
		for _, run := range runs {
			mark := w.mono(f, run.text, tableCellFont, w.pal.tx).Shrink(0)
			if run.hit {
				mark.Background(w.pal.yel.WithAlpha(tableHighlightAlpha))
			}
		}
	}
	if row.isRun {
		hint := w.text.Logs.Repeated(row.count, row.last)
		f.Row().Absolute().Left(0).Right(0).Top(0).Bottom(0).
			HitWith(tableMessagesScope.At(i), hint, gfx.HitOptions{Role: gfx.RoleOption, Hint: hint, SkipFocus: true})
		f.Row().Absolute().Left(tableCellPad).Top(0).Bottom(0).Width(tableFoldWidth).
			HitWith(tableRunsScope.At(i), hint, gfx.HitOptions{Role: gfx.RoleButton, Hint: hint, SkipFocus: true})
	}
}

// drawFieldsCell declares the fields of a row as key=value pairs: keys in cyan, values in
// pink (booleans), blue (numbers), green (text, quoted) or gray (redacted). A value that is
// not redacted adds the field to the filter when it is pressed.
func (w *window) drawFieldsCell(f *ui.Frame, i int, record *core.LogRecord, width float32, p *tableRowPaint) {
	cells := 0
	if p.cellW > 0 {
		cells = int(width / p.cellW)
	}
	used := 0
	for slot, key := range slices.Sorted(maps.Keys(record.Fields)) {
		if used >= cells {
			return
		}
		value := record.Fields[key]
		redacted := tableRedacted(value)
		shown, color := value, w.pal.grn
		switch {
		case redacted:
			color = w.pal.tx3
		case value == "true" || value == "false":
			color = w.pal.pnk
		case tableIsNumber(value):
			color = w.pal.blu
		default:
			shown = `"` + value + `"`
		}
		parts := [2]struct {
			text  string
			color gfx.Color
			link  bool
		}{{key + "=", w.pal.cyn, false}, {shown, color, !redacted}}
		for _, part := range parts {
			text, taken, cut := tableFit(part.text, cells-used)
			if text == "" {
				return
			}
			box := w.mono(f, tableFlatten(text), tableCellFont, part.color).Shrink(0)
			if part.link && slot < tableFieldSlots {
				box.HitWith(tableFieldsScope.At(i*tableFieldSlots+slot), key, gfx.HitOptions{Role: gfx.RoleLink, SkipFocus: true})
			}
			used += taken
			if cut {
				return
			}
		}
		f.Row().Width(p.cellW).Shrink(0)
		used++
	}
}

// tableRun is a stretch of a message that is either marked as a match or not.
type tableRun struct {
	text string
	hit  bool
}

// tableHighlight splits text into runs, marking every case-insensitive occurrence of any of
// the needles. Text without a match is one run that is not marked.
func tableHighlight(text string, needles [][]rune) []tableRun {
	if len(needles) == 0 || text == "" {
		return []tableRun{{text: text}}
	}
	runes := []rune(text)
	marked := make([]bool, len(runes))
	found := false
	for _, needle := range needles {
		for at := 0; at+len(needle) <= len(runes); {
			if tableFoldEqual(runes[at:], needle) {
				for k := range needle {
					marked[at+k] = true
				}
				at += len(needle)
				found = true
			} else {
				at++
			}
		}
	}
	if !found {
		return []tableRun{{text: text}}
	}
	var runs []tableRun
	start := 0
	for i := 1; i <= len(runes); i++ {
		if i == len(runes) || marked[i] != marked[start] {
			runs = append(runs, tableRun{text: string(runes[start:i]), hit: marked[start]})
			start = i
		}
	}
	return runs
}

// tableFoldEqual says whether the start of haystack equals needle, ignoring case. The
// haystack is at least as long as the needle.
func tableFoldEqual(haystack, needle []rune) bool {
	for k, r := range needle {
		if haystack[k] != r && unicode.ToLower(haystack[k]) != unicode.ToLower(r) {
			return false
		}
	}
	return true
}

// tableFit cuts s to the monospace cells it may take, ending it in an ellipsis when it has
// to cut. It returns the text, the cells the text takes and whether it cut. It looks at no
// more characters than fit, so a very long message costs no more than a short one.
func tableFit(s string, cells int) (string, int, bool) {
	if cells <= 0 {
		return "", 0, s != ""
	}
	used := 0
	for i, r := range s {
		width := vivatext.CellWidth(r)
		if used+width <= cells {
			used += width
			continue
		}
		// The text does not fit: leave room for the ellipsis, which takes one cell.
		head := s[:i]
		for used > cells-1 && head != "" {
			last, size := utf8.DecodeLastRuneInString(head)
			used -= vivatext.CellWidth(last)
			head = head[:len(head)-size]
		}
		return head + "…", used + 1, true
	}
	return s, used, false
}

// tableFlatten puts a space in place of the line breaks and tabs of a one-line cell. Each
// takes one cell, as the space does.
func tableFlatten(s string) string {
	if !strings.ContainsAny(s, "\n\r\t") {
		return s
	}
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		return r
	}, s)
}

// tableRedacted says whether a field value is the placeholder of a redacted value, which is
// shown dimmed and is not clickable.
func tableRedacted(value string) bool {
	return value == "‹redacted›" || value == "<redacted>"
}

// tableIsNumber says whether a field value reads as a number, including one too large for a
// float, which still reads as a number.
func tableIsNumber(value string) bool {
	_, err := strconv.ParseFloat(value, 64)
	return err == nil || errors.Is(err, strconv.ErrRange)
}

// tableKey handles the keys of the table. Up and Down move the selection by a row (⇧
// extends it from the anchor) and scroll it into view; Home, End, Page Up and Page Down
// scroll without changing the selection; Escape clears the selection.
func (w *window) tableKey(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || w.menu.kind != menuNone ||
		event.Modifiers&(gfx.ModifierMeta|gfx.ModifierControl|gfx.ModifierAlt) != 0 {
		return gfx.EventResult{}
	}
	handled := gfx.EventResult{Handled: true, Repaint: true}
	m := w.model
	t := &w.table
	s := w.view.ScrollState(tableScrollID)
	step := max(tableRowHeight, s.Viewport-tableRowHeight)
	switch event.Key {
	case gfx.KeyUp, gfx.KeyDown:
		rows := m.displayRows()
		if len(rows) == 0 {
			return gfx.EventResult{}
		}
		current := w.tableActiveRow(rows)
		var next int
		switch {
		case current < 0 && event.Key == gfx.KeyDown:
			next = 0
		case current < 0:
			next = len(rows) - 1
		case event.Key == gfx.KeyDown:
			next = min(len(rows)-1, current+1)
		default:
			next = max(0, current-1)
		}
		id := rows[next].id
		m.selectRow(id, false, event.Modifiers&gfx.ModifierShift != 0)
		t.cursor, t.reveal = id, id
		return handled
	case gfx.KeyHome:
		s.ScrollTo(0)
		w.tableScrolled()
		return handled
	case gfx.KeyEnd:
		t.toEnd = true
		return handled
	case gfx.KeyPageUp:
		s.ScrollTo(s.Offset - step)
		w.tableScrolled()
		return handled
	case gfx.KeyPageDown:
		s.ScrollTo(min(s.Max(), s.Offset+step))
		w.tableScrolled()
		return handled
	case gfx.KeyEscape:
		if len(m.selection) == 0 {
			return gfx.EventResult{}
		}
		m.selectIDs(nil)
		t.cursor = ""
		return handled
	}
	return gfx.EventResult{}
}

// tableActiveRow is the position of the row the arrow keys move from: the row the last key
// or click went to while it is still selected, otherwise the last selected row. It is -1
// when no displayed row is selected.
func (w *window) tableActiveRow(rows []displayRow) int {
	m := w.model
	if id := w.table.cursor; id != "" && m.selection[id] {
		if i := tableRowIndex(rows, id); i >= 0 {
			return i
		}
	}
	if m.selected >= 0 && m.selected < len(m.ids) {
		return tableRowIndex(rows, m.ids[m.selected])
	}
	return -1
}

// tableRecordByID is the record with the given id, which a row menu is about.
func (w *window) tableRecordByID(id string) (core.LogRecord, bool) {
	m := w.model
	for i := len(m.ids) - 1; i >= 0; i-- {
		if m.ids[i] == id && i < len(m.records) {
			return m.records[i], true
		}
	}
	return core.LogRecord{}, false
}

// drawRowMenu declares the table's open context menu: the menu of a row, or the menu of the
// header that shows and hides columns.
func (w *window) drawRowMenu(f *ui.Frame) {
	m := w.model
	place := func(b ui.Box) ui.Box { return b.At(w.menu.at.X, w.menu.at.Y) }
	if w.menu.kind == menuHeader {
		w.menuSurface(f, place, tableHeaderMenuWidth, func() {
			for i, name := range columns {
				hidden := m.columnHidden(name)
				if w.menuItem(f, tableColumnItems.At(i), w.tableColumnTitle(i), itemOptions{checked: !hidden}) {
					m.setColumnHidden(name, !hidden)
				}
			}
		})
		return
	}
	record, ok := w.tableRecordByID(w.menu.row)
	if !ok {
		w.closeMenu()
		return
	}
	text := w.text.Logs
	top := itemOptions{top: true}
	var anchor ui.Box
	w.menuSurface(f, place, tableRowMenuWidth, func() {
		if w.menuItem(f, tableMenuCopyLine, text.CopyLine, top) {
			m.copyFormatted([]core.LogRecord{record}, "json")
		}
		if w.menuItem(f, tableMenuCopyMarkdown, text.CopySelectionMarkdown, top) {
			m.copyFormatted(m.selectedRecords(), "markdown")
		}
		w.menuSeparator(f)
		if w.menuItem(f, tableMenuShowEvent, text.ShowOnlyEvent, top) {
			m.compose(core.LogFilterTerm{Kind: "event", Value: record.Event})
		}
		if w.menuItem(f, tableMenuHideEvent, text.HideEvent, top) {
			m.compose(core.LogFilterTerm{Kind: "event", Value: record.Event, Negate: true})
		}
		if w.menuItem(f, tableMenuShowChannel, text.ShowOnlyChannel, top) {
			m.compose(core.LogFilterTerm{Kind: "channel", Value: record.Channel})
		}
		if w.menuItem(f, tableMenuTrace, text.TraceThisOperation, itemOptions{top: true, disabled: record.Op == ""}) {
			m.compose(core.LogFilterTerm{Kind: "op", Value: record.Op})
		}
		anchor = w.menuSubmenu(f, tableMenuCopyField, text.CopyFieldValue, 0)
	})
	if w.menu.kind != menuRow || w.menu.sub != 0 {
		return
	}
	var keys []string
	for _, key := range slices.Sorted(maps.Keys(record.Fields)) {
		if !tableRedacted(record.Fields[key]) {
			keys = append(keys, key)
		}
	}
	if len(keys) == 0 {
		return
	}
	beside := func(b ui.Box) ui.Box { return b.BesideBox(anchor, 2, ui.Start) }
	w.menuPanel(f, beside, tableSubmenuWidth, func() {
		for k, key := range keys {
			if w.menuItem(f, tableFieldItems.At(k), key, itemOptions{}) {
				m.copyText(record.Fields[key])
			}
		}
	})
}
