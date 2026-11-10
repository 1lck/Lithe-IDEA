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
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
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
	// tableFieldCache is how many records keep their painted fields before the cache starts
	// again.
	tableFieldCache = 2048

	// The widths of the context menus.
	tableHeaderMenuWidth = 150
	tableRowMenuWidth    = 220
	tableSubmenuWidth    = 140
)

// tableColumnPart names the cells of a column in a row or in the header.
var tableColumnPart = [tableColumnCount]string{"column-0", "column-1", "column-2", "column-3", "column-4", "column-5", "column-6"}

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
	// list is the rows' list and chosen the rows the user chose in it, by their keys (see
	// Model.keyBase). The model's selection is the truth the details and the copy read: a
	// choice the list reports is handed to it, and one the model made is handed back, which
	// syncedRevision tells apart.
	list           ui.ListState
	chosen         ui.Selection
	syncedRevision int
	// rows are the displayed rows of the paint being declared, which list.Key reads.
	rows []displayRow

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

	// topID is the row at the top of the area and topIndex its position. When rows appear or
	// disappear above it the area scrolls to keep it where it was. topID is empty while the
	// area follows the end.
	topIndex int
	topID    string
	// scrolled says the paint being declared asked the list to scroll, which it does when it
	// lays out: until then the list is not where it was asked to be.
	scrolled bool

	// hints are the tooltips of the folded runs, which the i18n formats from a template:
	// kept for the text, the run's length and its last time, so a paint formats none of
	// them again. language is the messages they were made with.
	hints    map[string]runHint
	language *i18n.Messages

	// fields are the painted fields of the records near the screen, by record key.
	fields map[int][]fieldItem
}

// runHint is the tooltip of one folded run.
type runHint struct {
	count int
	last  string
	text  string
}

// runTooltip is what a folded run says of itself: how many records it holds and when the
// last one arrived. The text is formatted once for a run that does not change.
func (t *tableState) runTooltip(text *i18n.Messages, row displayRow) string {
	if t.language != text || len(t.hints) > 4*maxRecords {
		t.language, t.hints = text, map[string]runHint{}
	}
	if hint, ok := t.hints[row.id]; ok && hint.count == row.count && hint.last == row.last {
		return hint.text
	}
	hint := runHint{count: row.count, last: row.last, text: text.Logs.Repeated(row.count, row.last)}
	t.hints[row.id] = hint
	return hint.text
}

// init gives the list the key of a row: the key of the record the row shows, which stays
// the same while records come and go around it.
func (t *tableState) init(w *window) {
	t.list.Key = func(i int) int { return w.model.keyBase + t.rows[i].index }
	t.list.Selection = &t.chosen
	t.syncedRevision = -1
}

// tablePanel is the table: the header and the rows of the model, a list that declares only
// the visible ones. The list follows the end of the log while the model follows it, scrolls
// to the row the model asks for, and keeps the row at its top where it was when rows appear
// above it.
func (w *window) tablePanel(c ui.C) {
	m := w.model
	t := &w.table
	canvas := c.Canvas()
	// The table is the window less the channel list and its divider. The layout does not
	// say how wide an element was in an earlier frame, so the widths the columns show are
	// worked out from this.
	viewport := c.Bounds().Width - sidebarWidth - 1

	grid := w.gridOfColumns()
	widths := w.tableWidths(&grid, viewport)
	rows := m.displayRows()
	t.rows = rows
	n := len(rows)
	if !t.list.Changed() && t.syncedRevision != m.selectionRevision {
		w.syncTableSelection(rows)
	}
	t.scrolled = w.scrollTable(c, rows)

	var rowWidth float32
	for _, column := range grid.visible[:grid.count] {
		if t.dragging {
			rowWidth += widths[column]
		} else {
			rowWidth += grid.base[column]
		}
		rowWidth += tableCellSpacing
	}
	t.list.RowWidth = rowWidth

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

	panel := ui.Column(c).Fill().Children(func() {
		w.tableHeader(c, &grid, &widths, viewport, rowWidth)
		area := ui.List(c, &t.list, n, func(row ui.ListRow) {
			w.tableRow(row, &grid, &widths, &paint)
		}).Label(w.text.Logs.Logs).Grow(1).Shrink(1).MinHeight(0).FillWidth().Follow(m.follows)
		if t.list.Changed() {
			w.applyTableSelection()
		}
		w.trackTable(area, rows)
	})
	// Escape clears the selection while the focus is in the table.
	if panel.Shortcut(0, "escape") && len(m.selection) > 0 {
		m.selectIDs(nil)
	}
}

// syncTableSelection hands the model's selection to the list, which holds it by the keys
// of the rows: after the model changed it (a jump, a new answer, a clear), not after the
// list did.
func (w *window) syncTableSelection(rows []displayRow) {
	m := w.model
	t := &w.table
	t.syncedRevision = m.selectionRevision
	t.chosen.Clear()
	for i, row := range rows {
		if m.selection[row.id] {
			t.chosen.Add(m.keyBase + row.index)
			t.list.Select(i)
		}
	}
}

// applyTableSelection hands a choice the user made in the list to the model.
func (w *window) applyTableSelection() {
	m := w.model
	t := &w.table
	ids := make(map[string]bool, t.chosen.Len())
	for key := range t.chosen.All() {
		if i := key - m.keyBase; i >= 0 && i < len(m.ids) {
			ids[m.ids[i]] = true
		}
	}
	m.selectIDs(ids)
	t.syncedRevision = m.selectionRevision
}

// chooseTableRow chooses row i alone, as a press on it does.
func (w *window) chooseTableRow(i int) {
	m := w.model
	t := &w.table
	row := t.rows[i]
	t.chosen.Clear()
	t.chosen.Add(m.keyBase + row.index)
	t.list.Select(i)
	m.selectIDs(map[string]bool{row.id: true})
	t.syncedRevision = m.selectionRevision
}

// scrollTable acts on what the model asks of the scroll position: to the end, or to a row,
// and keeps the row that was at the top where it was when rows came or went above it.
func (w *window) scrollTable(c ui.C, rows []displayRow) (scrolled bool) {
	m := w.model
	t := &w.table
	if !t.revisionSeen || t.revision != m.scrollRevision {
		t.revisionSeen, t.revision = true, m.scrollRevision
		// The list places its rows from heights it has not measured yet, so the paint that
		// scrolls it is followed by one that settles.
		c.Canvas().RequestFrame()
		if m.scrollTarget == "" {
			t.list.ScrollToEnd()
			t.topID = ""
			return true
		}
		if i := tableRowIndex(rows, m.scrollTarget); i >= 0 {
			t.list.ScrollIntoView(i)
			t.list.Select(i)
			t.topID = ""
			return true
		}
	}
	if m.follows || t.topID == "" {
		return false
	}
	if t.topIndex < len(rows) && rows[t.topIndex].id == t.topID {
		return false
	}
	if i := tableRowIndex(rows, t.topID); i >= 0 {
		t.list.ScrollTo(i, ui.ListStart)
		c.Canvas().RequestFrame()
		return true
	}
	return false
}

// trackTable remembers the row at the top, and stops following when the table was
// scrolled away from its end: by the wheel or the scroll bar.
func (w *window) trackTable(area ui.Box, rows []displayRow) {
	m := w.model
	t := &w.table
	s := area.ScrollState()
	if m.follows {
		t.topID = ""
		if !t.scrolled && s.Viewport > 0 && s.Content > 0 && !s.AtEnd() {
			m.userScrolledUp()
		}
		return
	}
	if len(rows) == 0 {
		t.topID = ""
		return
	}
	top := min(len(rows)-1, max(0, int(s.Offset/tableRowHeight)))
	t.topIndex, t.topID = top, rows[top].id
}

// tableHeader is the header: a title for each visible column on the secondary background, a
// short divider at the end of each cell, the handle that drags the column's width, and the
// line under the whole header. A secondary press on it opens the menu of columns. The cells
// follow the rows when they scroll sideways.
func (w *window) tableHeader(c ui.C, grid *tableGrid, widths *[tableColumnCount]float32, viewport, rowWidth float32) {
	header := ui.Row(c).FillWidth().Height(tableHeaderHeight).Shrink(0).Clip().Background(w.pal.bg2).
		Hit(ui.ID(c), w.text.Logs.Columns)
	header.Children(func() {
		ui.Row(c).Width(max(rowWidth, viewport)).Height(tableHeaderHeight).Items(ui.Center).ScrollWith(&w.table.list).Children(func() {
			for _, column := range grid.visible[:grid.count] {
				title := w.tableColumnTitle(column)
				cell := w.sizeTableCell(ui.Row(c.Part(tableColumnPart[column])), grid, column, tableHeaderHeight)
				if column == tableColSeq {
					cell = cell.Justify(ui.End)
				}
				cell.Children(func() {
					w.mono(c, title, tableHeaderFont, w.pal.tx3).Ellipsis()
					ui.Row(c).Absolute().Top(4).Bottom(4).Right(0).Width(1).Background(w.pal.bd)
					w.resizeHandle(c, grid, column, title, viewport)
				})
			}
		})
		ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
	ui.ContextMenu(c, header, w.headerMenu)
}

// headerMenu is the menu of the header that shows and hides columns.
func (w *window) headerMenu(menu *ui.MenuItems) {
	menu.WidthRange(tableHeaderMenuWidth, 0)
	for i, name := range columns {
		hidden := w.model.columnHidden(name)
		if menu.Item(w.tableColumnTitle(i)).Checked(!hidden).Clicked() {
			w.model.setColumnHidden(name, !hidden)
		}
	}
}

// resizeHandle is the strip at a header cell's trailing edge that drags the column's width:
// the primary button down on it starts a drag, moving follows the pointer and releasing
// adopts the width.
func (w *window) resizeHandle(c ui.C, grid *tableGrid, column int, title string, viewport float32) {
	id := ui.ID(c)
	ui.Row(c).Absolute().Top(0).Bottom(0).Right(0).Width(tableHandleWidth).
		HitWith(id, title, gfx.HitOptions{Role: gfx.RoleSeparator, Cursor: gfx.PointerCursorResizeHorizontal, SkipFocus: true})
	canvas := c.Canvas()
	ev, ok := canvas.PointerOn(id)
	if !ok {
		return
	}
	t := &w.table
	switch ev.Kind {
	case gfx.PointerDown:
		if ev.Button != gfx.PointerButtonPrimary {
			return
		}
		t.dragging = true
		t.dragColumn = column
		t.dragStartX = ev.X
		t.frozen = grid.fit(viewport)
		t.dragStartWidth = t.frozen[column]
		t.dragWidth = t.dragStartWidth
		canvas.Consume()
	case gfx.PointerMove:
		if t.dragging && column == t.dragColumn {
			t.dragWidth = min(maxColumnWidth, max(minColumnWidth, t.dragStartWidth+ev.X-t.dragStartX))
			canvas.Consume()
		}
	case gfx.PointerUp, gfx.PointerExit:
		if !t.dragging || column != t.dragColumn {
			return
		}
		t.dragging = false
		if t.dragWidth != t.dragStartWidth {
			w.applyColumnWidths(grid.adopt(t.dragColumn, t.dragWidth, viewport))
		}
		canvas.Consume()
	}
}

// tableRow declares the row the list asks for: its background, which tells an error, a
// selected row and a row of the selected record's operation apart, its cells, the bar at
// its start and the line under it. A secondary press on it chooses it, if it is not chosen,
// and opens its menu.
func (w *window) tableRow(row ui.ListRow, grid *tableGrid, widths *[tableColumnCount]float32, p *tableRowPaint) {
	c := row.C
	m := w.model
	rows := w.table.rows
	i := row.Index
	display := rows[i]
	if display.index < 0 || display.index >= len(m.records) {
		row.Element.FillWidth().Height(tableRowHeight)
		return
	}
	record := &m.records[display.index]
	selected := row.Selected()
	isError := record.Level == core.LevelError
	isOperation := record.Op != "" && p.hasSelected && record.Op == p.selectedOp

	background := w.pal.bg
	stripe := ui.Color{}
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
	row.Element.FillWidth().Height(tableRowHeight).Items(ui.Center).Background(background)
	hint := ""
	if display.isRun {
		hint = w.table.runTooltip(w.text, display)
		row.Element.Tooltip(hint)
	}
	if ev, ok := c.Canvas().PointerOn(row.ID); ok && ev.Kind == gfx.PointerDown && ev.Button == gfx.PointerButtonSecondary && !selected {
		w.chooseTableRow(i)
	}
	ui.ContextMenu(c, row.Element, func(menu *ui.MenuItems) { w.rowMenu(menu, i) })

	for _, column := range grid.visible[:grid.count] {
		cell := w.sizeTableCell(ui.Row(c.Part(tableColumnPart[column])), grid, column, tableRowHeight)
		if column == tableColSeq {
			cell = cell.Justify(ui.End)
		}
		cell.Children(func() {
			w.tableCell(c, column, i, rows, widths[column], p, hint)
		})
	}
	ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	if hasStripe {
		ui.Row(c).Absolute().Left(0).Top(0).Bottom(0).Width(tableStripeWidth).Background(stripe)
	}
}

// tableCell declares the content of one cell of the row at position i, whose column shows
// width points of text.
func (w *window) tableCell(c ui.C, column, i int, rows []displayRow, width float32, p *tableRowPaint, hint string) {
	m := w.model
	row := rows[i]
	record := &m.records[row.index]
	switch column {
	case tableColSeq:
		w.mono(c, strconv.FormatUint(record.Seq, 10), tableCellFont, w.pal.tx3).Ellipsis()
	case tableColTime:
		w.mono(c, w.tableTime(i, rows, record, p), tableCellFont, w.pal.tx3).Ellipsis()
	case tableColLevel:
		w.mono(c, levelSymbol(record.Level)+" "+string(record.Level), tableSmallFont, w.pal.levelColor(record.Level)).
			Weight(gfx.WeightSemibold).Ellipsis()
	case tableColChannel:
		color := channelColor(record.Channel)
		ui.Row(c).Height(tableChipHeight).PadX(tableCellPad).Items(ui.Center).Radius(tableChipRadius).
			Background(color.WithAlpha(tableChipFill)).Children(func() {
			w.mono(c, record.Channel, tableSmallFont, color).Ellipsis()
		})
	case tableColEvent:
		w.mono(c, record.Event, tableCellFont, w.pal.pur).Ellipsis()
	case tableColMessage:
		w.messageCell(c, row, record, width, p, hint)
	case tableColFields:
		w.fieldsCell(c, record, w.model.keyBase+row.index, width, p)
	}
}

// messageCell declares the message of a row. The head of a folded run starts with a badge
// that counts the run, and a click on the start of the cell folds or unfolds it; the row
// tells how many records the run holds and when the last one arrived in a tooltip. The parts
// of the message that match a text term of the filter are marked.
func (w *window) messageCell(c ui.C, row displayRow, record *core.LogRecord, width float32, p *tableRowPaint, hint string) {
	avail := width
	if row.isRun {
		avail -= tableTextOffset
		ui.Row(c).Size(tableBadgeWidth, tableBadgeHeight).Shrink(0).PadSides(0, 0, 0, 4).Items(ui.Center).
			Radius(tableBadgeRadius).Background(w.pal.bg3).Border(1, w.pal.bd).Children(func() {
			w.mono(c, "×"+strconv.Itoa(row.count), tableHeaderFont, w.pal.tx2).Shrink(0)
		})
		ui.Row(c).Width(tableTextOffset - tableBadgeWidth).Shrink(0)
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
			w.mono(c, text, tableCellFont, w.pal.tx).Ellipsis()
		}
	} else {
		for _, run := range runs {
			mark := w.mono(c, run.text, tableCellFont, w.pal.tx).Shrink(0)
			if run.hit {
				mark.Background(w.pal.yel.WithAlpha(tableHighlightAlpha))
			}
		}
	}
	if row.isRun {
		fold := ui.Row(c).Absolute().Left(tableCellPad).Top(0).Bottom(0).Width(tableFoldWidth).
			HitWith(ui.ID(c), hint, gfx.HitOptions{Role: gfx.RoleButton, Hint: hint, SkipFocus: true})
		if fold.Clicked() {
			w.model.toggleRun(row.id)
		}
	}
}

// fieldKind says what a field value is, which decides its color.
type fieldKind uint8

const (
	fieldText fieldKind = iota
	fieldBool
	fieldNumber
	fieldRedacted
)

// fieldItem is one field of a record, ready to paint: its key and "key=" text, its value
// as it is shown (quoted when it is text) and what kind of value it is.
type fieldItem struct {
	key, keyText, shown string
	kind                fieldKind
}

// fieldItems are the fields of the record with the given key, sorted by key. The record
// does not change, so they are made once while the row is near the screen.
func (t *tableState) fieldItems(recordKey int, fields map[string]string) []fieldItem {
	if items, ok := t.fields[recordKey]; ok {
		return items
	}
	if t.fields == nil || len(t.fields) > tableFieldCache {
		t.fields = map[int][]fieldItem{}
	}
	items := make([]fieldItem, 0, len(fields))
	for _, key := range slices.Sorted(maps.Keys(fields)) {
		value := fields[key]
		item := fieldItem{key: key, keyText: key + "=", shown: value}
		switch {
		case tableRedacted(value):
			item.kind = fieldRedacted
		case value == "true" || value == "false":
			item.kind = fieldBool
		case tableIsNumber(value):
			item.kind = fieldNumber
		default:
			item.shown = `"` + value + `"`
		}
		items = append(items, item)
	}
	t.fields[recordKey] = items
	return items
}

// fieldsCell declares the fields of a row as key=value pairs: keys in cyan, values in pink
// (booleans), blue (numbers), green (text, quoted) or gray (redacted). A value that is not
// redacted adds the field to the filter when it is pressed.
func (w *window) fieldsCell(c ui.C, record *core.LogRecord, recordKey int, width float32, p *tableRowPaint) {
	cells := 0
	if p.cellW > 0 {
		cells = int(width / p.cellW)
	}
	used := 0
	for slot, item := range w.table.fieldItems(recordKey, record.Fields) {
		if used >= cells {
			return
		}
		color := w.pal.grn
		switch item.kind {
		case fieldRedacted:
			color = w.pal.tx3
		case fieldBool:
			color = w.pal.pnk
		case fieldNumber:
			color = w.pal.blu
		}
		for part := range 2 {
			text, textColor := item.keyText, w.pal.cyn
			if part == 1 {
				text, textColor = item.shown, color
			}
			text, taken, cut := tableFit(text, cells-used)
			if text == "" {
				return
			}
			box := w.mono(c, tableFlatten(text), tableCellFont, textColor).Shrink(0)
			if part == 1 && item.kind != fieldRedacted && slot < tableFieldSlots {
				if box.HitWith(ui.ID(c), item.key, gfx.HitOptions{Role: gfx.RoleLink, SkipFocus: true}).Clicked() {
					w.model.compose(core.LogFilterTerm{Kind: "field", Key: item.key, Value: record.Fields[item.key]})
				}
			}
			used += taken
			if cut {
				return
			}
		}
		ui.Row(c).Width(p.cellW).Shrink(0)
		used++
	}
}

// rowMenu is the menu of the row at position i: copying it, filtering by its event, its
// channel and its operation, and copying one of its field values.
func (w *window) rowMenu(menu *ui.MenuItems, i int) {
	m := w.model
	rows := w.table.rows
	if i >= len(rows) || rows[i].index >= len(m.records) {
		return
	}
	record := m.records[rows[i].index]
	text := w.text.Logs
	menu.WidthRange(tableRowMenuWidth, 0)
	if menu.Item(text.CopyLine).Clicked() {
		m.copyFormatted([]core.LogRecord{record}, "json")
	}
	if menu.Item(text.CopySelectionMarkdown).Clicked() {
		m.copyFormatted(m.selectedRecords(), "markdown")
	}
	menu.Separator()
	if menu.Item(text.ShowOnlyEvent).Clicked() {
		m.compose(core.LogFilterTerm{Kind: "event", Value: record.Event})
	}
	if menu.Item(text.HideEvent).Clicked() {
		m.compose(core.LogFilterTerm{Kind: "event", Value: record.Event, Negate: true})
	}
	if menu.Item(text.ShowOnlyChannel).Clicked() {
		m.compose(core.LogFilterTerm{Kind: "channel", Value: record.Channel})
	}
	if menu.Item(text.TraceThisOperation).Disabled(record.Op == "").Clicked() {
		m.compose(core.LogFilterTerm{Kind: "op", Value: record.Op})
	}
	var keys []string
	for _, key := range slices.Sorted(maps.Keys(record.Fields)) {
		if !tableRedacted(record.Fields[key]) {
			keys = append(keys, key)
		}
	}
	menu.Sub(text.CopyFieldValue, func(sub *ui.MenuItems) {
		sub.WidthRange(tableSubmenuWidth, 0)
		for _, key := range keys {
			if sub.Item(key).Clicked() {
				m.copyText(record.Fields[key])
			}
		}
	}).Disabled(len(keys) == 0)
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

// tableRowIndex is the position of the row with the given id, or -1.
func tableRowIndex(rows []displayRow, id string) int {
	for i, row := range rows {
		if row.id == id {
			return i
		}
	}
	return -1
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
