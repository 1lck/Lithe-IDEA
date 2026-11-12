package logwindow

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The metrics of the details pane, after the macOS window's.
const (
	// detailsFontSize is the size of the JSON, the tabs and the call chain's header, which
	// the macOS window inherits from its root view.
	detailsFontSize = 12.5
	// detailsPadX and detailsPadY pad the JSON.
	detailsPadX = 14
	detailsPadY = 8
	// detailsActionsWidth is the column of actions at the trailing end, with its padding.
	detailsActionsWidth = 209
	detailsActionsPad   = 8
	detailsActionsGap   = 5
	detailsButtonHeight = 25
	// detailsNoteSize is the size of the note under the actions.
	detailsNoteSize = 10

	// The call chain's rows: their height, the font and the padding of the list.
	detailsTraceRowHeight = 22
	detailsTraceFontSize  = 11.5
	detailsTracePadX      = 10
	detailsTracePadY      = 6
)

// The tabs of the details pane.
const (
	detailsTabFields = iota
	detailsTabTrace
)

// detailRole says what a span of the details' JSON is, which decides its color. The colors
// are resolved when the span is drawn so that a change of theme needs no new tokens.
type detailRole uint8

const (
	// detailPlain is punctuation and white space.
	detailPlain detailRole = iota
	detailKey
	detailString
	detailLiteral
	detailNumber
	// detailRedacted is a value the kernel masked.
	detailRedacted
	// detailNote is the line above the JSON that names the file and line of the record.
	detailNote
)

// detailSpan is a run of text of one role in a line of the details.
type detailSpan struct {
	text string
	role detailRole
	// field is set on the value of a field the record carries: clicking the span adds a
	// term for that field to the filter.
	field string
}

// detailRow is one line of the details, as the spans it is made of.
type detailRow []detailSpan

// detailsState is what the details pane remembers between frames: the tab that is open and
// the JSON of the selected record, tokenized, so that a frame with the same record does no
// work on the text.
type detailsState struct {
	// tab is detailsTabFields or detailsTabTrace.
	tab int

	// tokens are the lines of the kernel's JSON for the record tokenID, whose text was
	// tokenText.
	tokens             []detailRow
	tokenID, tokenText string
	tokenized          bool

	// traceList is the call chain's list and records the records of the paint being declared,
	// which its rows read.
	traceList ui.ListState
	records   []core.LogRecord

	// header is the row of the note above the JSON, built for the note laidHeader.
	header     []detailRow
	laidHeader string
}

// detailsToken finds the tokens the JSON is colored by: a string, true, false and null, and a
// number. It is the expression of the macOS window's highlighter, so both windows color the
// same text the same way. The text itself is the kernel's formatted copy.
var detailsToken = regexp.MustCompile(`"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?`)

// detailColor is the color of a role.
func (p palette) detailColor(role detailRole) gfx.Color {
	switch role {
	case detailKey:
		return p.cyn
	case detailString:
		return p.grn
	case detailLiteral:
		return p.pnk
	case detailNumber:
		return p.blu
	case detailRedacted, detailNote:
		return p.tx3
	}
	return p.tx2
}

// tokenizeDetailJSON colors the kernel's JSON text and splits it into lines. A key is a string
// that a colon follows, a redacted value is dimmed, and a value after a key the record has in
// its fields is a link that filters on that field.
func tokenizeDetailJSON(text string, fields map[string]string) []detailRow {
	if text == "" {
		return nil
	}
	var spans []detailSpan
	last := 0
	key := ""
	haveKey := false
	for _, at := range detailsToken.FindAllStringIndex(text, -1) {
		if at[0] > last {
			spans = append(spans, detailSpan{text: text[last:at[0]], role: detailPlain})
		}
		token := text[at[0]:at[1]]
		tail := strings.TrimLeftFunc(text[at[1]:], unicode.IsSpace)
		quoted := strings.HasPrefix(token, `"`)
		isKey := quoted && strings.HasPrefix(tail, ":")
		redacted := strings.Contains(token, "‹redacted›") || strings.Contains(token, "<redacted>")
		span := detailSpan{text: token}
		switch {
		case isKey:
			span.role = detailKey
		case redacted:
			span.role = detailRedacted
		case quoted:
			span.role = detailString
		case token == "true" || token == "false" || token == "null":
			span.role = detailLiteral
		default:
			span.role = detailNumber
		}
		if isKey {
			key, haveKey = token[1:len(token)-1], true
		} else if haveKey && !redacted {
			if _, ok := fields[key]; ok {
				span.field = key
			}
		}
		spans = append(spans, span)
		last = at[1]
	}
	if last < len(text) {
		spans = append(spans, detailSpan{text: text[last:], role: detailPlain})
	}
	return splitDetailLines(spans)
}

// splitDetailLines cuts spans at their line breaks.
func splitDetailLines(spans []detailSpan) []detailRow {
	var lines []detailRow
	var line detailRow
	for _, span := range spans {
		for {
			head, rest, found := strings.Cut(span.text, "\n")
			if head != "" {
				line = append(line, detailSpan{text: head, role: span.role, field: span.field})
			}
			if !found {
				break
			}
			lines = append(lines, line)
			line = nil
			span.text = rest
		}
	}
	return append(lines, line)
}

// layoutDetail makes the tokens of the selected record's JSON when the record or its text
// changed, and the row of the note above them when the note changed. The lines are not
// broken: the area they are in scrolls sideways.
func (w *window) layoutDetail(fields map[string]string, header string) {
	d := &w.details
	id, text := w.model.detailID, w.model.detailText
	if !d.tokenized || d.tokenID != id || d.tokenText != text {
		d.tokens = tokenizeDetailJSON(text, fields)
		d.tokenID, d.tokenText, d.tokenized = id, text, true
	}
	if d.header == nil || d.laidHeader != header {
		d.header = []detailRow{{{text: header, role: detailNote}}}
		d.laidHeader = header
	}
}

// detailsPanel is the details pane: the tabs and the selected record's JSON or call chain on
// the left, the actions on the right. The caller draws the splitter above it.
func (w *window) detailsPanel(c ui.C) {
	record, selected := w.model.selectedRecord()
	ui.Row(c).Fill().Children(func() {
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).FillHeight().Children(func() {
			w.detailTabs(c)
			if w.details.tab == detailsTabTrace {
				w.detailTrace(c, record, selected)
			} else {
				w.detailFields(c, record, selected)
			}
		})
		ui.Row(c).Width(1).FillHeight().Shrink(0).Background(w.pal.line)
		w.detailActions(c, record, selected)
	})
}

// detailTabs is the strip of tabs, with the call chain's record count, the help for the
// call chain, and a line under the whole strip.
func (w *window) detailTabs(c ui.C) {
	m := w.text.Logs
	count := -1
	if trace := w.model.trace; trace != nil && trace.OpSummary != nil {
		count = trace.OpSummary.Count
	}
	ui.Row(c).FillWidth().Shrink(0).PadSides(4, 8, 0, 8).Gap(2).Items(ui.Center).FocusGroup(ui.FocusHorizontal).Children(func() {
		w.detailTab(c, "detail", detailsTabFields, m.Detail, -1)
		w.detailTab(c, "call-chain", detailsTabTrace, m.CallChain, count)
		w.info(c, m.TraceHelp)
		ui.Spacer(c)
		// The line is declared last so that it paints over the bottom of the open tab's
		// underline, as the macOS window's overlay does.
		ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
}

// detailTab is one tab: its title, the count after it when count is not negative, and a 2
// point underline in the accent color when it is the open one.
func (w *window) detailTab(c ui.C, name string, index int, title string, count int) {
	open := w.details.tab == index
	color := w.pal.tx2
	if open {
		color = w.pal.tx
	}
	ui.TabBase(c.Part(name), &w.details.tab, index, title).Shrink(0).PadSides(3, 10, 5, 10).Gap(5).Items(ui.Center).
		Children(func() {
			w.mono(c, title, detailsFontSize, color).Shrink(0)
			if count >= 0 {
				w.mono(c, "("+strconv.Itoa(count)+")", detailsFontSize, color).Shrink(0)
			}
			if open {
				ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(2).Background(w.pal.blu)
			}
		})
}

// detailFields is the Detail tab: the file and line of the record, then its JSON as the
// kernel formats it, colored. A line is never broken: the area scrolls sideways, as the macOS
// window's does, so a long value runs on past the pane's edge. Nothing is drawn while no
// record is selected.
func (w *window) detailFields(c ui.C, record core.LogRecord, selected bool) {
	_, ch := c.Canvas().CellSize(detailsFontSize)
	area := ui.Scroll(c).Sideways().Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).
		PadSides(detailsPadY, detailsPadX, detailsPadY, detailsPadX)
	if !selected {
		area.Children(func() {})
		return
	}
	relative := record.RelativePath
	if session := w.model.currentSessionPath; session != "" {
		relative = strings.ReplaceAll(relative, session+"/", "")
	}
	header := "// " + relative + "  ·  " + w.text.Logs.SourceLine(record.LineNumber)
	w.layoutDetail(record.Fields, header)
	area.Children(func() {
		w.detailRows(c, w.details.header, ch, record)
		ui.Row(c).Height(2).Shrink(0)
		w.detailRows(c, w.details.tokens, ch, record)
	})
}

// detailRows declares rows of the JSON, each as a row of monospaced spans. A row is as wide as
// the area or as its longest line, so that the area scrolls to the end of the line.
func (w *window) detailRows(c ui.C, rows []detailRow, height float32, record core.LogRecord) {
	for _, row := range rows {
		ui.Row(c).FillWidth().Height(height).Shrink(0).Children(func() {
			for _, span := range row {
				w.detailSpan(c, span, record)
			}
		})
	}
}

// detailSpan declares one span. The value of a field of the record is a link: it turns to
// the accent color under the pointer and, when clicked, adds the field to the filter.
func (w *window) detailSpan(c ui.C, span detailSpan, record core.LogRecord) {
	color := w.pal.detailColor(span.role)
	if span.field == "" {
		w.mono(c, span.text, detailsFontSize, color).Shrink(0)
		return
	}
	holder := ui.Row(c).Shrink(0).HitWith(ui.ID(c), span.text, gfx.HitOptions{Role: gfx.RoleLink, Cursor: gfx.PointerCursorHand})
	holder.Children(func() {
		w.mono(c, span.text, detailsFontSize, color).Shrink(0).StateFrom(holder).Hover(ui.Look{}.Color(w.pal.blu))
	})
	if holder.Clicked() {
		w.model.compose(core.LogFilterTerm{Kind: "field", Key: span.field, Value: record.Fields[span.field]})
	}
}

// detailTrace is the Call chain tab: that the record has no operation, or the operation's
// header and its records in time order, a list that declares only the rows in view. Choosing
// a record in it selects the record in the table.
func (w *window) detailTrace(c ui.C, record core.LogRecord, selected bool) {
	m := w.text.Logs
	_, ch := c.Canvas().CellSize(detailsFontSize)
	var records []core.LogRecord
	var summary *core.LogOpSummary
	if trace := w.model.trace; trace != nil {
		records, summary = trace.Records, trace.OpSummary
	}
	noOp := !selected || record.Op == ""
	d := &w.details
	d.records = records
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).PadSides(detailsTracePadY, detailsTracePadX, 0, detailsTracePadX).Children(func() {
		if noOp {
			w.mono(c, m.NoOperation, detailsFontSize, w.pal.tx3).Ellipsis().LineHeight(ch)
		}
		if summary != nil {
			duration := strconv.FormatInt(summary.DurationMs, 10) + " ms"
			ui.Row(c).FillWidth().Shrink(0).PadSides(0, 0, 4, 0).Children(func() {
				w.mono(c, m.Operation(summary.Op, summary.Count, duration), detailsFontSize, w.pal.tx3).Ellipsis().LineHeight(ch)
			})
		}
		ui.List(c, &d.traceList, len(records), func(row ui.ListRow) {
			w.detailTraceRow(row, summary)
		}).Label(m.CallChain).FillWidth().Grow(1).Shrink(1).MinHeight(0)
		if d.traceList.Changed() {
			if i := d.traceList.Selected(); i >= 0 && i < len(records) {
				w.model.jump(records[i].EpochMs)
			}
		}
	})
}

// detailTraceRow is one record of the call chain: its offset from the first record, its
// level, channel and event, its message, and a bar that places the offset in the operation's
// span. The macOS window gives the columns fixed widths and scrolls sideways; here the
// narrow ones keep theirs and the others shrink, the bar first, so that nothing runs out of
// the pane.
func (w *window) detailTraceRow(row ui.ListRow, summary *core.LogOpSummary) {
	c := row.C
	record := w.details.records[row.Index]
	offset := int64(0)
	if record.OpOffsetMs != nil {
		offset = *record.OpOffsetMs
	}
	element := row.Element.FillWidth().Height(detailsTraceRowHeight).PadX(4).Gap(10).Items(ui.Center)
	if w.model.selection[recordID(record)] {
		element.Background(w.pal.hl)
	}
	ui.Row(c).Width(70).Shrink(0).Items(ui.Center).Children(func() {
		w.mono(c, "+"+strconv.FormatInt(offset, 10)+" ms", detailsTraceFontSize, w.pal.tx3).Shrink(0)
	})
	ui.Row(c).Width(64).Shrink(0).Items(ui.Center).Children(func() {
		w.mono(c, levelSymbol(record.Level)+" "+string(record.Level), detailsTraceFontSize, w.pal.levelColor(record.Level)).Shrink(0)
	})
	ui.Row(c).Width(150).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
		color := channelColor(record.Channel)
		ui.Row(c).PadX(5).Shrink(1).MinWidth(0).Radius(3).Background(color.WithAlpha(0.15)).Items(ui.Center).Children(func() {
			w.mono(c, record.Channel, detailsTraceFontSize, color).Ellipsis()
		})
	})
	ui.Row(c).Width(210).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
		w.mono(c, record.Event, detailsTraceFontSize, w.pal.pur).Ellipsis()
	})
	ui.Row(c).Basis(180).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
		w.mono(c, record.Msg, detailsTraceFontSize, w.pal.tx).Ellipsis()
	})
	ui.Row(c).Width(160).Shrink(2).MinWidth(0).Items(ui.Center).Children(func() {
		span := int64(1)
		if summary != nil {
			span = max(1, summary.DurationMs)
		}
		share := min(100, 100*float32(offset)/float32(span))
		color := w.pal.pur
		if record.Level == core.LevelError {
			color = w.pal.red
		}
		ui.Row(c).WidthPercent(share).MinWidth(3).Height(6).Radius(3).Background(color.WithAlpha(0.7))
	})
}

// detailActions is the column of actions on the record, and under it the note that redacted
// values are masked. Every action needs a selected record, and tracing the operation one
// with an operation. Exporting a bundle opens the same sheet as the toolbar's Export, as in
// the macOS client.
func (w *window) detailActions(c ui.C, record core.LogRecord, selected bool) {
	m := w.text.Logs
	action := func(name, symbol, title string, disabled bool) bool {
		button := w.button(c, name, symbol, title, buttonOptions{fullWidth: true, height: detailsButtonHeight, disabled: disabled})
		return !disabled && button.Clicked()
	}
	ui.Scroll(c).Width(detailsActionsWidth).FillHeight().Shrink(0).
		Pad(detailsActionsPad).Gap(detailsActionsGap).Children(func() {
		if action("copy-json", "⧉", m.CopyJSON, !selected) {
			w.model.copyFormatted(w.model.selectedRecords(), "json")
		}
		if action("copy-markdown", "⧉", m.CopyMarkdown, !selected) {
			w.model.copyFormatted(w.model.selectedRecords(), "markdown")
		}
		if action("filter-channel", "⊙", m.FilterChannel, !selected) {
			w.model.compose(core.LogFilterTerm{Kind: "channel", Value: record.Channel})
		}
		if action("trace-operation", "⇢", m.TraceOperation, !selected || record.Op == "") {
			w.details.tab = detailsTabTrace
			w.model.compose(core.LogFilterTerm{Kind: "op", Value: record.Op})
		}
		if action("reveal", "↗", m.RevealInFinder, !selected) {
			w.revealRecord()
		}
		if action("export-bundle", "⇩", m.ExportBundle, !selected) {
			w.openExport()
		}

		_, ch := c.Canvas().CellSize(detailsNoteSize)
		ui.Wrap(c, m.RedactedNote).Mono().FontSize(detailsNoteSize).Color(w.pal.tx3).FillWidth().Shrink(0).LineHeight(ch)
	})
}
