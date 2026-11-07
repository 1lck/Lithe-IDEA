package logwindow

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/flex"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// The identities of the details pane.
var (
	detailsScope = tree.Sub(page, tree.Name("details"))

	detailsTabID      = tree.ID(detailsScope, "detail-tab")
	detailsTraceTabID = tree.ID(detailsScope, "trace-tab")
	detailsHelpID     = tree.ID(detailsScope, "trace-help")

	// The scrolling areas of the two tabs and of the column of actions.
	detailsFieldsID  = tree.ID(detailsScope, "fields")
	detailsTraceID   = tree.ID(detailsScope, "trace")
	detailsActionsID = tree.ID(detailsScope, "actions")

	detailsCopyJSONID     = tree.ID(detailsScope, "copy-json")
	detailsCopyMarkdownID = tree.ID(detailsScope, "copy-markdown")
	detailsChannelID      = tree.ID(detailsScope, "filter-channel")
	detailsOperationID    = tree.ID(detailsScope, "trace-operation")
	detailsRevealID       = tree.ID(detailsScope, "reveal")
	detailsExportID       = tree.ID(detailsScope, "export")

	// detailsLinks are the field values of the JSON that filter the log when clicked, and
	// detailsTraceRows the records of the call chain.
	detailsLinks     = tree.Sub(detailsScope, tree.Name("field-links"))
	detailsTraceRows = tree.Sub(detailsScope, tree.Name("trace-rows"))
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
	// detailsGutter is kept free at the trailing edge of the JSON so that a scroll bar never
	// covers the last column.
	detailsGutter = 8
	// detailsMinCols is the fewest columns the JSON is wrapped to, however narrow the window.
	detailsMinCols = 16

	// The call chain's rows: their height, the font, the padding of the list, and how many
	// rows are declared beyond the visible ones so that a fast scroll never shows a gap.
	detailsTraceRowHeight = 22
	detailsTraceFontSize  = 11.5
	detailsTracePadX      = 10
	detailsTracePadY      = 6
	detailsOverscan       = 3
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
// the JSON of the selected record, tokenized and wrapped, so that a frame with the same
// record and the same width does no work on the text.
type detailsState struct {
	// tab is detailsTabFields or detailsTabTrace.
	tab int

	// tokens are the lines of the kernel's JSON for the record tokenID, whose text was
	// tokenText.
	tokens             []detailRow
	tokenID, tokenText string
	tokenized          bool

	// header and body are the note and the tokens wrapped to laidCols columns, for the note
	// laidHeader.
	header, body []detailRow
	laidCols     int
	laidHeader   string
	laidOut      bool
}

// detailsToken finds the tokens the JSON is colored by: a string, true, false and null, and a
// number. It is the expression of the macOS window's highlighter, so both windows color the
// same text the same way. The text itself is the kernel's formatted copy.
var detailsToken = regexp.MustCompile(`"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?`)

// detailColor is the color of a role.
func (p palette) detailColor(role detailRole) ui.Color {
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

// wrapDetailRows breaks every line at cols cells of a monospaced font. Viva has no horizontal scrolling and a
// Text is one clipped line, so a long line continues on the next row instead of running out
// of the pane where the macOS window would let the user scroll sideways.
func wrapDetailRows(lines []detailRow, cols int) []detailRow {
	var rows []detailRow
	for _, line := range lines {
		rows = append(rows, wrapDetailRow(line, cols)...)
	}
	return rows
}

// wrapDetailRow breaks one line at cols cells of a monospaced font, where a wide character,
// such as a Chinese one, takes two. An empty line stays one empty row.
func wrapDetailRow(line detailRow, cols int) []detailRow {
	cols = max(cols, 1)
	var rows []detailRow
	var row detailRow
	used := 0
	for _, span := range line {
		for span.text != "" {
			if used == cols {
				rows = append(rows, row)
				row, used = nil, 0
			}
			room := cols - used
			if n := monoCells(span.text); n <= room {
				row = append(row, span)
				used += n
				break
			}
			cut := detailCellOffset(span.text, room)
			if cut == 0 && used > 0 {
				// The next character is wider than what is left of the row.
				rows = append(rows, row)
				row, used = nil, 0
				continue
			}
			if cut == 0 {
				// A character wider than a whole row takes a row of its own.
				_, cut = utf8.DecodeRuneInString(span.text)
			}
			row = append(row, detailSpan{text: span.text[:cut], role: span.role, field: span.field})
			rows = append(rows, row)
			row, used = nil, 0
			span.text = span.text[cut:]
		}
	}
	return append(rows, row)
}

// detailCellOffset is the byte offset of the longest start of s that takes at most cells
// cells of a monospaced font.
func detailCellOffset(s string, cells int) int {
	for i, r := range s {
		if cells -= vivatext.CellWidth(r); cells < 0 {
			return i
		}
	}
	return len(s)
}

// wrapDetailWords breaks s into lines of at most cols cells of a monospaced font, between
// words where it can and inside a word that is longer than a line, such as a run of Chinese,
// whose characters take two cells each. The note under the actions is set by it: a paragraph
// of Viva measures the text it wraps with the proportional font, which is narrower than the
// monospaced font the note is drawn in.
func wrapDetailWords(s string, cols int) []string {
	cols = max(cols, 1)
	var lines []string
	var line []rune
	used := 0
	flush := func() {
		if len(line) > 0 {
			lines = append(lines, string(line))
			line, used = line[:0], 0
		}
	}
	for _, word := range strings.Fields(s) {
		width := monoCells(word)
		if len(line) > 0 && used+1+width <= cols {
			line = append(append(line, ' '), []rune(word)...)
			used += 1 + width
			continue
		}
		flush()
		for _, r := range word {
			cells := vivatext.CellWidth(r)
			if used+cells > cols && len(line) > 0 {
				flush()
			}
			line = append(line, r)
			used += cells
		}
	}
	flush()
	return lines
}

// drawDetails is the details pane: the tabs and the selected record's JSON or call chain on
// the left, the actions on the right. The caller draws the line above it.
func (w *window) drawDetails(f *flex.Frame) {
	record, selected := w.model.selectedRecord()
	f.Row().Fill().Children(func() {
		f.Column().Grow(1).Shrink(1).MinWidth(0).FillHeight().Children(func() {
			w.drawDetailTabs(f)
			if w.details.tab == detailsTabTrace {
				w.drawDetailTrace(f, record, selected)
			} else {
				w.drawDetailFields(f, record, selected)
			}
		})
		f.Row().Width(1).FillHeight().Shrink(0).Background(w.pal.line)
		w.drawDetailActions(f, record, selected)
	})
}

// drawDetailTabs is the strip of tabs, with the call chain's record count, the help for the
// call chain, and a line under the whole strip.
func (w *window) drawDetailTabs(f *flex.Frame) {
	m := w.text.Logs
	count := -1
	if trace := w.model.trace; trace != nil && trace.OpSummary != nil {
		count = trace.OpSummary.Count
	}
	f.Row().FillWidth().Shrink(0).PadSides(4, 8, 0, 8).Gap(2).Items(flex.Center).Children(func() {
		w.drawDetailTab(f, detailsTabID, detailsTabFields, m.Detail, -1)
		w.drawDetailTab(f, detailsTraceTabID, detailsTabTrace, m.CallChain, count)
		w.info(f, detailsHelpID, m.TraceHelp)
		f.Spacer()
		// The line is declared last so that it paints over the bottom of the open tab's
		// underline, as the macOS window's overlay does.
		f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
}

// drawDetailTab is one tab: its title, the count after it when count is not negative, and a
// 2 point underline in the accent color when it is the open one.
func (w *window) drawDetailTab(f *flex.Frame, id ui.ID, index int, title string, count int) {
	open := w.details.tab == index
	color := w.pal.tx2
	if open {
		color = w.pal.tx
	}
	tab := f.Row().Shrink(0).PadSides(3, 10, 5, 10).Gap(5).Items(flex.Center).
		HitWith(id, title, ui.HitOptions{Role: ui.RoleTab, Selected: open})
	tab.Children(func() {
		w.mono(f, title, detailsFontSize, color).Shrink(0)
		if count >= 0 {
			w.mono(f, "("+strconv.Itoa(count)+")", detailsFontSize, color).Shrink(0)
		}
		if open {
			f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(2).Background(w.pal.blu)
		}
	})
	if tab.Clicked() {
		w.details.tab = index
	}
}

// layoutDetail makes the tokens of the selected record's JSON when the record or its text
// changed, and wraps the note and the tokens to cols columns when they or the width changed.
func (w *window) layoutDetail(fields map[string]string, header string, cols int) {
	d := &w.details
	id, text := w.model.detailID, w.model.detailText
	if !d.tokenized || d.tokenID != id || d.tokenText != text {
		d.tokens = tokenizeDetailJSON(text, fields)
		d.tokenID, d.tokenText, d.tokenized = id, text, true
		d.laidOut = false
	}
	if d.laidOut && d.laidCols == cols && d.laidHeader == header {
		return
	}
	d.header = wrapDetailRows([]detailRow{{{text: header, role: detailNote}}}, cols)
	d.body = wrapDetailRows(d.tokens, cols)
	d.laidCols, d.laidHeader, d.laidOut = cols, header, true
}

// drawDetailFields is the Detail tab: the file and line of the record, then its JSON as the
// kernel formats it, colored. Nothing is drawn while no record is selected.
func (w *window) drawDetailFields(f *flex.Frame, record core.LogRecord, selected bool) {
	cw, ch := f.Canvas().CellSize(detailsFontSize)
	area := f.ScrollArea(detailsFieldsID).FillWidth().Grow(1).Shrink(1).MinHeight(0).
		PadSides(detailsPadY, detailsPadX, detailsPadY, detailsPadX)
	if !selected {
		area.Children(func() {})
		return
	}
	// The pane's width is known without a layout: the window less the channel list, the
	// column of actions and the lines between them.
	width := f.Bounds().Width - sidebarWidth - 1 - 1 - detailsActionsWidth - 2*detailsPadX - detailsGutter
	cols := max(detailsMinCols, int(width/cw))
	relative := record.RelativePath
	if session := w.model.currentSessionPath; session != "" {
		relative = strings.ReplaceAll(relative, session+"/", "")
	}
	header := "// " + relative + "  ·  " + w.text.Logs.SourceLine(record.LineNumber)
	w.layoutDetail(record.Fields, header, cols)
	area.Children(func() {
		link := 0
		w.drawDetailRows(f, w.details.header, ch, record, &link)
		f.Row().Height(2).Shrink(0)
		w.drawDetailRows(f, w.details.body, ch, record, &link)
	})
}

// drawDetailRows declares rows of the JSON, each as a row of monospaced spans. link counts the
// clickable spans of the frame so that each gets an identity of its own.
func (w *window) drawDetailRows(f *flex.Frame, rows []detailRow, height float32, record core.LogRecord, link *int) {
	for _, row := range rows {
		f.Row().FillWidth().Height(height).Shrink(0).Children(func() {
			for _, span := range row {
				w.drawDetailSpan(f, span, record, link)
			}
		})
	}
}

// drawDetailSpan declares one span. The value of a field of the record is a link: it turns to
// the accent color under the pointer and, when clicked, adds the field to the filter.
func (w *window) drawDetailSpan(f *flex.Frame, span detailSpan, record core.LogRecord, link *int) {
	color := w.pal.detailColor(span.role)
	if span.field == "" {
		w.mono(f, span.text, detailsFontSize, color).Shrink(0)
		return
	}
	id := detailsLinks.At(*link)
	*link++
	holder := f.Row().Shrink(0).HitWith(id, span.text, ui.HitOptions{Role: ui.RoleLink, Cursor: ui.PointerCursorHand})
	holder.Children(func() {
		w.mono(f, span.text, detailsFontSize, color).Shrink(0).StateFrom(holder).Hover(flex.Look{}.Color(w.pal.blu))
	})
	if holder.Clicked() {
		w.model.compose(core.LogFilterTerm{Kind: "field", Key: span.field, Value: record.Fields[span.field]})
	}
}

// drawDetailTrace is the Call chain tab: that the record has no operation, or the operation's
// header and its records in time order. Only the rows in view are declared.
func (w *window) drawDetailTrace(f *flex.Frame, record core.LogRecord, selected bool) {
	m := w.text.Logs
	_, ch := f.Canvas().CellSize(detailsFontSize)
	var records []core.LogRecord
	var summary *core.LogOpSummary
	if trace := w.model.trace; trace != nil {
		records, summary = trace.Records, trace.OpSummary
	}
	noOp := !selected || record.Op == ""
	top := float32(detailsTracePadY)
	if noOp {
		top += ch
	}
	if summary != nil {
		top += ch + 4
	}
	state := w.view.ScrollState(detailsTraceID)
	viewport := state.Viewport
	if viewport <= 0 {
		// The first frame does not know the area's height yet.
		viewport = 800
	}
	first := max(0, int((state.Offset-top)/detailsTraceRowHeight)-detailsOverscan)
	last := min(len(records), int((state.Offset+viewport-top)/detailsTraceRowHeight)+detailsOverscan+1)
	first = min(first, last)
	f.ScrollArea(detailsTraceID).FillWidth().Grow(1).Shrink(1).MinHeight(0).
		PadSides(detailsTracePadY, detailsTracePadX, detailsTracePadY, detailsTracePadX).Children(func() {
		if noOp {
			w.mono(f, m.NoOperation, detailsFontSize, w.pal.tx3).Ellipsis().LineHeight(ch)
		}
		if summary != nil {
			duration := strconv.FormatInt(summary.DurationMs, 10) + " ms"
			f.Row().FillWidth().Shrink(0).PadSides(0, 0, 4, 0).Children(func() {
				w.mono(f, m.Operation(summary.Op, summary.Count, duration), detailsFontSize, w.pal.tx3).Ellipsis().LineHeight(ch)
			})
		}
		if first > 0 {
			f.Row().Height(float32(first) * detailsTraceRowHeight).Shrink(0)
		}
		for i := first; i < last; i++ {
			w.drawDetailTraceRow(f, i, records[i], summary)
		}
		if rest := len(records) - last; rest > 0 {
			f.Row().Height(float32(rest) * detailsTraceRowHeight).Shrink(0)
		}
	})
}

// drawDetailTraceRow is one record of the call chain: its offset from the first record, its
// level, channel and event, its message, and a bar that places the offset in the operation's
// span. A click selects the record in the table. The macOS window gives the columns fixed
// widths and scrolls sideways; here the narrow ones keep theirs and the others shrink, the
// bar first, so that nothing runs out of the pane.
func (w *window) drawDetailTraceRow(f *flex.Frame, i int, record core.LogRecord, summary *core.LogOpSummary) {
	offset := int64(0)
	if record.OpOffsetMs != nil {
		offset = *record.OpOffsetMs
	}
	selected := w.model.selection[recordID(record)]
	row := f.Row().FillWidth().Height(detailsTraceRowHeight).Shrink(0).PadX(4).Gap(10).Items(flex.Center).
		HitWith(detailsTraceRows.At(i), record.Msg, ui.HitOptions{Role: ui.RoleOption, Selected: selected})
	if selected {
		row = row.Background(w.pal.hl)
	}
	row.Children(func() {
		f.Row().Width(70).Shrink(0).Items(flex.Center).Children(func() {
			w.mono(f, "+"+strconv.FormatInt(offset, 10)+" ms", detailsTraceFontSize, w.pal.tx3).Shrink(0)
		})
		f.Row().Width(64).Shrink(0).Items(flex.Center).Children(func() {
			w.mono(f, levelSymbol(record.Level)+" "+string(record.Level), detailsTraceFontSize, w.pal.levelColor(record.Level)).Shrink(0)
		})
		f.Row().Width(150).Shrink(1).MinWidth(0).Items(flex.Center).Children(func() {
			color := channelColor(record.Channel)
			f.Row().PadX(5).Shrink(1).MinWidth(0).Radius(3).Background(color.WithAlpha(0.15)).Items(flex.Center).Children(func() {
				w.mono(f, record.Channel, detailsTraceFontSize, color).Ellipsis()
			})
		})
		f.Row().Width(210).Shrink(1).MinWidth(0).Items(flex.Center).Children(func() {
			w.mono(f, record.Event, detailsTraceFontSize, w.pal.pur).Ellipsis()
		})
		f.Row().Basis(180).Grow(1).Shrink(1).MinWidth(0).Items(flex.Center).Children(func() {
			w.mono(f, record.Msg, detailsTraceFontSize, w.pal.tx).Ellipsis()
		})
		f.Row().Width(160).Shrink(2).MinWidth(0).Items(flex.Center).Children(func() {
			span := int64(1)
			if summary != nil {
				span = max(1, summary.DurationMs)
			}
			share := min(100, 100*float32(offset)/float32(span))
			color := w.pal.pur
			if record.Level == core.LevelError {
				color = w.pal.red
			}
			f.Row().WidthPercent(share).MinWidth(3).Height(6).Radius(3).Background(color.WithAlpha(0.7))
		})
	})
	if row.Clicked() {
		w.model.jump(record.EpochMs)
	}
}

// drawDetailActions is the column of actions on the record, and under it the note that
// redacted values are masked. Every action needs a selected record, and tracing the
// operation one with an operation. The export of a diagnostics bundle has no counterpart in
// this client yet, so its button is drawn dimmed.
func (w *window) drawDetailActions(f *flex.Frame, record core.LogRecord, selected bool) {
	m := w.text.Logs
	action := func(id ui.ID, symbol, title string, disabled bool) bool {
		button := w.button(f, id, symbol, title, buttonOptions{fullWidth: true, height: detailsButtonHeight, disabled: disabled})
		return !disabled && button.Clicked()
	}
	f.ScrollArea(detailsActionsID).Width(detailsActionsWidth).FillHeight().Shrink(0).
		Pad(detailsActionsPad).Gap(detailsActionsGap).Children(func() {
		if action(detailsCopyJSONID, "⧉", m.CopyJSON, !selected) {
			w.model.copyFormatted(w.model.selectedRecords(), "json")
		}
		if action(detailsCopyMarkdownID, "⧉", m.CopyMarkdown, !selected) {
			w.model.copyFormatted(w.model.selectedRecords(), "markdown")
		}
		if action(detailsChannelID, "⊙", m.FilterChannel, !selected) {
			w.model.compose(core.LogFilterTerm{Kind: "channel", Value: record.Channel})
		}
		if action(detailsOperationID, "⇢", m.TraceOperation, !selected || record.Op == "") {
			w.details.tab = detailsTabTrace
			w.model.compose(core.LogFilterTerm{Kind: "op", Value: record.Op})
		}
		if action(detailsRevealID, "↗", m.RevealInFinder, !selected) {
			w.revealRecord()
		}
		action(detailsExportID, "⇩", m.ExportBundle, true)

		cw, ch := f.Canvas().CellSize(detailsNoteSize)
		cols := int((detailsActionsWidth - 2*detailsActionsPad) / cw)
		for _, line := range wrapDetailWords(m.RedactedNote, cols) {
			w.mono(f, line, detailsNoteSize, w.pal.tx3).Shrink(0).Height(ch)
		}
	})
}
