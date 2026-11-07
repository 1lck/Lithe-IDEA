package term

import "unicode/utf8"

// Limits that keep the memory a hostile or buggy stream can claim bounded.
const (
	maxCols            = 1000
	maxRows            = 500
	maxMarks           = 32   // combining marks kept per line
	maxTitle           = 1024 // bytes of window title
	maxOSC             = 4096 // bytes of one OSC string; longer ones are ignored whole (but see oscPrefixLimits)
	maxHyperlinkTarget = 2048 // bytes retained for one OSC 8 target
	maxHyperlinks      = 8192 // live target slots per terminal; oldest tokens expire after this
	maxTextRun         = 4096 // runes decoded for one text run, which bounds its buffer
)

// DefaultScrollback is the number of lines kept above the screen.
const DefaultScrollback = 5000

// A scrollback line costs the same whatever its age: its cells, its combining
// marks and its hyperlink slots. The byte budget keeps a wide terminal from
// turning the line limit into tens of megabytes; short lines still keep the
// full line count.
const (
	defaultHistoryBytes = 16 << 20
	historyLineOverhead = 112 // the line struct, its slice headers and allocator slack
	historyCellBytes    = 16  // Cell
	historyMarkBytes    = 8   // Mark
	historyLinkBytes    = 4   // one uint32 element of a line's hyperlink slice
	historyLinkOverhead = 24  // that slice's header and allocation
)

// CursorStyle is the cursor shape an application asked for with DECSCUSR.
type CursorStyle uint8

const (
	CursorBlock CursorStyle = iota
	CursorUnderline
	CursorBar
)

// Cursor is where the cursor is drawn, in view rows and columns.
type Cursor struct {
	X, Y    int
	Visible bool
	Style   CursorStyle
	// Steady is set when the application asked for a cursor that does not blink
	// (DECSCUSR 2, 4 or 6). Otherwise whether it blinks is the user's choice.
	Steady bool
}

// MouseMode is which mouse events an application asked to receive.
type MouseMode uint8

const (
	MouseOff    MouseMode = iota
	MouseX10              // 9: presses only
	MouseButton           // 1000: presses and releases
	MouseDrag             // 1002: plus motion while a button is down
	MouseAny              // 1003: all motion
)

// MouseEncoding is how mouse events are reported.
type MouseEncoding uint8

const (
	MouseEncodingX10 MouseEncoding = iota
	MouseEncodingUTF8
	MouseEncodingSGR
	MouseEncodingURXVT
)

// Modes are the terminal modes an application can switch. The owner reads
// them to decide how to encode keys and what to forward.
type Modes struct {
	AppCursorKeys   bool // DECCKM: arrows send SS3 instead of CSI
	AppKeypad       bool // DECKPAM
	BracketedPaste  bool // 2004
	FocusReporting  bool // 1004
	AlternateScroll bool // 1007
	ReverseVideo    bool // DECSCNM
	CursorVisible   bool // DECTCEM
	AltScreen       bool
	Origin          bool // DECOM
	Autowrap        bool // DECAWM
	Insert          bool // IRM
	Newline         bool // LNM: line feed also returns the carriage
	Mouse           MouseMode
	MouseEncoding   MouseEncoding
	// Sync is DECSET 2026's synchronized update mode: the program is between
	// BSU and ESU, and the presentation should not show the screen until the
	// block is complete.
	Sync bool
	// Win32Input is DECSET 9001: the program asked for Windows console key
	// packets (Vk;Sc;Uc;Kd;Cs;Rc). It is only accepted on Windows.
	Win32Input bool
}

type pen struct {
	fg, bg    Color
	attr      Attr
	hyperlink uint32
}

// cell returns a cell painted with the pen's colors and attributes.
func (p pen) cell() Cell {
	return Cell{FG: p.fg, BG: p.bg, Attr: p.attr}
}

// charset is a G0-G3 designation.
type charset uint8

const (
	charsetASCII charset = iota
	charsetGraphics
)

type savedCursor struct {
	valid    bool
	x, y     int
	pend     bool
	pen      pen
	origin   bool
	charsets [4]charset
	gl       uint8
}

// screen is one of the two buffers: the grid and its own saved cursor.
type screen struct {
	lines []*line
	saved savedCursor
	// kittyFlags are the progressive keyboard enhancement flags for this
	// screen, and kittyStack the values pushed before them. The main and
	// alternate screens keep independent stacks, as the kitty protocol
	// requires.
	kittyFlags uint32
	kittyStack []uint32
}

// Terminal is the emulator. Create it with New.
type Terminal struct {
	cols, rows     int
	wordSeparators string

	main, alt screen
	scr       *screen // the active one
	onAlt     bool

	// History is a ring of lines that scrolled off the top of the main
	// screen, oldest first from histHead. len(hist) is the ring's capacity
	// (histMax once the first line arrives) and histCount is how many of those
	// slots hold a line. histBytes is what those lines cost, so a wide terminal
	// can be held to a memory budget and not only to a line count.
	hist       []*line
	histHead   int
	histCount  int
	histBytes  int
	histMax    int
	histBudget int
	histSpare  *line        // an evicted line to reuse, so a budget-bound history does not allocate per line
	view       int          // how many lines the view is scrolled back
	scrolled   uint64       // lines ever pushed into history, kept or dropped
	clock      func() int64 // stamps lines on first write; nil records nothing

	cx, cy   int
	pend     bool // a character was written in the last column; wrap on the next
	pen      pen
	top, bot int // scroll region, inclusive
	tabs     []bool
	charsets [4]charset
	gl       uint8
	modes    Modes
	cursor   CursorStyle
	// defaultCursor is the shape the cursor takes until a program asks for its
	// own with DECSCUSR; SetDefaultCursor sets it from the user's settings.
	defaultCursor CursorStyle
	// cursorStyled says a program has styled the cursor, so the default no
	// longer applies to it.
	cursorStyled      bool
	cursorSteady      bool
	title             string
	hyperlinks        []hyperlinkRecord // allocated only after the first accepted OSC 8 target
	hyperlinkByTarget map[string]uint32
	nextHyperlink     uint32
	images            *imageStore
	kitty             *kittyTransfer
	// imageOps are the inline images whose decode or placement has not been
	// applied yet, in parse order; see image_decode.go.
	imageOps   []*imageJob
	imageBytes int
	imageWake  func()

	replyFn            func([]byte)
	clipboardFn        func(ClipboardWrite)
	notifyFn           func(Notification)
	bellFn             func()
	cwdFn              func(Cwd)
	cwdReportFn        func(Cwd)
	promptReadyFn      func()
	promptStartFn      func()
	promptToken        string
	inputStart         Point // where the shell's editable line begins; see InputMove
	inputStartSet      bool
	inputEnvironmentFn func(InputEnvironment)
	commandStartFn     func()
	commandFinishedFn  func(int)
	syncFn             func(bool)
	cwd                Cwd
	kittyNotes         []kittyPending // OSC 99 notifications still waiting for chunks
	defFG, defBG       [3]uint8
	haveDefaults       bool

	lastRune rune   // for REP
	runBuf   []rune // text decoded for the run path, reused across writes
	nextID   uint64
	version  uint64
	reflow   reflow

	parser
}

// New returns a terminal of the given size keeping at most scrollback lines of
// history. A scrollback of 0 keeps none.
func New(cols, rows, scrollback int) *Terminal {
	t := &Terminal{histMax: max(scrollback, 0), histBudget: defaultHistoryBytes}
	t.cols = clampInt(cols, 1, maxCols)
	t.rows = clampInt(rows, 1, maxRows)
	t.main.lines = t.blankLines(t.rows)
	t.alt.lines = t.blankLines(t.rows)
	t.scr = &t.main
	t.resetState()
	return t
}

func clampInt(value, low, high int) int { return min(max(value, low), high) }

// Size is the grid size in cells.
func (t *Terminal) Size() (cols, rows int) { return t.cols, t.rows }

// Version changes whenever anything visible may have changed: written bytes,
// resizes and scrolling the view. The owner can skip repainting while it holds.
func (t *Terminal) Version() uint64 { return t.version }

// Title is the window title the application set with OSC 0 or 2.
func (t *Terminal) Title() string { return t.title }

// Modes returns the current terminal modes.
func (t *Terminal) Modes() Modes { return t.modes }

// SetReply installs the function that receives the bytes the terminal answers
// with (device attributes, cursor position reports, color queries). The slice
// is only valid during the call; the function must not block.
func (t *Terminal) SetReply(reply func([]byte)) { t.replyFn = reply }

// SetSyncHold installs the receiver for DECSET 2026 transitions. The callback
// runs during Write, after the mode changes and before the bytes that follow
// it are parsed, so the owner can snapshot the screen at the beginning of a
// synchronized update. It must not block. A nil callback ignores the mode.
func (t *Terminal) SetSyncHold(hold func(bool)) { t.syncFn = hold }

// setSync changes the synchronized update mode and tells the owner once.
func (t *Terminal) setSync(on bool) {
	if t.modes.Sync == on {
		return
	}
	t.modes.Sync = on
	if t.syncFn != nil {
		t.syncFn(on)
	}
}

// SetClipboardWrite installs the synchronous receiver for accepted OSC 52
// writes. Clipboard reads are never requested by the emulator. The callback
// runs during Write and must not block.
func (t *Terminal) SetClipboardWrite(write func(ClipboardWrite)) { t.clipboardFn = write }

// SetDefaultColors tells the terminal the default foreground and background so
// it can answer OSC 10 and 11 queries.
func (t *Terminal) SetDefaultColors(foreground, background [3]uint8) {
	t.defFG, t.defBG, t.haveDefaults = foreground, background, true
}

// Scrollback is the number of history lines above the screen.
func (t *Terminal) Scrollback() int { return t.histCount }

// ClearScrollback drops the history above the screen and returns the view to
// the live screen. The screen itself is untouched.
func (t *Terminal) ClearScrollback() {
	if t.histCount == 0 && t.view == 0 {
		return
	}
	t.clearHistory()
	t.version++
}

// ClearScreen drops the history and erases every row except the one the cursor
// is on, which becomes the first row with the cursor in its column. A shell's
// prompt and the command typed on it therefore survive the clear, and the line
// editor's idea of where it is writing stays true: nothing has been sent to the
// shell. It reports false, and leaves the screen alone, on the alternate screen,
// which a full-screen program owns and would paint over the blank rows without
// knowing to redraw them.
func (t *Terminal) ClearScreen() bool {
	if t.onAlt {
		return false
	}
	lines := t.main.lines
	lines[t.cy], lines[0] = lines[0], lines[t.cy]
	for i := 1; i < len(lines); i++ {
		t.eraseLine2(lines[i])
	}
	// What stays on the line above is gone, so it no longer continues it.
	lines[0].wrapped = false
	t.clearHistory()
	t.cy = 0
	t.version++
	return true
}

// ScrollbackLimit is the configured maximum retained history length.
func (t *Terminal) ScrollbackLimit() int { return t.histMax }

// SetScrollbackLimit changes how many main-screen history lines are retained.
// Raising the limit preserves existing history. Lowering it drops the oldest
// lines immediately and releases the larger pointer backing store. The byte
// budget stays a second, independent bound.
func (t *Terminal) SetScrollbackLimit(limit int) {
	limit = max(limit, 0)
	if limit == t.histMax {
		return
	}
	t.histMax = limit
	if limit == 0 {
		t.clearHistory()
		t.version++
		return
	}
	if t.hist == nil {
		return
	}
	count := min(t.histCount, limit)
	kept := make([]*line, limit)
	start := t.histCount - count
	for i := 0; i < count; i++ {
		kept[i] = t.histAt(start + i)
	}
	for i := 0; i < start; i++ {
		if t.images != nil {
			t.images.dropLine(t.histAt(i).id)
		}
	}
	t.hist = kept
	t.histHead = 0
	t.histCount = count
	t.histBytes = t.historyBytes()
	t.view = min(t.view, count)
	t.trimHistory()
	t.version++
}

// ViewOffset is how many lines the view is scrolled back from the live screen.
func (t *Terminal) ViewOffset() int { return t.view }

// Scroll moves the view by lines (positive goes back into history) and reports
// whether it moved. The alternate screen has no history.
func (t *Terminal) Scroll(lines int) bool {
	if t.onAlt {
		return false
	}
	view := clampInt(t.view+lines, 0, t.histCount)
	if view == t.view {
		return false
	}
	t.view = view
	t.version++
	return true
}

// ScrollToBottom returns the view to the live screen.
func (t *Terminal) ScrollToBottom() bool { return t.Scroll(-t.view) }

// Cursor is the cursor position in view coordinates. It is not Visible when
// the application hid it or when the view is scrolled so far back that the
// cursor line is off screen.
func (t *Terminal) Cursor() Cursor {
	row := t.cy + t.view
	return Cursor{X: t.cx, Y: row, Visible: t.modes.CursorVisible && row < t.rows, Style: t.cursor, Steady: t.cursorSteady}
}

// Row returns view row i (0 is the top).
func (t *Terminal) Row(i int) Row { return t.rowOf(t.lineAt(i)) }

func (t *Terminal) rowOf(l *line) Row {
	cells := l.cells
	if len(cells) > t.cols {
		cells = cells[:t.cols]
	}
	markColumns := len(cells)
	if markColumns > 0 && cells[markColumns-1].Attr&WideHead != 0 {
		markColumns--
		if background := cells[markColumns].BG; background != 0 {
			// Keep the boundary's background without changing retained history.
			cells = append([]Cell(nil), cells...)
			cells[markColumns] = Cell{BG: background}
		} else {
			cells = cells[:markColumns]
		}
	}
	marks := l.marks
	// Marks are sorted by column; those past a cut belong to cells that are
	// no longer shown.
	for len(marks) > 0 && int(marks[len(marks)-1].Col) >= markColumns {
		marks = marks[:len(marks)-1]
	}
	return Row{Cells: cells, Marks: marks, ID: l.id, Version: l.version, Wrapped: l.wrapped, Written: l.at}
}

func (t *Terminal) lineAt(i int) *line {
	k := t.histCount - t.view + i
	if k < t.histCount {
		return t.histAt(k)
	}
	return t.scr.lines[k-t.histCount]
}

func (t *Terminal) histAt(i int) *line { return t.hist[(t.histHead+i)%len(t.hist)] }

// lineHistoryBytes is what one line costs the history budget: its cell and mark
// backing arrays, its hyperlink slots and the line struct itself. len, not cap,
// would undercount the allocator's size class, so cap is what is counted.
func lineHistoryBytes(l *line) int {
	bytes := historyLineOverhead + cap(l.cells)*historyCellBytes + cap(l.marks)*historyMarkBytes
	if l.hyperlinks != nil {
		bytes += historyLinkOverhead + cap(*l.hyperlinks)*historyLinkBytes
	}
	return bytes
}

// historyBytes is the cost of every line now in the ring.
func (t *Terminal) historyBytes() int {
	bytes := 0
	for i := 0; i < t.histCount; i++ {
		bytes += lineHistoryBytes(t.histAt(i))
	}
	return bytes
}

// dropOldest gives back the oldest line, without touching the view: callers
// that add a line adjust the view themselves.
func (t *Terminal) dropOldest() {
	l := t.hist[t.histHead]
	if t.images != nil {
		t.images.dropLine(l.id)
	}
	t.hist[t.histHead] = nil
	t.histBytes -= lineHistoryBytes(l)
	t.histHead = (t.histHead + 1) % len(t.hist)
	t.histCount--
	if t.histCount == 0 {
		t.histHead = 0
	}
}

// trimHistory keeps the ring within its byte budget. The line limit alone
// cannot: a width change makes the same number of lines cost several times as
// much, and old lines keep the width they were written at.
func (t *Terminal) trimHistory() {
	if t.histBudget <= 0 {
		return
	}
	for t.histBytes > t.histBudget && t.histCount > 0 {
		if t.histSpare == nil {
			t.histSpare = t.hist[t.histHead]
		}
		t.dropOldest()
	}
	t.view = min(t.view, t.histCount)
}

// SetDefaultCursor sets the shape the cursor takes until a program asks for
// its own with DECSCUSR: at construction, and after a reset. A cursor a program
// has styled keeps its shape. The change reaches the screen when it repaints.
func (t *Terminal) SetDefaultCursor(style CursorStyle) {
	if t.defaultCursor == style {
		return
	}
	t.defaultCursor = style
	if !t.cursorStyled {
		t.cursor = style
	}
	t.version++
}

// Reset restores the power-on state and clears the screen. History stays.
func (t *Terminal) Reset() {
	t.parser = parser{}
	t.kitty = nil
	t.discardImageJobs()
	if t.images != nil {
		t.images.deleteAll()
	}
	t.alt.saved, t.main.saved = savedCursor{}, savedCursor{}
	t.onAlt, t.scr = false, &t.main
	t.pen = pen{}
	for _, s := range []*screen{&t.main, &t.alt} {
		for i, l := range s.lines {
			s.lines[i] = t.recycle(l)
		}
	}
	t.view = 0
	t.title = ""
	t.resetState()
}

// resetState sets modes, cursor, margins and tabs to their defaults.
func (t *Terminal) resetState() {
	t.inputStartSet = false
	t.setSync(false)
	t.cx, t.cy, t.pend = 0, 0, false
	t.top, t.bot = 0, t.rows-1
	t.charsets, t.gl = [4]charset{}, 0
	t.cursor, t.cursorSteady = t.defaultCursor, false
	t.cursorStyled = false
	// Alternate scroll starts on, as in VTE, kitty and Windows Terminal: a pager
	// or editor that did not ask for the mouse still scrolls with the wheel. A
	// program turns it off with 1007 reset.
	t.modes = Modes{CursorVisible: true, Autowrap: true, AlternateScroll: true}
	t.ResetKeyboard()
	t.tabs = defaultTabs(t.cols, nil)
	t.version++
}

func defaultTabs(cols int, old []bool) []bool {
	previous := len(old)
	var tabs []bool
	if cap(old) >= cols {
		tabs = old[:cols]
	} else {
		tabs = make([]bool, cols)
		copy(tabs, old)
	}
	for x := len(old); x < cols; x++ {
		tabs[x] = x > 0 && x%8 == 0
	}
	if previous > cols {
		clear(tabs[cols:cap(tabs)])
	}
	return tabs
}

func (t *Terminal) blankCell() Cell { return Cell{BG: t.pen.bg} }

// touch records that columns up to end have been written. Columns past it still
// hold the blank the line was recycled with, so pushHistory starts trimming
// there instead of at the row's width.
func (l *line) touch(end int) {
	if end > l.used {
		l.used = min(end, len(l.cells))
	}
}

// span hands out cells x..x+n to be written and records the row as written up
// to there. Cells past used are blank, so anything but a blank goes through
// here; a write that skips it leaves text the scrollback then trims away.
func (l *line) span(x, n int) []Cell {
	l.touch(x + n)
	return l.cells[x : x+n]
}

// fill writes cell over cells a..b-1. A blank that carries a background is
// content of its own, so the row counts as written up to b.
func (l *line) fill(a, b int, cell Cell) {
	if cell != (Cell{}) {
		l.touch(b)
	}
	cells := l.cells[a:b]
	for i := range cells {
		cells[i] = cell
	}
}

func (t *Terminal) blankLines(n int) []*line {
	lines := make([]*line, n)
	for i := range lines {
		lines[i] = t.allocLine()
	}
	return lines
}

func (t *Terminal) allocLine() *line { return t.recycle(&line{}) }

// recycle turns l into a fresh blank line of the current width, reusing its
// storage. Giving it a new ID keeps caches built from the old content honest.
func (t *Terminal) recycle(l *line) *line {
	// A recycled row is written from column zero again, so it only has to lose
	// what it wrote: the cells past used are blank already. They can hold stale
	// cells when the row grows back over a width it had before, so the cells a
	// shorter slice never covered are cleared too.
	to := l.used
	if cap(l.cells) < t.cols {
		l.cells = make([]Cell, t.cols)
		to = 0
	} else {
		if t.cols > len(l.cells) {
			// The row grew back over a width it had before: the cells the
			// shorter slice never covered can still hold its old content.
			to = t.cols
		}
		l.cells = l.cells[:t.cols]
	}
	// The runtime zeroes cells faster than the blank-cell loop can store them.
	if blank := t.blankCell(); blank == (Cell{}) {
		clear(l.cells[:to])
		l.used = 0
	} else {
		l.fill(0, len(l.cells), blank)
	}
	l.marks = l.marks[:0]
	l.hyperlinks = nil
	l.wrapped = false
	l.at = 0
	t.nextID++
	l.id = t.nextID
	l.version = 0
	return l
}

// pushHistory appends a copy of l, without its trailing blanks, to the
// history. When the ring is full the oldest line's storage is reused; when the
// byte budget is reached the oldest lines are dropped.
func (t *Terminal) pushHistory(l *line) {
	t.scrolled++
	if t.histMax == 0 {
		return
	}
	used := l.used
	for used > 0 && l.cells[used-1] == (Cell{}) && l.hyperlinkAt(used-1) == 0 {
		used--
	}
	if t.hist == nil {
		t.hist = make([]*line, t.histMax)
	}
	var dst *line
	if t.histCount == t.histMax {
		dst = t.hist[t.histHead]
		t.dropOldest()
	} else if t.histSpare != nil {
		dst, t.histSpare = t.histSpare, nil
	} else {
		dst = &line{}
	}
	if cap(dst.cells) < used || cap(dst.cells) > 4*used+64 {
		dst.cells = make([]Cell, used)
	}
	dst.cells = dst.cells[:used]
	dst.used = used
	copy(dst.cells, l.cells[:used])
	dst.marks = append(dst.marks[:0], l.marks...)
	if used > 0 && l.hyperlinks != nil {
		links := append([]uint32(nil), (*l.hyperlinks)[:used]...)
		dst.hyperlinks = &links
	} else {
		dst.hyperlinks = nil
	}
	dst.wrapped, dst.id, dst.version, dst.at = l.wrapped, l.id, l.version, l.at
	t.hist[(t.histHead+t.histCount)%t.histMax] = dst
	t.histCount++
	t.histBytes += lineHistoryBytes(dst)
	if t.view > 0 {
		// Keep the same content in view while new lines arrive.
		t.view++
	}
	t.trimHistory()
	t.view = min(t.view, t.histCount)
}

// popHistory removes the newest history line and returns it widened to the
// current column count.
func (t *Terminal) popHistory() *line {
	last := (t.histHead + t.histCount - 1) % len(t.hist)
	h := t.hist[last]
	t.scrolled--
	t.hist[last] = nil
	t.histCount--
	t.histBytes -= lineHistoryBytes(h)
	if t.histCount == 0 {
		t.histHead = 0
	}
	l := &line{cells: append([]Cell(nil), h.cells...), marks: append([]Mark(nil), h.marks...),
		wrapped: h.wrapped, id: h.id, version: h.version, at: h.at}
	if h.hyperlinks != nil {
		links := append([]uint32(nil), (*h.hyperlinks)...)
		l.hyperlinks = &links
	}
	t.fitCols(l)
	l.used = len(l.cells)
	t.view = min(t.view, t.histCount)
	return l
}

func (t *Terminal) clearHistory() {
	if t.images != nil {
		for i := 0; i < t.histCount; i++ {
			t.images.dropLine(t.histAt(i).id)
		}
	}
	clear(t.hist)
	t.hist, t.histHead, t.histCount, t.histBytes, t.view = nil, 0, 0, 0, 0
}

// index moves the cursor down one line, scrolling at the bottom margin.
func (t *Terminal) index() {
	switch {
	case t.cy == t.bot:
		t.scrollUp(1)
	case t.cy < t.rows-1:
		t.cy++
	}
}

// reverseIndex moves the cursor up one line, scrolling at the top margin.
func (t *Terminal) reverseIndex() {
	switch {
	case t.cy == t.top:
		t.scrollDown(1)
	case t.cy > 0:
		t.cy--
	}
}

// scrollUp scrolls the scroll region up by n, pushing lines that leave the top
// of the main screen into the history.
func (t *Terminal) scrollUp(n int) {
	t.rotate(t.top, t.bot, n, true, !t.onAlt && t.top == 0)
}

func (t *Terminal) scrollDown(n int) { t.rotate(t.top, t.bot, n, false, false) }

// rotate scrolls lines top..bottom by n, filling the vacated lines with blanks.
func (t *Terminal) rotate(top, bottom, n int, up, toHistory bool) {
	n = min(n, bottom-top+1)
	lines := t.scr.lines
	for k := 0; k < n; k++ {
		if up {
			l := lines[top]
			if toHistory {
				t.pushHistory(l)
			}
			copy(lines[top:bottom], lines[top+1:bottom+1])
			lines[bottom] = t.recycle(l)
		} else {
			l := lines[bottom]
			copy(lines[top+1:bottom+1], lines[top:bottom])
			lines[top] = t.recycle(l)
		}
	}
	t.version++
}

// Resize changes the grid size. A new width reflows the main screen and its
// history (see reflowMain); the alternate screen, which its program redraws,
// truncates or pads. Shrinking pushes the lines above the cursor into the
// history, growing pulls them back, so a shell that redraws its prompt keeps
// its place.
func (t *Terminal) Resize(cols, rows int) {
	cols = clampInt(cols, 1, maxCols)
	rows = clampInt(rows, 1, maxRows)
	if cols == t.cols && rows == t.rows {
		return
	}
	oldCols := t.cols
	t.cols = cols
	if cols != oldCols {
		t.inputStartSet = false // reflow moves the line the shell is editing
	}
	t.tabs = defaultTabs(cols, t.tabs[:min(oldCols, cols)])
	if cols != oldCols {
		t.reflowMain()
	}

	cursor := &t.cy
	if t.onAlt {
		t.resizeLines(&t.main, rows, nil, true)
		t.resizeLines(&t.alt, rows, cursor, false)
	} else {
		t.resizeLines(&t.main, rows, cursor, true)
		t.resizeLines(&t.alt, rows, nil, false)
	}
	t.rows = rows
	t.top, t.bot = 0, rows-1
	t.cx = min(t.cx, cols-1)
	t.cy = clampInt(t.cy, 0, rows-1)
	t.pend = false
	t.view = min(t.view, t.histCount)
	t.version++
}

// resizeLines adapts one buffer to the new row count (and the already updated
// column count). cursorY, when set, is the cursor row to keep on screen.
func (t *Terminal) resizeLines(s *screen, rows int, cursorY *int, useHistory bool) {
	for _, l := range s.lines {
		t.fitCols(l)
	}
	switch {
	case rows < len(s.lines):
		drop := 0
		if cursorY != nil {
			drop = max(0, *cursorY-(rows-1))
		}
		if useHistory {
			for _, l := range s.lines[:drop] {
				t.pushHistory(l)
			}
		} else if t.images != nil {
			for _, l := range s.lines[:drop] {
				t.images.dropLine(l.id)
			}
		}
		if t.images != nil {
			for _, l := range s.lines[drop+rows:] {
				t.images.dropLine(l.id)
			}
		}
		next := make([]*line, rows)
		copy(next, s.lines[drop:])
		s.lines = next
		if cursorY != nil {
			*cursorY -= drop
		}
	case rows > len(s.lines):
		pulled := 0
		if useHistory && cursorY != nil {
			pulled = min(rows-len(s.lines), t.histCount)
		}
		next := make([]*line, 0, rows)
		for i := 0; i < pulled; i++ {
			next = append(next, nil)
		}
		for i := pulled - 1; i >= 0; i-- {
			next[i] = t.popHistory()
		}
		next = append(next, s.lines...)
		for len(next) < rows {
			next = append(next, t.allocLine())
		}
		s.lines = next
		if cursorY != nil {
			*cursorY += pulled
		}
	}
}

// fitCols makes l exactly as wide as the terminal.
func (t *Terminal) fitCols(l *line) {
	changed := false
	switch {
	case len(l.cells) > t.cols:
		if l.used > t.cols {
			changed = true
		}
		l.cells = l.cells[:t.cols]
		for len(l.marks) > 0 && int(l.marks[len(l.marks)-1].Col) >= t.cols {
			l.marks = l.marks[:len(l.marks)-1]
			changed = true
		}
		if l.cells[t.cols-1].Attr&WideHead != 0 { // its tail was cut off
			l.orphan(t.cols - 1)
			changed = true
		}
	case len(l.cells) < t.cols:
		if cap(l.cells) >= t.cols {
			old := len(l.cells)
			l.cells = l.cells[:t.cols]
			clear(l.cells[old:])
		} else {
			grown := make([]Cell, t.cols)
			copy(grown, l.cells)
			l.cells = grown
		}
	default:
		l.fitHyperlinks(t.cols)
		return
	}
	l.used = min(l.used, len(l.cells))
	l.fitHyperlinks(t.cols)
	if changed {
		l.version++
	}
}

// eraseRange blanks cells a..b-1 of l with the current background, repairing
// any double-width character the cut splits.
func (t *Terminal) eraseRange(l *line, a, b int) {
	a, b = max(a, 0), min(b, t.cols)
	if a >= b {
		return
	}
	if t.images != nil {
		t.images.erase(l.id, a, b)
	}
	l.dropMarks(a, b)
	l.fill(a, b, t.blankCell())
	if l.hyperlinks != nil {
		clear((*l.hyperlinks)[a:b])
		if a == 0 && b == t.cols {
			l.hyperlinks = nil
		}
	}
	t.repairWide(l, a-1)
	t.repairWide(l, b)
	l.version++
}

// repairWide blanks the orphan half of a double-width character at x.
func (t *Terminal) repairWide(l *line, x int) {
	if x < 0 || x >= len(l.cells) {
		return
	}
	switch c := &l.cells[x]; {
	case c.Attr&WideTail != 0 && (x == 0 || l.cells[x-1].Attr&WideHead == 0):
		l.orphan(x)
	case c.Attr&WideHead != 0 && (x+1 >= len(l.cells) || l.cells[x+1].Attr&WideTail == 0):
		l.orphan(x)
	}
}

// orphan blanks cell x, keeping its background, and drops its marks.
func (l *line) orphan(x int) {
	l.cells[x] = Cell{BG: l.cells[x].BG}
	if l.hyperlinks != nil {
		(*l.hyperlinks)[x] = 0
	}
	l.dropMarks(x, x+1)
}

// dropMarks removes the combining marks attached to cells a..b-1.
func (l *line) dropMarks(a, b int) {
	if len(l.marks) == 0 {
		return
	}
	kept := l.marks[:0]
	for _, m := range l.marks {
		if int(m.Col) < a || int(m.Col) >= b {
			kept = append(kept, m)
		}
	}
	l.marks = kept
}

// text returns the characters of l, trailing blanks trimmed.
func (l *line) text(cols int) string {
	cells := l.cells
	if len(cells) > cols {
		cells = cells[:cols]
	}
	runes := make([]rune, 0, len(cells))
	m := 0
	for x, c := range cells {
		if c.Attr&WideTail != 0 {
			continue
		}
		if c.R == 0 {
			runes = append(runes, ' ')
		} else {
			runes = append(runes, c.R)
		}
		for m < len(l.marks) && int(l.marks[m].Col) < x {
			m++
		}
		for k := m; k < len(l.marks) && int(l.marks[k].Col) == x; k++ {
			runes = append(runes, l.marks[k].R)
		}
	}
	for len(runes) > 0 && runes[len(runes)-1] == ' ' {
		runes = runes[:len(runes)-1]
	}
	return string(runes)
}

// RowText is the text of view row i with trailing spaces removed.
func (t *Terminal) RowText(i int) string { return t.lineAt(i).text(t.cols) }

// AppendCellText appends the text of cells [from, to) of view row y to dst, the
// way RowText writes a row but over an exact range and without trimming: an
// empty cell reads as a space, the tail of a wide character adds nothing and
// combining marks follow the cell they belong to. ok is false when the range
// lies outside the row or starts or ends inside a wide character.
func (t *Terminal) AppendCellText(dst []byte, y, from, to int) ([]byte, bool) {
	if y < 0 || y >= t.rows || from < 0 || from > to || to > t.cols {
		return dst, false
	}
	l := t.lineAt(y)
	cell := func(x int) Cell {
		if x < len(l.cells) {
			return l.cells[x]
		}
		return Cell{}
	}
	if from < to && cell(from).Attr&WideTail != 0 || to < t.cols && from < to && cell(to).Attr&WideTail != 0 {
		return dst, false
	}
	for x := from; x < to; x++ {
		c := cell(x)
		if c.Attr&WideTail != 0 {
			continue
		}
		r := c.R
		if r == 0 {
			r = ' '
		}
		dst = utf8.AppendRune(dst, r)
		for _, mark := range l.marks {
			if int(mark.Col) == x {
				dst = utf8.AppendRune(dst, mark.R)
			}
		}
	}
	return dst, true
}

// Text is the whole view as lines of text, trailing empty lines removed.
func (t *Terminal) Text() string {
	rows := make([]string, t.rows)
	last := -1
	for i := range rows {
		rows[i] = t.RowText(i)
		if rows[i] != "" {
			last = i
		}
	}
	out := ""
	for i := 0; i <= last; i++ {
		if i > 0 {
			out += "\n"
		}
		out += rows[i]
	}
	return out
}

// AppendRetainedText appends the visible text retained by the active terminal
// buffer to dst and returns the extended slice. Main-screen scrollback is
// included in chronological order. Soft-wrapped rows are joined; hard line
// breaks are preserved; trailing empty rows are omitted. Concealed cells are
// exported as spaces rather than leaking their contents.
func (t *Terminal) AppendRetainedText(dst []byte) []byte {
	start := len(dst)
	for index := 0; index < t.bufferLineCount(); index++ {
		line := t.bufferLine(index)
		lineStart := len(dst)
		mark := 0
		for column, cell := range line.cells {
			if column >= t.cols {
				break
			}
			if cell.Attr&WideTail != 0 {
				continue
			}
			value := cell.R
			if value == 0 || cell.Attr&Hidden != 0 {
				value = ' '
			}
			dst = utf8.AppendRune(dst, value)
			for mark < len(line.marks) && int(line.marks[mark].Col) < column {
				mark++
			}
			if cell.Attr&Hidden == 0 {
				for mark < len(line.marks) && int(line.marks[mark].Col) == column {
					dst = utf8.AppendRune(dst, line.marks[mark].R)
					mark++
				}
			}
		}
		for len(dst) > lineStart && dst[len(dst)-1] == ' ' {
			dst = dst[:len(dst)-1]
		}
		if !line.wrapped {
			dst = append(dst, '\n')
		}
	}
	for len(dst) > start && dst[len(dst)-1] == '\n' {
		dst = dst[:len(dst)-1]
	}
	return dst
}

// SetClock makes the terminal remember when each line is first written: now
// returns unix seconds and is called once per line, not per character. A nil
// clock stops recording and costs one nil check per printed run. Lines keep
// their time when they scroll into the history.
func (t *Terminal) SetClock(now func() int64) { t.clock = now }

// LineNumber is the 1-based number of view row i among every line the main
// screen has produced since the terminal started. It keeps counting as the
// history drops its oldest lines, and is not meaningful on the alternate
// screen.
func (t *Terminal) LineNumber(i int) uint64 { return t.scrolled - uint64(t.view) + uint64(i) + 1 }

// stamp records the first write to l.
func (t *Terminal) stamp(l *line) {
	if t.clock != nil && l.at == 0 {
		l.at = t.clock()
	}
}
