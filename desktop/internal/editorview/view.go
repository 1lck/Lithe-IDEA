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
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
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
	HitID ui.ID
	// Label names the view for assistive technology: the file's name.
	Label string
	// Text is the document's content as it was read.
	Text []byte
	// Syntax colors the text; nil shows it in one color.
	Syntax *syntax.Syntax
	// Notify wakes the window when the background highlighter has colored lines anew.
	Notify func()
	// Save asks the window to write the text out, for the save chord.
	Save func()
}

// Look is the view's colors for the frame being painted.
type Look struct {
	Dark bool
	// Background is the editor's ground, Foreground its plain text and Subtle the line
	// numbers.
	Background, Foreground, Subtle ui.Color
	// CurrentLine is the band behind the caret's line, Selection the selected text's ground
	// and Caret the caret.
	CurrentLine, Selection, Caret ui.Color
	// Scrollbar is the thumb of the scrollbars.
	Scrollbar ui.Color
}

// snapshot is the text and the selection before or after an edit, as undo restores them.
type snapshot struct {
	text            rope.Rope
	anchor, caret   int
	scrollX, scroll float32
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
	// anchor and caret are the ends of the selection; they are equal when nothing is
	// selected. goal is the column, in cells, that up and down keep to; -1 is the caret's.
	anchor, caret int
	goal          int
	undo, redo    []snapshot
	// lastKind and lastEnd say what the last edit was and where it left the caret, so that
	// typing on goes into the same undo step.
	lastKind editKind
	lastEnd  int
	// indentUnit is what Tab inserts: a tab in a file indented with tabs, spaces otherwise.
	indentUnit string
	// widest is the most cells any line takes, for the horizontal scroll range. It only grows
	// while the view is open.
	widest int

	hl    *syntax.Highlighter
	theme *syntax.Theme
	// themeDark and themeFG are what theme was built for.
	themeDark bool
	themeFG   ui.Color

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

	// scroll and scrollX are how far the text is scrolled, in pixels.
	scroll, scrollX float32
	// reveal asks the next paint to scroll the caret into view.
	reveal bool
	// The geometry of the last paint, which the pointer and the text input use.
	area             ui.Rect
	textLeft         float32
	cellW, cellH     float32
	lineH            float32
	painted, focused bool

	dragging bool
	// dragUnit is what a drag selects by: 1 characters, 2 words, 3 lines; dragFrom and
	// dragTo are the unit the drag started on.
	dragUnit         int
	dragFrom, dragTo int

	preedit app.TextState
	input   app.TextInput
	// blinkFrom is when the caret last moved; it is solid for a period after.
	blinkFrom time.Duration
	clock     time.Duration

	tokens  []syntax.Token
	runs    []ui.TextRun
	display []byte
	// numbers is the line numbers a paint puts in the gutter once the text is drawn.
	numbers []gutterNumber
}

// New makes the view of a document.
func New(cfg Config) *View {
	text := rope.New(cfg.Text)
	v := &View{cfg: cfg, text: text, saved: text, goal: -1, indentUnit: indentUnit(text)}
	v.widest = v.scanWidest(0, text.LineCount()-1)
	notify := cfg.Notify
	v.hl = syntax.NewHighlighter(cfg.Syntax, text, syntax.HighlighterOptions{
		OnChange: func(first, last int) {
			if notify != nil {
				notify()
			}
		},
	})
	return v
}

// Owns reports whether id is the view's hit.
func (v *View) Owns(id ui.ID) bool { return id == v.cfg.HitID }

// Close stops the view's background highlighter.
func (v *View) Close() { v.hl.Close() }

// Dirty reports whether the text differs from the text last read or written.
func (v *View) Dirty() bool { return v.dirty }

// compare works out whether the text differs from the saved text, after it changed.
func (v *View) compare() {
	v.dirty = !v.text.Same(v.saved) && (v.text.Len() != v.saved.Len() || !bytes.Equal(v.text.Bytes(), v.saved.Bytes()))
}

// Text is the document's current content, and the rope it was taken from for MarkSaved.
func (v *View) Text() ([]byte, rope.Rope) { return v.text.Bytes(), v.text }

// MarkSaved records that text was written out, so the view is clean while it shows it.
func (v *View) MarkSaved(text rope.Rope) {
	v.saved = text
	v.compare()
}

// SetLabel changes the name the view gives assistive technology.
func (v *View) SetLabel(label string) { v.cfg.Label = label }

// Selection is the selection's start and end, in order.
func (v *View) Selection() (int, int) { return min(v.anchor, v.caret), max(v.anchor, v.caret) }

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

// scanWidest is the most cells a line from first to last takes.
func (v *View) scanWidest(first, last int) int {
	widest := 0
	for line := first; line <= last && line < v.text.LineCount(); line++ {
		n := v.text.LineEnd(line) - v.text.LineStart(line)
		if n <= widest {
			continue
		}
		widest = max(widest, cellsOf(v.text.Line(line), n))
	}
	return widest
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
	firstLine, oldLast, oldCount := v.text.LineOf(start), v.text.LineOf(end), v.text.LineCount()
	v.text = v.text.Replace(start, end, text)
	v.hl.Edit(v.text, start, end, start+len(text))
	v.spliceRows(firstLine, oldLast, v.text.LineOf(start+len(text)), oldCount)
	v.anchor, v.caret = start+len(text), start+len(text)
	v.lastKind, v.lastEnd = kind, v.caret
	if kind == editDeleting {
		v.lastEnd = start
	}
	v.widest = max(v.widest, v.scanWidest(firstLine, v.text.LineOf(v.caret)))
	v.compare()
	v.moved()
}

// snapshot is the text and selection as they are now.
func (v *View) snapshot() snapshot {
	return snapshot{text: v.text, anchor: v.anchor, caret: v.caret, scroll: v.scroll, scrollX: v.scrollX}
}

// restore makes s the view's text and selection.
func (v *View) restore(s snapshot) {
	v.text = s.text
	v.hl.SetText(s.text)
	v.forgetRows()
	v.anchor, v.caret = s.anchor, s.caret
	v.lastKind = editOther
	v.widest = max(v.widest, v.scanWidest(0, v.text.LineCount()-1))
	v.compare()
	v.moved()
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
