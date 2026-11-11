package workbench

import (
	"context"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// The Console tab of the Git tool window lists the Git commands every project of the window
// ran and what they wrote. Core keeps the commands in the window's journal (core.GitConsole)
// and says how to draw them (git.consolePresentation); this file holds the tab's state: it
// takes snapshots of the journal, asks Core to present the records that changed, and
// flattens the records into the rows of one virtualized list, with the texts the copy
// actions put on the clipboard. gitconsole_view.go draws the toolbar, the rows and the
// context menu.

// The identities of the console page and its search field, named in the page's own scope so
// that the window's input routing finds the field as the page's.
var (
	consolePage     = tree.Feature("git-console")
	consoleSearchID = tree.ID(consolePage, "search")
)

// The words of Core's presentation the console reads: the kinds of fragment that fold, and
// the fragment ids of a search hit outside the command and the output.
const (
	consoleFragmentConfiguration = "configuration"
	consoleFragmentProgress      = "progress"
	consoleHitRepository         = "repository"
	consoleHitError              = "error"
	consoleHitProgress           = "progress"
)

// consoleTone is the color a row's text is drawn in.
type consoleTone uint8

// The tones of the console's rows: ordinary output, secondary notes and failures.
const (
	consoleToneText consoleTone = iota
	consoleToneSubtle
	consoleToneError
)

// consolePart is the kind of a row, which with its record and index names the row.
type consolePart uint8

// The kinds of row, in the order a record's rows come in after the two console-wide notes.
const (
	consolePartOmitted consolePart = iota
	consolePartUnavailable
	consolePartHeader
	consolePartTruncated
	consolePartLine
	consolePartProgress
	consolePartNotice
	consolePartUnconfirmed
	consolePartExit
	consolePartError
)

// consoleRowID names a row by what it shows, so that the row keeps its list key while rows
// are added above it or a fold around it opens: a line row is named by its record and line
// index, and a closed fold by the line it shows.
type consoleRowID struct {
	// record is the record's ID, empty for a console-wide note.
	record string
	part   consolePart
	// index is the line of a line row and the line of the error of an error row.
	index int
}

// consoleFold names a fold by its record and the fragment it starts at, so that whether it is
// open survives a new presentation of the record.
type consoleFold struct {
	record, fragment string
}

// consoleSpanKind is what a stretch of a row's text says, which picks the color it is drawn in.
type consoleSpanKind uint8

// The kinds of stretch a header is made of; every other row is one stretch of text.
const (
	// consoleSpanText is drawn in the row's tone.
	consoleSpanText consoleSpanKind = iota
	// consoleSpanStamp is when the command started, drawn subtle.
	consoleSpanStamp
	// consoleSpanRepository is the repository the command ran in, drawn in the accent color.
	consoleSpanRepository
	// consoleSpanFold is the command's temporary configuration, its preview while the fold
	// is closed and all of it while open: a click on it opens or closes the row's fold.
	consoleSpanFold
	// consoleSpanCommand is the command the record ran, git and its arguments, drawn in its
	// own color so that it stands apart from the output under it.
	consoleSpanCommand
)

// consoleSpan is a stretch of a row's text of one kind: from where the span before it ends,
// or the start of the text, to the byte offset end.
type consoleSpan struct {
	end  int
	kind consoleSpanKind
}

// consoleRow is one row of the console's list.
type consoleRow struct {
	id consoleRowID
	// key is the row's list key, unique among the rows and kept for the same id.
	key int
	// record is the index of the row's record in the snapshot, or -1 for a console-wide
	// note, which has no context menu.
	record int
	text   string
	// spans are the stretches text is made of, in order; none is one stretch of text.
	spans []consoleSpan
	tone  consoleTone
	// badge is a note drawn after the text, the running mark of a header.
	badge string
	// fold, with toggle set, is the fold the row's toggle opens or closes; toggle is the
	// toggle's text and folded says it opens the fold. inline says the toggle is the
	// configuration in the header's own text, its consoleSpanFold spans, and toggle only
	// names it for assistive technology; otherwise toggle is drawn after the text.
	fold   consoleFold
	toggle string
	folded bool
	inline bool
	// first and last are the lines of the record's output the row stands for: one line, or
	// the lines of a closed fold. They are meaningful for line rows only.
	first, last int
	// matched says a search hit is on the row.
	matched bool
}

// consoleHitKey names a search hit across presentations, so that the hit the user stepped
// to stays current when the rows are flattened again: line is the output line or -1, and
// nth tells apart the hits Core reports in a row for the same place.
type consoleHitKey struct {
	record, fragment string
	line, nth        int
}

// consoleHit is a search hit placed on the rows.
type consoleHit struct {
	key consoleHitKey
	// row is the row the hit is drawn on.
	row int
	// fold, when its fragment is set, is a closed fold the hit is inside, which stepping to
	// the hit opens.
	fold consoleFold
}

// consolePresented is Core's presentation of one record, with what it was made from.
type consolePresented struct {
	entry core.GitConsoleEntry
	hits  []core.GitConsoleHit
	// revision and lines are the record's revision and number of lines the presentation
	// was made for; search is the search it matched.
	revision uint64
	lines    int
	search   string
	// raw says Core gave no entry for the record, which is then drawn from its lines; it
	// keeps the record from being asked for again until it changes.
	raw bool
}

// consoleView is the Console tab's state, window-wide like the journal.
type consoleView struct {
	// stale is set by gitConsoleChanged, on any goroutine, when the journal changed; the next
	// paint reads the journal again. It is the only field touched off the window thread.
	stale atomic.Bool
	// read says snapshot has been taken.
	read     bool
	snapshot core.GitConsoleSnapshot
	// presented is Core's presentation of each record, by record ID.
	presented map[string]*consolePresented
	// presenting says a presentation request is in flight; only one ever is.
	presenting bool
	// failed says the last request failed, for the snapshot revision and search it names,
	// which are not asked for again; the records are drawn from their lines meanwhile.
	failed         bool
	failedRevision uint64
	failedSearch   string
	search         ui.Field
	// searchFor is the search the rows were flattened for: the field's text, cut to what
	// Core accepts.
	searchFor string
	// open holds the folds the user opened.
	open map[consoleFold]bool
	// wrap says long lines break into several instead of ending in an ellipsis.
	wrap bool
	list ui.ListState
	// drawRow is drawConsoleRow, made once because a method value made in each paint
	// allocates.
	drawRow func(ui.ListRow)
	rows    []consoleRow
	// spans holds the spans of all the rows, which slice it; it is reused by each
	// flattening.
	spans []consoleSpan
	// width is the width of the list as it was last drawn, which the rows are broken or cut
	// to, or 0 before it was; measure, made once, records it and asks for a paint when it
	// changed. pieces is the layout of the row being declared, reused from row to row.
	width   float32
	measure func(*ui.DrawContext)
	pieces  []consolePiece
	// font is the run output's font the rows are drawn in, taken as the list is declared,
	// with the width of its character cell and the height of a line in it.
	font         scopeFont
	cellW, lineH float32
	// keys are the list keys of the rows by id; spareKeys is the map of the flattening
	// before, reused so that flattening allocates no map once warm. nextKey is the key a
	// new row gets.
	keys, spareKeys map[consoleRowID]int
	nextKey         int
	// dirty says the rows must be flattened again before they are drawn.
	dirty bool
	// hits are the search hits placed on the rows, in the order Core reported them; total
	// is the exact number of matches, and counted says every record has been presented
	// for the current search, so total is known.
	hits    []consoleHit
	total   int
	counted bool
	// current is the hit the user stepped to, when hasCurrent is set; hitIndex and hitRow
	// are where it is now, or -1.
	current    consoleHitKey
	hasCurrent bool
	hitIndex   int
	hitRow     int
	// detach says the list was just scrolled to a hit and must stop following its end.
	detach bool
}

// gitConsoleChanged is the journal's change callback. Core calls it on any goroutine, so it
// only marks the view stale and asks for a paint, which reads the journal on the window
// thread.
func (a *App) gitConsoleChanged() {
	a.consoleView.stale.Store(true)
	a.invalidator.Invalidate()
}

// syncConsole brings the rows up to date before a paint draws them: it takes a snapshot when
// the journal changed, takes in a new search, asks Core to present what changed and flattens
// the rows again when anything they show did.
func (a *App) syncConsole() {
	v := &a.consoleView
	if v.stale.Swap(false) || !v.read {
		if revision := a.gitConsole.Revision(); !v.read || revision != v.snapshot.Revision {
			v.snapshot = a.gitConsole.Snapshot()
			v.read, v.dirty = true, true
			v.prune()
		}
	}
	if search := consoleSearchText(v.search.Text()); search != v.searchFor {
		v.searchFor, v.dirty, v.hasCurrent = search, true, false
	}
	a.presentConsole()
	if v.dirty {
		v.flatten(&a.text.Console, time.Local)
	}
}

// presentConsole asks Core, in the background, to present the records whose presentation is
// missing or was made for another revision or search. One request is in flight at a time:
// when it lands, the paint that follows asks for what changed meanwhile. A request that
// failed is not repeated until the journal or the search changes.
func (a *App) presentConsole() {
	v := &a.consoleView
	if v.presenting || v.failed && v.failedRevision == v.snapshot.Revision && v.failedSearch == v.searchFor {
		return
	}
	var records []core.GitConsoleRecord
	for i := range v.snapshot.Records {
		r := &v.snapshot.Records[i]
		if p := v.presented[r.ID]; p == nil || p.revision != r.Revision || p.search != v.searchFor {
			records = append(records, *r)
		}
	}
	if len(records) == 0 {
		return
	}
	kernel, search, revision := a.kernel, v.searchFor, v.snapshot.Revision
	v.presenting = true
	a.background(nil, kernelCallTimeout, func(ctx context.Context) func(*App) {
		presentation, err := kernel.GitConsolePresentation(ctx, records, search)
		return func(a *App) { a.landConsolePresentation(records, search, revision, presentation, err) }
	})
}

// landConsolePresentation keeps what a presentation request answered for records, which it
// made for search when the snapshot had revision.
func (a *App) landConsolePresentation(records []core.GitConsoleRecord, search string, revision uint64, presentation core.GitConsolePresentation, err error) {
	v := &a.consoleView
	v.presenting, v.dirty = false, true
	if err != nil {
		v.failed, v.failedRevision, v.failedSearch = true, revision, search
		return
	}
	v.failed = false
	if v.presented == nil {
		v.presented = map[string]*consolePresented{}
	}
	hits := map[string][]core.GitConsoleHit{}
	for _, hit := range presentation.Hits {
		hits[hit.RecordID] = append(hits[hit.RecordID], hit)
	}
	entries := make(map[string]int, len(presentation.Entries))
	for i := range presentation.Entries {
		entries[presentation.Entries[i].ID] = i
	}
	for i := range records {
		r := &records[i]
		p := &consolePresented{hits: hits[r.ID], revision: r.Revision, lines: len(r.Lines), search: search}
		if at, ok := entries[r.ID]; ok {
			p.entry = presentation.Entries[at]
		} else {
			p.raw = true
		}
		v.presented[r.ID] = p
	}
	v.prune()
}

// prune forgets the presentations and open folds of records the snapshot no longer has.
func (v *consoleView) prune() {
	live := make(map[string]bool, len(v.snapshot.Records))
	for i := range v.snapshot.Records {
		live[v.snapshot.Records[i].ID] = true
	}
	for id := range v.presented {
		if !live[id] {
			delete(v.presented, id)
		}
	}
	for fold := range v.open {
		if !live[fold.record] {
			delete(v.open, fold)
		}
	}
}

// consoleSearchText is the search text as Core accepts it: at most core.GitConsoleSearchLimit
// bytes, cut where a character starts.
func consoleSearchText(text string) string {
	if len(text) <= core.GitConsoleSearchLimit {
		return text
	}
	end := core.GitConsoleSearchLimit
	for end > 0 && !utf8.RuneStart(text[end]) {
		end--
	}
	return text[:end]
}

// rowKey is the list key of row i. The list may ask for a row the rows no longer have while
// it settles, which gets a key no row has.
func (v *consoleView) rowKey(i int) int {
	if i < 0 || i >= len(v.rows) {
		return -1 - i
	}
	return v.rows[i].key
}

// rowLabel is the text of row i, which assistive technology reads and typing finds.
func (v *consoleView) rowLabel(i int) string {
	if i < 0 || i >= len(v.rows) {
		return ""
	}
	return v.rows[i].text
}

// add appends row with the key its id had in old, the keys of the flattening before, or a new
// one, and returns its index.
func (v *consoleView) add(old map[consoleRowID]int, row consoleRow) int {
	key, ok := old[row.id]
	if _, taken := v.keys[row.id]; !ok || taken {
		key = v.nextKey
		v.nextKey++
	}
	row.key = key
	v.keys[row.id] = key
	v.rows = append(v.rows, row)
	return len(v.rows) - 1
}

// addLines appends a row for each of the lines [from, to) of r, the record at index.
func (v *consoleView) addLines(old map[consoleRowID]int, index int, r *core.GitConsoleRecord, from, to int) {
	for j := from; j < to; j++ {
		v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartLine, index: j}, record: index, text: consoleExpandTabs(r.Lines[j].Text), first: j, last: j})
	}
}

// endSpan ends the span of kind that runs to end in the spans of the row whose spans start at
// index start of v.spans. A span that would be empty is left out.
func (v *consoleView) endSpan(start, end int, kind consoleSpanKind) {
	from := 0
	if n := len(v.spans); n > start {
		from = v.spans[n-1].end
	}
	if end > from {
		v.spans = append(v.spans, consoleSpan{end: end, kind: kind})
	}
}

// rowSpans is the spans of the row that start at index start of v.spans, capped so that no
// later row's spans are appended into them.
func (v *consoleView) rowSpans(start int) []consoleSpan {
	n := len(v.spans)
	return v.spans[start:n:n]
}

// prefixSpans adds the spans of a header that starts with consoleHeaderParts' stamp and
// repository, joined by a space, and is n bytes long, the rest of it the command, and returns
// them.
func (v *consoleView) prefixSpans(stamp, repository string, n int) []consoleSpan {
	start := len(v.spans)
	v.endSpan(start, len(stamp), consoleSpanStamp)
	v.endSpan(start, len(stamp)+1, consoleSpanText)
	v.endSpan(start, len(stamp)+1+len(repository), consoleSpanRepository)
	v.endSpan(start, n, consoleSpanCommand)
	return v.rowSpans(start)
}

// consoleTabStop is how many cells apart the stops a tab in a command's output moves to are,
// as a terminal sets them.
const consoleTabStop = 8

// consoleExpandTabs is line with each tab replaced by the spaces to the next tab stop, so that
// the fixed-pitch font draws the columns git aligns with tabs, as git status does, where a
// terminal does. A line without a tab is returned as it is.
func consoleExpandTabs(line string) string {
	if strings.IndexByte(line, '\t') < 0 {
		return line
	}
	var b strings.Builder
	b.Grow(len(line) + consoleTabStop)
	cells := 0
	for _, r := range line {
		if r == '\t' {
			n := consoleTabStop - cells%consoleTabStop
			b.WriteString(strings.Repeat(" ", n))
			cells += n
			continue
		}
		b.WriteRune(r)
		cells += vivatext.CellWidth(r)
	}
	return b.String()
}

// flatten turns the snapshot into the rows of the list and places the search hits on them.
// text is the language's words and loc the zone the start times are shown in.
func (v *consoleView) flatten(text *i18n.ConsoleMessages, loc *time.Location) {
	v.dirty = false
	old := v.keys
	v.keys = v.spareKeys
	if v.keys == nil {
		v.keys = map[consoleRowID]int{}
	}
	clear(v.keys)
	v.rows, v.spans, v.hits, v.total, v.counted = v.rows[:0], v.spans[:0], v.hits[:0], 0, true
	if v.snapshot.Omitted {
		v.add(old, consoleRow{id: consoleRowID{part: consolePartOmitted}, record: -1, text: text.HistoryTruncated, tone: consoleToneSubtle})
	}
	if v.failed {
		v.add(old, consoleRow{id: consoleRowID{part: consolePartUnavailable}, record: -1, text: text.Unavailable, tone: consoleToneSubtle})
	}
	for i := range v.snapshot.Records {
		v.flattenRecord(old, i, &v.snapshot.Records[i], text, loc)
	}
	v.hitIndex, v.hitRow = -1, -1
	if v.hasCurrent {
		for i, hit := range v.hits {
			if hit.key == v.current {
				v.hitIndex, v.hitRow = i, hit.row
				break
			}
		}
	}
	v.spareKeys = old
}

// flattenRecord appends the rows of r, the record at index: its header, its output, its
// status and its error. It uses Core's presentation while that still describes the lines r
// has, even one made before more lines came, and draws the rest from the lines themselves.
func (v *consoleView) flattenRecord(old map[consoleRowID]int, index int, r *core.GitConsoleRecord, text *i18n.ConsoleMessages, loc *time.Location) {
	p := v.presented[r.ID]
	// A presentation made before lines were dropped from the front no longer indexes them.
	use := p != nil && !p.raw && !v.failed && (p.revision == r.Revision || !r.Truncated && p.lines <= len(r.Lines))
	exact := use && p.revision == r.Revision
	searching := v.searchFor != ""
	if searching {
		if p != nil && p.search == v.searchFor {
			v.total += p.entry.Matches
		} else {
			v.counted = false
		}
	}

	header := consoleRow{id: consoleRowID{record: r.ID, part: consolePartHeader}, record: index}
	if use {
		entry := &p.entry
		label := entry.RepositoryLabel
		if label == "" {
			label = r.Root
		}
		var fold consoleFold
		count := 0
		for _, fragment := range entry.Command {
			if fragment.Kind == consoleFragmentConfiguration {
				if fold.fragment == "" {
					fold = consoleFold{record: r.ID, fragment: fragment.ID}
				}
				count += fragment.Count
			}
		}
		folded := fold.fragment != "" && !v.open[fold]
		start := len(v.spans)
		stamp, repository := consoleHeaderParts(r.Started, label, loc)
		var b strings.Builder
		b.WriteString(stamp)
		v.endSpan(start, b.Len(), consoleSpanStamp)
		b.WriteByte(' ')
		v.endSpan(start, b.Len(), consoleSpanText)
		b.WriteString(repository)
		v.endSpan(start, b.Len(), consoleSpanRepository)
		if len(entry.Command) > 0 {
			b.WriteString(" git")
		}
		for _, fragment := range entry.Command {
			part := fragment.Text
			configuration := fragment.Kind == consoleFragmentConfiguration
			if configuration && folded {
				part = fragment.Preview
			}
			if part == "" {
				continue
			}
			b.WriteByte(' ')
			if configuration {
				v.endSpan(start, b.Len(), consoleSpanCommand)
				b.WriteString(part)
				v.endSpan(start, b.Len(), consoleSpanFold)
				continue
			}
			b.WriteString(part)
		}
		v.endSpan(start, b.Len(), consoleSpanCommand)
		header.text, header.spans = b.String(), v.rowSpans(start)
		if fold.fragment != "" {
			header.fold, header.folded, header.inline = fold, folded, true
			header.toggle = text.Collapse
			if folded {
				header.toggle = text.ExpandConfiguration(count)
			}
		}
	} else {
		header.text = consoleRawHeader(r, loc)
		stamp, repository := consoleHeaderParts(r.Started, r.Root, loc)
		header.spans = v.prefixSpans(stamp, repository, len(header.text))
	}
	if r.State == core.GitConsoleRunning {
		header.badge = text.Running
	}
	if consoleFailed(r, p, exact) {
		header.tone = consoleToneError
	}
	headerRow := v.add(old, header)

	if r.Truncated {
		v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartTruncated}, record: index, text: text.Truncated, tone: consoleToneSubtle})
	}
	lo, next := len(v.rows), 0
	if use {
		for _, fragment := range p.entry.Output {
			start, end := max(fragment.Start, next), min(fragment.End, len(r.Lines))
			if start >= end {
				continue
			}
			v.addLines(old, index, r, next, start)
			next = end
			if fragment.Kind != consoleFragmentProgress || end-start <= 1 {
				v.addLines(old, index, r, start, end)
				continue
			}
			fold := consoleFold{record: r.ID, fragment: fragment.ID}
			last := consoleRow{id: consoleRowID{record: r.ID, part: consolePartLine, index: end - 1}, record: index, text: consoleExpandTabs(r.Lines[end-1].Text), fold: fold, first: end - 1, last: end - 1}
			if v.open[fold] {
				v.addLines(old, index, r, start, end-1)
				last.toggle = text.Collapse
			} else {
				count := fragment.Count
				if count <= 0 {
					count = end - start
				}
				last.toggle, last.folded, last.first = text.ExpandLines(count), true, start
			}
			v.add(old, last)
		}
	}
	v.addLines(old, index, r, next, len(r.Lines))
	hi := len(v.rows)

	progressRow := -1
	if r.State == core.GitConsoleRunning && r.Progress != "" {
		progressRow = v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartProgress}, record: index, text: r.Progress, tone: consoleToneSubtle})
	}
	if exact {
		if notice := consoleNoticeText(text, p.entry.Notice); notice != "" {
			v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartNotice}, record: index, text: notice, tone: consoleToneSubtle})
		}
	}
	if r.State == core.GitConsoleUnconfirmed {
		v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartUnconfirmed}, record: index, text: text.Unconfirmed, tone: consoleToneError})
	}
	if consoleUnexpectedExit(r) {
		v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartExit}, record: index, text: text.ExitCode(r.ExitCode), tone: consoleToneError})
	}
	errorRow := -1
	if r.Error != "" {
		for j, line := range strings.Split(strings.TrimRight(r.Error, "\n"), "\n") {
			at := v.add(old, consoleRow{id: consoleRowID{record: r.ID, part: consolePartError, index: j}, record: index, text: line, tone: consoleToneError})
			if j == 0 {
				errorRow = at
			}
		}
	}

	if !use || !searching || p.search != v.searchFor {
		return
	}
	var previous consoleHitKey
	nth, havePrevious := 0, false
	for _, hit := range p.hits {
		key := consoleHitKey{record: r.ID, fragment: hit.FragmentID, line: -1}
		if hit.LineIndex != nil {
			key.line = *hit.LineIndex
		}
		row, fold := -1, consoleFold{}
		switch {
		case hit.LineIndex != nil:
			row = v.lineRow(lo, hi, *hit.LineIndex)
			if row >= 0 && v.rows[row].folded && v.rows[row].last != *hit.LineIndex {
				fold = v.rows[row].fold
			}
		case hit.FragmentID == consoleHitRepository:
			row = headerRow
		case hit.FragmentID == consoleHitError:
			row = errorRow
			if row < 0 {
				row = headerRow
			}
		case hit.FragmentID == consoleHitProgress:
			row = progressRow
		default:
			row, fold = v.fragmentRow(p, hit.FragmentID, headerRow, lo, hi)
		}
		if row < 0 {
			continue
		}
		if havePrevious && key == previous {
			nth++
		} else {
			previous, nth, havePrevious = key, 0, true
		}
		key.nth = nth
		v.rows[row].matched = true
		v.hits = append(v.hits, consoleHit{key: key, row: row, fold: fold})
	}
}

// lineRow is the row among the line rows [lo, hi) of a record that stands for its output
// line, or -1.
func (v *consoleView) lineRow(lo, hi, line int) int {
	at := lo + sort.Search(hi-lo, func(i int) bool { return v.rows[lo+i].last >= line })
	if at < hi && v.rows[at].first <= line {
		return at
	}
	return -1
}

// fragmentRow is the row a hit on the command or output fragment id of p is drawn on, and the
// closed fold the hit is inside, if any: a command fragment is on the header, whose
// configuration fold hides it while closed, and an output fragment on the row of its first
// line. It is -1 for a fragment the presentation does not have.
func (v *consoleView) fragmentRow(p *consolePresented, id string, headerRow, lo, hi int) (int, consoleFold) {
	for _, fragment := range p.entry.Command {
		if fragment.ID != id {
			continue
		}
		if fragment.Kind == consoleFragmentConfiguration && v.rows[headerRow].folded {
			return headerRow, v.rows[headerRow].fold
		}
		return headerRow, consoleFold{}
	}
	for _, fragment := range p.entry.Output {
		if fragment.ID == id {
			return v.lineRow(lo, hi, fragment.Start), consoleFold{}
		}
	}
	return -1, consoleFold{}
}

// step makes the hit delta places from the current one current, wrapping around the ends,
// opens the fold it is inside and scrolls the list to its row. Without a current hit, a step
// forward goes to the first and a step back to the last.
func (v *consoleView) step(delta int, text *i18n.ConsoleMessages, loc *time.Location) {
	n := len(v.hits)
	if n == 0 {
		return
	}
	i := v.hitIndex
	switch {
	case i < 0 && delta > 0:
		i = 0
	case i < 0:
		i = n - 1
	default:
		i = ((i+delta)%n + n) % n
	}
	hit := v.hits[i]
	v.current, v.hasCurrent = hit.key, true
	v.hitIndex, v.hitRow = i, hit.row
	if hit.fold.fragment != "" && !v.open[hit.fold] {
		if v.open == nil {
			v.open = map[consoleFold]bool{}
		}
		v.open[hit.fold] = true
		v.flatten(text, loc)
	}
	if v.hitRow >= 0 {
		v.list.ScrollTo(v.hitRow, ui.ListCenter)
		v.detach = true
	}
}

// stepConsoleMatch moves to the next search hit, or with a negative delta the one before.
func (a *App) stepConsoleMatch(delta int) {
	action := "git.console.nextMatch"
	if delta < 0 {
		action = "git.console.previousMatch"
	}
	a.performed(action, surfaceButton)
	a.consoleView.step(delta, &a.text.Console, time.Local)
}

// toggleConsoleFold opens fold, or closes it when opening is not set.
func (a *App) toggleConsoleFold(fold consoleFold, opening bool) {
	v := &a.consoleView
	if opening {
		a.performed("git.console.expand", surfaceButton)
		if v.open == nil {
			v.open = map[consoleFold]bool{}
		}
		v.open[fold] = true
	} else {
		a.performed("git.console.collapse", surfaceButton)
		delete(v.open, fold)
	}
	v.dirty = true
}

// closeConsoleSearch empties the search, which the next paint takes in.
func (a *App) closeConsoleSearch() {
	a.performed("git.console.closeSearch", surfaceButton)
	a.consoleView.search.SetText("")
}

// toggleConsoleWrap switches between breaking long lines and ending them in an ellipsis.
func (a *App) toggleConsoleWrap() {
	a.performed("git.console.wrap", surfaceButton)
	a.consoleView.wrap = !a.consoleView.wrap
}

// consoleScrollToEnd scrolls the list to its end, where it follows new rows again.
func (a *App) consoleScrollToEnd() {
	a.performed("git.console.scrollToEnd", surfaceButton)
	a.consoleView.list.ScrollToEnd()
	a.consoleView.detach = false
}

// showGitConsole shows the Console tab of the Git tool window, scrolled to its end, when the
// user starts a Git write outside that tool window: in the Commit tool window, a Diff tab or
// the title bar's branch popup. The commands the write runs and what they write are then in
// view. A write started on a page of the Git tool window, the Log or the Worktrees, leaves
// that page in view, since the user works in it and the Console is one tab away. from is
// the catalog item of the tool window the write was started in, empty for the title bar:
// when that window shares the Git tool window's zone and is open there, the Git tool window
// does not take its place, and only its tab changes.
func (a *App) showGitConsole(from string) {
	a.layout.gitTab = gitTabConsole
	a.consoleView.list.ScrollToEnd()
	a.consoleView.detach = false
	git := catalogIndex[itemGit]
	if a.chrome.isOpen(git) {
		return
	}
	if source, known := catalogIndex[from]; known {
		if s, ok := a.chrome.zoneOf(git).slot(); ok && a.chrome.open[s] == source {
			return
		}
	}
	a.reduceChrome(core.SetChromeOpen(itemGit, true))
}

// stopConsole asks Core to cancel the commands that are running.
func (a *App) stopConsole() {
	a.performed("git.console.stop", surfaceButton)
	a.gitConsole.Stop()
}

// clearConsole removes every record from the journal; the change callback repaints.
func (a *App) clearConsole() {
	a.performed("git.console.clear", surfaceButton)
	a.gitConsole.Clear()
}

// copyConsoleAll puts the whole console on the clipboard as plain text.
func (a *App) copyConsoleAll() {
	a.performed("git.console.copyAll", surfaceButton)
	a.copyConsoleText(consoleCopyAll(a.consoleView.snapshot.Records, &a.text.Console, time.Local))
}

// copyConsoleRecord puts value, which a record's context menu action named action made, on
// the clipboard.
func (a *App) copyConsoleRecord(action, value string) {
	a.performed("git.console."+action, surfaceMenu)
	a.copyConsoleText(value)
}

// copyConsoleText puts value on the clipboard and says so when the system refuses it. The
// clipboard takes no NUL, which Git output can hold, so each is replaced by its visible
// symbol.
func (a *App) copyConsoleText(value string) {
	if err := app.SetClipboardText(strings.ReplaceAll(value, "\x00", "\u2400")); err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
	}
}

// consoleQuote writes an argument the way a POSIX shell reads it back: as it is when it holds
// nothing the shell treats specially, else in single quotes, with each quote inside closing
// the quoted text, written escaped and opening it again.
func consoleQuote(argument string) string {
	if argument == "" {
		return "''"
	}
	if !strings.ContainsAny(argument, " \t\n\r'\"\\$`!*?[]{}()<>|&;#~") {
		return argument
	}
	return "'" + strings.ReplaceAll(argument, "'", `'\''`) + "'"
}

// consoleCommand is the command of r as a shell would run it: git, a -c for each temporary
// setting, then the arguments, each quoted where it needs to be.
func consoleCommand(r *core.GitConsoleRecord) string {
	var b strings.Builder
	b.WriteString("git")
	for _, setting := range r.TemporaryConfig {
		b.WriteString(" -c ")
		b.WriteString(consoleQuote(setting[0] + "=" + setting[1]))
	}
	for _, argument := range r.Arguments {
		b.WriteByte(' ')
		b.WriteString(consoleQuote(argument))
	}
	return b.String()
}

// consoleOutput is the retained output of r, one line after another.
func consoleOutput(r *core.GitConsoleRecord) string {
	var b strings.Builder
	for i, line := range r.Lines {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(line.Text)
	}
	return b.String()
}

// consoleHeaderPrefix is the start of a header: when the command started, in loc to the
// millisecond, and the name of the repository it ran in, as consoleHeaderParts gives them,
// joined by a space.
func consoleHeaderPrefix(started time.Time, root string, loc *time.Location) string {
	stamp, repository := consoleHeaderParts(started, root, loc)
	return stamp + " " + repository
}

// consoleHeaderParts is the two parts of the start of a header, drawn in colors of their
// own: the stamp, when the command started in loc to the millisecond with a colon after it,
// and the name of the repository it ran in, in brackets.
func consoleHeaderParts(started time.Time, root string, loc *time.Location) (stamp, repository string) {
	base := ""
	if root != "" {
		base = filepath.Base(root)
	}
	return started.In(loc).Format("15:04:05.000") + ":", "[" + base + "]"
}

// consoleRawHeader is the header of r drawn without Core's presentation, and the header the
// copy of the whole console has: the prefix and the whole command. A failed request that ran
// no command has none.
func consoleRawHeader(r *core.GitConsoleRecord, loc *time.Location) string {
	header := consoleHeaderPrefix(r.Started, r.Root, loc)
	if len(r.Arguments) > 0 || len(r.TemporaryConfig) > 0 {
		header += " " + consoleCommand(r)
	}
	return header
}

// consoleCopyAll is the whole console as plain text: for each record its header, every
// retained line, the exit code of an unexpected exit and the error.
func consoleCopyAll(records []core.GitConsoleRecord, text *i18n.ConsoleMessages, loc *time.Location) string {
	var b strings.Builder
	first := true
	line := func(value string) {
		if !first {
			b.WriteByte('\n')
		}
		first = false
		b.WriteString(value)
	}
	for i := range records {
		r := &records[i]
		line(consoleRawHeader(r, loc))
		for _, output := range r.Lines {
			line(output.Text)
		}
		if consoleUnexpectedExit(r) {
			line(text.ExitCode(r.ExitCode))
		}
		if r.Error != "" {
			for _, message := range strings.Split(strings.TrimRight(r.Error, "\n"), "\n") {
				line(message)
			}
		}
	}
	return b.String()
}

// consoleUnexpectedExit says r exited with a code the workflow did not accept.
func consoleUnexpectedExit(r *core.GitConsoleRecord) bool {
	return r.Exited && r.ExitCode != 0 && !r.ExpectedExit
}

// consoleFailed says r is drawn as a failure: as Core says when its presentation is for the
// record as it is, else from the record itself.
func consoleFailed(r *core.GitConsoleRecord, p *consolePresented, exact bool) bool {
	if exact {
		return p.entry.Failed
	}
	return r.Error != "" || r.State == core.GitConsoleUnconfirmed || consoleUnexpectedExit(r)
}

// consoleNoticeText is the words of a notice Core gives in place of output, empty for none or
// one this client does not know.
func consoleNoticeText(text *i18n.ConsoleMessages, notice string) string {
	switch notice {
	case core.GitConsoleNoticeWaiting:
		return text.Waiting
	case core.GitConsoleNoticeNoOutput:
		return text.NoOutput
	case core.GitConsoleNoticeUnchanged:
		return text.Unchanged
	}
	return ""
}
