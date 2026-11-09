// Package editorview is the code editor's view of one document: it paints the text with its
// syntax colors, the line numbers, the caret and the selection, and edits the text with the
// keyboard, the pointer and the platform's text input.
//
// The text is a rope, which is persistent: an edit makes a new rope and leaves the old one
// whole, so undo keeps the ropes an edit replaced instead of a record of the change. Positions
// are byte offsets into the text.
package editorview

import (
	"bytes"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

const (
	// fontSize is the size of the editor's fixed-pitch font, the terminal's.
	fontSize = float32(13)
	// lineSpacing is how much taller a line is than the font's cell.
	lineSpacing = float32(1.4)
	// tabSize is how many columns a tab character advances to the next stop.
	tabSize = 4
	// undoLimit bounds how many steps undo keeps.
	undoLimit = 1000
	// blinkPeriod is how long the caret stays on, and then off, while it blinks.
	blinkPeriod = 530 * time.Millisecond
)

// Config is what a view needs from its window.
type Config struct {
	// HitID is the view's hit, which takes the keyboard focus.
	HitID gfx.ID
	// Label names the view for assistive technology: the file's name.
	Label string
	// Content is the document as it was read, made by Prepare on a worker: building its rope
	// and measuring its lines take time in proportion to the file, which the window thread
	// must not spend.
	Content Content
	// Syntax colors the text; nil shows it in one color.
	Syntax *syntax.Syntax
	// Notify wakes the window when the background highlighter has colored lines anew.
	Notify func()
	// Save asks the window to write the text out, for the save chord.
	Save func()
	// OnEdit reports every replacement made to the view, for a language
	// server's versioned document synchronization. It runs on the view's thread
	// and must not block.
	OnEdit func(Edit)
	// MinimapID is the minimap's hit and MinimapToggleID the button beside it that hides and
	// shows it; VerticalBarID and HorizontalBarID are the tracks of the scrollbars. The window
	// owns what the toggle does: it asks canvas.Clicked of MinimapToggleID and calls
	// SetMinimap. A zero ID leaves the part out of the hits, and the bar or the minimap does
	// not take the pointer.
	MinimapID, MinimapToggleID     gfx.ID
	VerticalBarID, HorizontalBarID gfx.ID
}

// Edit is one replaced range of the document. Start and End are zero-based LSP
// lines and UTF-16 columns in the text before the replacement; Text is the
// replacement text.
type Edit struct {
	StartLine   int
	StartColumn int
	EndLine     int
	EndColumn   int
	Text        string
}

// Messages are the words the view gives assistive technology for its parts.
type Messages struct {
	// Minimap names the minimap, and HideMinimap and ShowMinimap the button that hides it and
	// shows it again.
	Minimap, HideMinimap, ShowMinimap string
	// VerticalScrollbar and HorizontalScrollbar name the scrollbars.
	VerticalScrollbar, HorizontalScrollbar string
}

// Look is the view's colors for the frame being painted.
type Look struct {
	Dark bool
	// Background is the editor's ground, Foreground its plain text and Subtle the line
	// numbers.
	Background, Foreground, Subtle gfx.Color
	// CurrentLine is the band behind the caret's line, Selection the selected text's ground
	// and Caret the caret.
	CurrentLine, Selection, Caret gfx.Color
	// Scrollbar is the thumb of the scrollbars.
	Scrollbar gfx.Color
	// Button is the ground of the button that hides and shows the minimap, ButtonHover its
	// ground under the pointer and ButtonBorder its edge.
	Button, ButtonHover, ButtonBorder gfx.Color
}

// snapshot is the text and the selection before or after an edit, as undo restores them.
type snapshot struct {
	text            rope.Rope
	anchor, caret   int
	scrollX, scroll float32
	// widest is the view's widest at the time, no less than the widest line of text, so undo
	// restores the scroll range without measuring the document again.
	widest int
}

// editKind says how an edit merges with the one before it into one undo step.
type editKind uint8

const (
	editOther editKind = iota
	editTyping
	editDeleting
)

// View is the editor of one document.
type View struct {
	cfg Config

	text rope.Rope
	// saved is the text as it was last read or written, and dirty says the text differs
	// from it.
	saved rope.Rope
	dirty bool
	// revision counts the changes to the text since the file was read, undo and redo
	// included.
	revision int
	// anchor and caret are the ends of the selection; they are equal when nothing is
	// selected. goal is the column, in cells, that up and down keep to; -1 is the caret's.
	anchor, caret                                      int
	goal                                               int
	caretUTF16Text                                     rope.Rope
	caretUTF16Offset, caretUTF16Line, caretUTF16Column int
	caretUTF16Valid                                    bool
	undo, redo                                         []snapshot
	// lastKind and lastEnd say what the last edit was and where it left the caret, so that
	// typing on goes into the same undo step.
	lastKind editKind
	lastEnd  int
	// indentUnit is what Tab inserts: a tab in a file indented with tabs, spaces otherwise.
	indentUnit string
	// widest is the most cells any line takes, for the horizontal scroll range. It only grows
	// while the view is open.
	widest int
	// markers are the diagnostics to underline, grouped by line. They are the view's only
	// knowledge of a language server: the text and the caret never depend on them.
	markers map[int][]Marker

	hl    *syntax.Highlighter
	theme *syntax.Theme
	// themeDark and themeFG are what theme was built for.
	themeDark bool
	themeFG   gfx.Color

	// wrap says soft wrapping is on, and wrapCols is the columns the last paint wrapped the text
	// at, 0 when it did not. wraps keeps every line's rows at wrapCols and rowStart where each
	// line's first row is, one more than the lines; rowsDirty says rowStart is behind wraps.
	// rowCache keeps the rows of the lines painted lately. See wrap.go.
	wrap      bool
	wrapCols  int
	wraps     []lineWrap
	rowStart  []int32
	rowsDirty bool
	rowCache  map[int][]wrapRow
	rowBuf    []wrapRow

	// minimap says the window wants the minimap shown; a view too narrow for it leaves it out.
	// See minimap.go.
	minimap bool
	mm      minimapState
	// hlGen counts the highlighter's reports of lines colored anew, from its goroutine, so
	// the minimap knows its colors are stale.
	hlGen atomic.Uint64
	words Messages

	// scroll and scrollX are how far the text is scrolled, in pixels.
	scroll, scrollX float32
	// reveal asks the next paint to scroll the caret into view.
	reveal bool
	// The geometry of the last paint, which the pointer and the text input use. textRight is
	// where the text ends: at the minimap while it shows, else at the view's right edge.
	area                gfx.Rect
	textLeft, textRight float32
	cellW, cellH        float32
	lineH               float32
	painted, focused    bool

	dragging bool
	// dragUnit is what a drag selects by: 1 characters, 2 words, 3 lines; dragFrom and
	// dragTo are the unit the drag started on.
	dragUnit         int
	dragFrom, dragTo int
	// grip is the scrollbar thumb or the minimap slider a press holds, and the last paint's
	// scrollbars; edgeHot says the pointer is near the right edge, which shows the button
	// that brings the minimap back. See scrollbar.go.
	grip    grip
	bars    barLayout
	edgeHot bool

	preedit app.TextState
	input   app.TextInput
	// blinkFrom is when the caret last moved; it is solid for a period after.
	blinkFrom time.Duration
	clock     time.Duration

	tokens  []syntax.Token
	runs    []gfx.TextRun
	display []byte
	// numbers is the line numbers a paint puts in the gutter once the text is drawn.
	numbers []gutterNumber
}

// New makes the view of a document.
func New(cfg Config) *View {
	content := cfg.Content
	// The view keeps cfg for its hits and callbacks. It must not keep the text it opened with
	// alive once edits have replaced it.
	cfg.Content = Content{}
	text := content.text
	v := &View{cfg: cfg, text: text, saved: text, goal: -1, indentUnit: content.indent, widest: content.widest}
	if v.indentUnit == "" {
		// A zero Content is an empty document, which Prepare was not asked to measure.
		v.indentUnit = indentUnit(text)
	}
	notify := cfg.Notify
	v.hl = syntax.NewHighlighter(cfg.Syntax, text, syntax.HighlighterOptions{
		OnChange: func(first, last int) {
			v.hlGen.Add(1)
			if notify != nil {
				notify()
			}
		},
	})
	return v
}

// Owns reports whether id is one of the view's hits: the text, the minimap, its button or a
// scrollbar.
func (v *View) Owns(id gfx.ID) bool {
	if id.IsZero() {
		return false
	}
	c := &v.cfg
	return id == c.HitID || id == c.MinimapID || id == c.MinimapToggleID || id == c.VerticalBarID || id == c.HorizontalBarID
}

// SetMessages hands the view the words for its parts, each frame, so a change of language
// reaches it at once.
func (v *View) SetMessages(words Messages) { v.words = words }

// MarkerSeverity chooses the colour a marker is drawn in.
type MarkerSeverity uint8

const (
	// MarkerError is a problem that stops the code from working.
	MarkerError MarkerSeverity = iota + 1
	// MarkerWarning is a problem worth reading.
	MarkerWarning
	// MarkerInfo is a note the server chose to publish.
	MarkerInfo
)

// Marker is one diagnostic the view underlines.
//
// Line, Start and End are zero-based, and End counts UTF-16 code units within the
// line, which is the unit the language protocol reports.
type Marker struct {
	Line     int
	Start    int
	End      int
	Severity MarkerSeverity
}

// SetMarkers replaces the diagnostics the view underlines.
//
// A marker that covers no cell is dropped: an underline of zero width is invisible
// and would only cost paint time. Markers never affect the text, the caret or the
// selection, so a server cannot change what the document says.
func (v *View) SetMarkers(markers []Marker) {
	if len(markers) == 0 {
		v.markers = nil
		return
	}
	grouped := make(map[int][]Marker, len(markers))
	for _, marker := range markers {
		if marker.Line < 0 || marker.Start < 0 || marker.End <= marker.Start {
			continue
		}
		grouped[marker.Line] = append(grouped[marker.Line], marker)
	}
	if len(grouped) == 0 {
		v.markers = nil
		return
	}
	v.markers = grouped
}

// Close stops the view's background highlighter.
func (v *View) Close() { v.hl.Close() }

// IsComposing reports input method text that has not been committed to the document.
func (v *View) IsComposing() bool { return v.preedit.Composing }

// Dirty reports whether the text differs from the text last read or written.
func (v *View) Dirty() bool { return v.dirty }

// compare works out whether the text differs from the saved text, after it changed.
func (v *View) compare() {
	v.dirty = !v.text.Equal(v.saved)
}

// Revision counts the changes made to the text since the file was read, undo and redo
// included, so a failed save can be told apart from a later one.
func (v *View) Revision() int { return v.revision }

// Text is the document's current content, and the rope it was taken from for MarkSaved.
func (v *View) Text() ([]byte, rope.Rope) { return v.text.Bytes(), v.text }

// Content is a document read and laid out away from the window thread: its rope, the indent it
// uses and its widest line. A view opens with it or reloads it. It never changes, so a read that
// has become stale may simply be dropped.
type Content struct {
	text   rope.Rope
	indent string
	widest int
}

// Prepare makes the content of data, the bytes of a file as they were read. It takes time in
// proportion to data, so it runs on a worker, not on the window thread.
func Prepare(data []byte) Content {
	text := rope.New(data)
	return Content{text: text, indent: indentUnit(text), widest: widestLine(text, 0, text.LineCount()-1)}
}

// SavedSnapshot returns an immutable baseline for background comparison.
func (v *View) SavedSnapshot() rope.Rope { return v.saved }

// HasSavedSnapshot reports whether a background read still uses the current baseline.
func (v *View) HasSavedSnapshot(snapshot rope.Rope) bool { return v.saved.Same(snapshot) }

// Reload installs an externally changed file only while no local edit or input-method
// composition needs protection. Undo retains the previous contents as a recovery path.
func (v *View) Reload(content Content) bool {
	if v.dirty || v.preedit.Composing {
		return false
	}
	return v.replaceFromDisk(content)
}

// ResolveWithDisk applies an explicit conflict decision while preserving undo history.
func (v *View) ResolveWithDisk(content Content) bool {
	if v.preedit.Composing {
		return false
	}
	return v.replaceFromDisk(content)
}

// Snapshot returns the immutable disk contents that were prepared on a worker.
func (c Content) Snapshot() rope.Rope { return c.text }

func (v *View) replaceFromDisk(content Content) bool {
	edit := v.wholeDocumentEdit(content.text)
	v.undo = append(v.undo, v.snapshot())
	if len(v.undo) > undoLimit {
		v.undo = v.undo[len(v.undo)-undoLimit:]
	}
	v.redo = v.redo[:0]
	v.text = content.text
	v.saved = v.text
	v.revision++
	v.hl.SetText(v.text)
	v.forgetRows()
	boundary := func(at int) int {
		at = min(max(at, 0), v.text.Len())
		for at > 0 && at < v.text.Len() && !utf8.RuneStart(v.text.ByteAt(at)) {
			at--
		}
		if at > 0 && at < v.text.Len() && v.text.ByteAt(at) == '\n' && v.text.ByteAt(at-1) == '\r' {
			at--
		}
		return at
	}
	v.anchor, v.caret = boundary(v.anchor), boundary(v.caret)
	v.indentUnit = content.indent
	v.widest = content.widest
	v.lastKind, v.goal = editOther, -1
	v.dirty = false
	v.blinkFrom = v.clock
	v.reportEdit(edit)
	return true
}

// SavedBytes returns the last persisted content for a guarded save.
func (v *View) SavedBytes() []byte { return v.saved.Bytes() }

// MarkSaved records that text was written out, so the view is clean while it shows it.
func (v *View) MarkSaved(text rope.Rope) {
	v.saved = text
	v.compare()
}

// SetLabel changes the name the view gives assistive technology.
func (v *View) SetLabel(label string) { v.cfg.Label = label }

// Selection is the selection's start and end, in order.
func (v *View) Selection() (int, int) { return min(v.anchor, v.caret), max(v.anchor, v.caret) }

// GoToLine selects the start of a one-based line and reveals it on the next paint.
// Active input-method composition retains its selection until it is committed.
func (v *View) GoToLine(line int) bool {
	if v.preedit.Composing {
		return false
	}
	line = min(max(line, 1), v.text.LineCount())
	v.anchor = v.text.LineStart(line - 1)
	v.caret = v.anchor
	v.goal, v.lastKind, v.reveal = -1, editOther, true
	return true
}

// GoToNavigation applies Core's zero-based UTF-16 position to the live text.
// A position inside a surrogate pair snaps to the preceding rune boundary.
func (v *View) GoToNavigation(line, column int, wholeLine bool) bool {
	if v.preedit.Composing {
		return false
	}
	line = min(max(line, 0), v.text.LineCount()-1)
	start, end := v.text.LineStart(line), v.text.LineEnd(line)
	v.anchor, v.caret = start, start
	if wholeLine {
		v.caret = end
	} else {
		remaining := max(column, 0)
		v.text.Chunks(start, end, func(chunk []byte) bool {
			for len(chunk) > 0 && remaining > 0 {
				r, size := utf8.DecodeRune(chunk)
				units := 1
				if r > 0xffff {
					units = 2
				}
				if units > remaining {
					return false
				}
				remaining -= units
				v.caret += size
				chunk = chunk[size:]
			}
			return remaining > 0
		})
		v.anchor = v.caret
	}
	v.goal, v.lastKind, v.reveal = -1, editOther, true
	return true
}

// CaretUTF16 is the caret's zero-based line and column in UTF-16 code units.
func (v *View) CaretUTF16() (int, int) {
	if v.caretUTF16Valid && v.caretUTF16Offset == v.caret && v.caretUTF16Text.Same(v.text) {
		return v.caretUTF16Line, v.caretUTF16Column
	}
	line := v.text.LineOf(v.caret)
	column := v.utf16Units(v.text.LineStart(line), v.caret)
	v.caretUTF16Text, v.caretUTF16Offset = v.text, v.caret
	v.caretUTF16Line, v.caretUTF16Column, v.caretUTF16Valid = line, column, true
	return line, column
}

func utf16Length(data []byte) int {
	units := 0
	for len(data) > 0 {
		r, size := utf8.DecodeRune(data)
		units++
		if r > 0xffff {
			units++
		}
		data = data[size:]
	}
	return units
}

func (v *View) utf16Units(start, end int) int {
	units := 0
	v.text.Chunks(start, end, func(chunk []byte) bool { units += utf16Length(chunk); return true })
	return units
}

// Caret is the caret's line and column, both from zero; the column counts bytes.
func (v *View) Caret() (int, int) {
	line := v.text.LineOf(v.caret)
	return line, v.caret - v.text.LineStart(line)
}

// indentUnit is a tab for a text whose first indented lines use tabs, and four spaces for any
// other.
func indentUnit(text rope.Rope) string {
	tabs, spaces := 0, 0
	for line := 0; line < min(text.LineCount(), 200); line++ {
		start := text.LineStart(line)
		if start >= text.Len() {
			break
		}
		switch text.ByteAt(start) {
		case '\t':
			tabs++
		case ' ':
			spaces++
		}
	}
	if tabs > spaces {
		return "\t"
	}
	return "    "
}

// lineEnd is where the content of line ends: before its line feed, and before a carriage
// return that comes with it.
func (v *View) lineEnd(line int) int {
	end := v.text.LineEnd(line)
	if end > v.text.LineStart(line) && v.text.ByteAt(end-1) == '\r' {
		end--
	}
	return end
}

// cellsOf is how many cells the bytes of line take up to byte column col.
func cellsOf(line string, col int) int {
	cells := 0
	for i, r := range line {
		if i >= col {
			break
		}
		cells += runeCells(r, cells)
	}
	return cells
}

// columnAt is the byte column of line whose cell holds cells, rounding to the nearer edge of
// the character under it.
func columnAt(line string, cells float32) int {
	return columnIn(line, 0, len(line), 0, cells)
}

// columnIn is columnAt for the part of line from byte from to byte to, where from is startCells
// columns into the line; cells counts from the line's start too. It is to when cells lies past
// the part.
func columnIn(line string, from, to, startCells int, cells float32) int {
	at := startCells
	for i, r := range line[from:to] {
		i += from
		if r == '\r' && i == len(line)-1 {
			return i
		}
		w := runeCells(r, at)
		if cells < float32(at)+float32(w)/2 {
			return i
		}
		at += w
	}
	return to
}

// runeCells is how many cells r takes when it starts at column at.
func runeCells(r rune, at int) int {
	switch {
	case r == '\t':
		return tabSize - at%tabSize
	case r == '\r':
		return 0
	case r < 0x80:
		return 1
	}
	return max(term.Width(r), 1)
}

// widestLine is the most cells a line of text from first to last takes. It reads the lines
// once, a leaf at a time and without copying them, and counts the cells of a line only when it
// could be wider than the widest so far: a character takes at most a cell per byte, and a tab
// at most tabSize.
func widestLine(text rope.Rope, first, last int) int {
	last = min(last, text.LineCount()-1)
	if first > last {
		return 0
	}
	widest := 0
	start := text.LineStart(first)
	offset, lineStart, length, tabs := start, start, 0, 0
	// ended measures the line that ends at offset, when it may be the widest.
	ended := func() {
		if length+(tabSize-1)*tabs > widest {
			widest = max(widest, rangeCells(text, lineStart, offset))
		}
	}
	text.Chunks(start, text.LineEnd(last), func(chunk []byte) bool {
		for {
			i := bytes.IndexByte(chunk, '\n')
			part := chunk
			if i >= 0 {
				part = chunk[:i]
			}
			length += len(part)
			tabs += bytes.Count(part, tabBytes)
			offset += len(part)
			if i < 0 {
				return true
			}
			ended()
			offset++
			lineStart, length, tabs = offset, 0, 0
			chunk = chunk[i+1:]
		}
	})
	ended()
	return widest
}

// tabBytes is a tab, as the separator bytes.Count counts.
var tabBytes = []byte{'\t'}

// rangeCells is the cells the bytes of text from start to end take, the first at column 0, as
// cellsOf counts them. It reads the text a leaf at a time without copying it: a leaf never
// ends inside a character of valid UTF-8.
func rangeCells(text rope.Rope, start, end int) int {
	cells := 0
	text.Chunks(start, end, func(chunk []byte) bool {
		for i := 0; i < len(chunk); {
			if c := chunk[i]; c < utf8.RuneSelf {
				cells += runeCells(rune(c), cells)
				i++
				continue
			}
			r, size := utf8.DecodeRune(chunk[i:])
			cells += runeCells(r, cells)
			i += size
		}
		return true
	})
	return cells
}

// edit replaces the bytes from start to end with text, leaves the caret after it and keeps
// what was there for undo. Typing and deleting on from where the last such edit stopped go
// into its undo step.
func (v *View) edit(start, end int, text []byte, kind editKind) {
	if start == end && len(text) == 0 {
		return
	}
	// Typing merges when it goes on where the last typing ended; deleting merges when it goes
	// on backwards (Backspace) or forwards (Delete) from where the last deletion left the caret.
	merge := kind != editOther && kind == v.lastKind && len(v.undo) > 0
	switch kind {
	case editTyping:
		merge = merge && start == v.lastEnd &&
			!bytes.ContainsRune(text, '\n') && !(len(text) > 0 && text[0] == ' ' && start > 0 && v.text.ByteAt(start-1) != ' ')
	case editDeleting:
		merge = merge && (end == v.lastEnd || start == v.lastEnd)
	}
	if !merge {
		v.undo = append(v.undo, v.snapshot())
		if len(v.undo) > undoLimit {
			v.undo = v.undo[len(v.undo)-undoLimit:]
		}
	}
	v.redo = v.redo[:0]
	startLine, startColumn := v.positionAt(start)
	endLine, endColumn := v.positionAt(end)
	firstLine, oldLast, oldCount := v.text.LineOf(start), v.text.LineOf(end), v.text.LineCount()
	// Keep the status column incremental for ordinary typing and deletion, even
	// on a very long line. Other edits invalidate the cached rope naturally.
	cacheEdit := v.caretUTF16Valid && v.caretUTF16Text.Same(v.text) && v.caretUTF16Line == firstLine && firstLine == oldLast &&
		start <= v.caretUTF16Offset && v.caretUTF16Offset <= end && !bytes.ContainsRune(text, '\n')
	column := 0
	if cacheEdit {
		column = v.caretUTF16Column - v.utf16Units(start, v.caretUTF16Offset) + utf16Length(text)
	}
	v.text = v.text.Replace(start, end, text)
	v.revision++
	v.hl.Edit(v.text, start, end, start+len(text))
	v.spliceRows(firstLine, oldLast, v.text.LineOf(start+len(text)), oldCount)
	v.anchor, v.caret = start+len(text), start+len(text)
	if cacheEdit {
		v.caretUTF16Text, v.caretUTF16Offset = v.text, v.caret
		v.caretUTF16Line, v.caretUTF16Column = firstLine, column
	}
	v.lastKind, v.lastEnd = kind, v.caret
	if kind == editDeleting {
		v.lastEnd = start
	}
	v.widest = max(v.widest, widestLine(v.text, firstLine, v.text.LineOf(v.caret)))
	v.compare()
	v.moved()
	v.reportEdit(Edit{StartLine: startLine, StartColumn: startColumn, EndLine: endLine, EndColumn: endColumn, Text: string(text)})
}

// positionAt is the zero-based LSP line and UTF-16 column of a byte offset in
// the current text.
func (v *View) positionAt(offset int) (line, column int) {
	line = v.text.LineOf(offset)
	return line, v.utf16Units(v.text.LineStart(line), offset)
}

// wholeDocumentEdit is the replacement Edit for making replacement the view's
// whole text.
func (v *View) wholeDocumentEdit(replacement rope.Rope) Edit {
	last := v.text.LineCount() - 1
	return Edit{
		EndLine:   last,
		EndColumn: v.utf16Units(v.text.LineStart(last), v.text.LineEnd(last)),
		Text:      string(replacement.Bytes()),
	}
}

func (v *View) reportEdit(edit Edit) {
	if v.cfg.OnEdit != nil {
		v.cfg.OnEdit(edit)
	}
}

// snapshot is the text and selection as they are now.
func (v *View) snapshot() snapshot {
	return snapshot{text: v.text, anchor: v.anchor, caret: v.caret, scroll: v.scroll, scrollX: v.scrollX, widest: v.widest}
}

// restore makes s the view's text and selection.
func (v *View) restore(s snapshot) {
	edit := v.wholeDocumentEdit(s.text)
	v.text = s.text
	v.revision++
	v.hl.SetText(s.text)
	v.forgetRows()
	v.anchor, v.caret = s.anchor, s.caret
	v.lastKind = editOther
	v.widest = max(v.widest, s.widest)
	v.compare()
	v.moved()
	v.reportEdit(edit)
}

// Undo takes back the last edit; Redo does it again.
func (v *View) Undo() bool {
	if len(v.undo) == 0 {
		return false
	}
	last := v.undo[len(v.undo)-1]
	v.undo = v.undo[:len(v.undo)-1]
	v.redo = append(v.redo, v.snapshot())
	v.restore(last)
	return true
}

func (v *View) Redo() bool {
	if len(v.redo) == 0 {
		return false
	}
	next := v.redo[len(v.redo)-1]
	v.redo = v.redo[:len(v.redo)-1]
	v.undo = append(v.undo, v.snapshot())
	v.restore(next)
	return true
}

// insert puts text in place of the selection.
func (v *View) insert(text string, kind editKind) {
	start, end := v.Selection()
	v.edit(start, end, []byte(text), kind)
}

// SelectAll selects the whole text.
func (v *View) SelectAll() {
	v.anchor, v.caret = 0, v.text.Len()
	v.moved()
}

// SelectedText is the selected text, and empty when nothing is selected.
func (v *View) SelectedText() string {
	start, end := v.Selection()
	return string(v.text.AppendRange(nil, start, end))
}

// moveTo puts the caret at offset; extend keeps the anchor where it is, so the selection
// grows or shrinks, and otherwise the selection collapses to the caret.
func (v *View) moveTo(offset int, extend bool) {
	v.caret = min(max(offset, 0), v.text.Len())
	if !extend {
		v.anchor = v.caret
	}
	v.lastKind = editOther
	v.moved()
}

// moved notes that the caret moved: it shows solid, the next paint scrolls to it, and up and
// down aim at its new column. A vertical move puts the column it aims at back afterwards.
func (v *View) moved() {
	v.reveal = true
	v.blinkFrom = v.clock
	v.goal = -1
}

// prevRune and nextRune are the offsets of the character before and after offset.
func (v *View) prevRune(offset int) int {
	if offset <= 0 {
		return 0
	}
	at := offset - 1
	for at > 0 && !utf8.RuneStart(v.text.ByteAt(at)) {
		at--
	}
	// A line break written as CR LF is one step.
	if v.text.ByteAt(at) == '\n' && at > 0 && v.text.ByteAt(at-1) == '\r' {
		at--
	}
	return at
}

func (v *View) nextRune(offset int) int {
	n := v.text.Len()
	if offset >= n {
		return n
	}
	if v.text.ByteAt(offset) == '\r' && offset+1 < n && v.text.ByteAt(offset+1) == '\n' {
		return offset + 2
	}
	at := offset + 1
	for at < n && !utf8.RuneStart(v.text.ByteAt(at)) {
		at++
	}
	return at
}

// runeAt is the character at offset.
func (v *View) runeAt(offset int) rune {
	var buf [utf8.UTFMax]byte
	n := 0
	for n < len(buf) && offset+n < v.text.Len() {
		buf[n] = v.text.ByteAt(offset + n)
		n++
		if utf8.FullRune(buf[:n]) {
			break
		}
	}
	r, _ := utf8.DecodeRune(buf[:n])
	return r
}

// charClass sorts characters for word steps: spaces, word characters and the rest.
func charClass(r rune) int {
	switch {
	case r == '\n' || r == '\r':
		return 0
	case unicode.IsSpace(r):
		return 1
	case r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r):
		return 2
	}
	return 3
}

// wordLeft and wordRight step over the spaces next to offset and then over a run of one class
// of characters, as Option and the arrow keys do on a Mac.
func (v *View) wordLeft(offset int) int {
	at := offset
	for at > 0 && charClass(v.runeAt(v.prevRune(at))) == 1 {
		at = v.prevRune(at)
	}
	if at > 0 {
		class := charClass(v.runeAt(v.prevRune(at)))
		if class == 0 {
			return v.prevRune(at)
		}
		for at > 0 && charClass(v.runeAt(v.prevRune(at))) == class {
			at = v.prevRune(at)
		}
	}
	return at
}

func (v *View) wordRight(offset int) int {
	n := v.text.Len()
	at := offset
	for at < n && charClass(v.runeAt(at)) == 1 {
		at = v.nextRune(at)
	}
	if at < n {
		class := charClass(v.runeAt(at))
		if class == 0 {
			return v.nextRune(at)
		}
		for at < n && charClass(v.runeAt(at)) == class {
			at = v.nextRune(at)
		}
	}
	return at
}

// wordAt is the word, the run of spaces or the punctuation around offset, for a double click.
func (v *View) wordAt(offset int) (int, int) {
	n := v.text.Len()
	if n == 0 {
		return 0, 0
	}
	at := offset
	if at >= n || charClass(v.runeAt(at)) == 0 {
		if at == 0 {
			return 0, 0
		}
		at = v.prevRune(at)
	}
	class := charClass(v.runeAt(at))
	if class == 0 {
		return offset, offset
	}
	start, end := at, v.nextRune(at)
	for start > 0 && charClass(v.runeAt(v.prevRune(start))) == class {
		start = v.prevRune(start)
	}
	for end < n && charClass(v.runeAt(end)) == class {
		end = v.nextRune(end)
	}
	return start, end
}

// lineRange is line with its line break, for a triple click.
func (v *View) lineRange(line int) (int, int) {
	end := v.text.LineEnd(line)
	if end < v.text.Len() {
		end++
	}
	return v.text.LineStart(line), end
}

// leadingSpace is the indentation of the line offset is on.
func (v *View) leadingSpace(line int) string {
	start, end := v.text.LineStart(line), v.lineEnd(line)
	at := start
	for at < end {
		if b := v.text.ByteAt(at); b != ' ' && b != '\t' {
			break
		}
		at++
	}
	return string(v.text.AppendRange(nil, start, at))
}

// verticalTarget is the offset on row nearest the goal column, counted from the row's start.
func (v *View) verticalTarget(row int) int {
	if v.goal < 0 {
		line, text, rows, k := v.caretPlace()
		v.goal = cellsOf(text, v.caret-v.text.LineStart(line)) - rows[k].cells
	}
	line, sub := v.rowLine(row)
	return v.text.LineStart(line) + v.columnOnRow(line, sub, float32(v.goal))
}
