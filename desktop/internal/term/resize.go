package term

// reflowAnchor is a position in the main buffer (history then screen) that has
// to follow its character through a reflow: the cursor, the saved cursor, the
// first screen row. index and col are the old position going in and the new
// one coming out.
type reflowAnchor struct {
	index, col int
	offset     int  // in the logical line, while its run is being rewrapped
	cursor     bool // a cursor keeps the blanks before it as part of its line
	moved      bool
	inRun      bool
}

// reflowMark is a combining mark at its offset in a logical line.
type reflowMark struct {
	offset int
	r      rune
}

// reflow is the scratch a main-screen reflow reuses from one resize to the next.
type reflow struct {
	lines []*line
	cells []Cell
	links []uint32
	marks []reflowMark
	run   []*line
	ends  []int // where each new row of the run ends in the logical line
}

// reflowMain rewraps the main screen and its history at the new width. The
// rows a long line was wrapped into are joined back into that line and split
// again, so narrowing the terminal moves text to the next row instead of cutting
// it off, and widening puts it back on one row. A row keeps its ID where it can;
// the cursor and the saved cursor stay on the character they were on. Nothing
// changes when every line already fits unwrapped.
func (t *Terminal) reflowMain() {
	s := &t.main
	total := t.histCount + len(s.lines)
	if !t.mainNeedsReflow(total) && (t.onAlt || t.cx < t.cols) && (!s.saved.valid || s.saved.x < t.cols) {
		return
	}
	rows := len(s.lines)
	anchors := [3]reflowAnchor{{index: t.histCount}, {moved: true}, {moved: true}}
	top := &anchors[0]
	var cursor, saved *reflowAnchor
	if !t.onAlt {
		cursor = &anchors[1]
		*cursor = reflowAnchor{index: t.histCount + t.cy, col: t.cx, cursor: true}
	}
	if s.saved.valid {
		// A saved cursor keeps the row it was set on and is clamped when it is
		// restored, so a screen that has since shrunk can leave its row past
		// the buffer. The anchor below is a buffer index, so clamp it the way
		// restoreCursor will.
		saved = &anchors[2]
		*saved = reflowAnchor{
			index:  t.histCount + min(s.saved.y, len(s.lines)-1),
			col:    min(s.saved.x, t.cols-1),
			cursor: true,
		}
	}

	r := &t.reflow
	r.lines = r.lines[:0]
	for first := 0; first < total; {
		last := first
		for last < total-1 && t.mainLine(last).wrapped {
			last++
		}
		l := t.mainLine(first)
		width := l.contentWidth()
		for _, a := range anchors {
			if a.cursor && !a.moved && a.index == first {
				width = max(width, a.col+1)
			}
		}
		if first == last && width <= t.cols {
			for i := range anchors {
				if a := &anchors[i]; !a.moved && a.index == first {
					a.index, a.col, a.moved = len(r.lines), min(a.col, t.cols-1), true
				}
			}
			l.wrapped = false
			r.lines = append(r.lines, l)
		} else {
			t.rewrap(first, last, &anchors)
		}
		first = last + 1
	}

	// The screen keeps its top line, unless that would push the cursor off the
	// bottom or the cursor was on the bottom row, which stays where it is. Under
	// the alternate screen the cursor to come back to is the saved one.
	start := top.index
	follow, followY := cursor, t.cy
	if follow == nil {
		follow, followY = saved, min(s.saved.y, len(s.lines)-1)
	}
	if follow != nil && follow.moved && (followY == rows-1 || follow.index-start >= rows) {
		start = follow.index - (rows - 1)
	}
	// Every anchor followed its character above; this only keeps a start that
	// no line can hold from slicing past the buffer.
	start = clampInt(start, 0, max(len(r.lines)-1, 0))
	end := min(start+rows, len(r.lines))
	if t.images != nil {
		for _, l := range r.lines[end:] {
			t.images.dropLine(l.id)
		}
	}
	for i := range s.lines {
		var l *line
		if start+i < end {
			l = r.lines[start+i]
		} else {
			l = t.allocLine()
		}
		t.fitCols(l)
		s.lines[i] = l
	}
	t.refillHistory(r.lines[:start])
	clear(r.lines)

	if cursor != nil {
		t.cy, t.cx = clampInt(cursor.index-start, 0, rows-1), cursor.col
	}
	if saved != nil {
		s.saved.y, s.saved.x = clampInt(saved.index-start, 0, rows-1), saved.col
	}
}

// mainNeedsReflow reports whether any line is wrapped or no longer fits.
func (t *Terminal) mainNeedsReflow(total int) bool {
	for i := 0; i < total; i++ {
		if l := t.mainLine(i); l.wrapped || l.contentWidth() > t.cols {
			return true
		}
	}
	return false
}

// mainLine is line i of the main buffer: the history, oldest first, then the
// screen.
func (t *Terminal) mainLine(i int) *line {
	if i < t.histCount {
		return t.histAt(i)
	}
	return t.main.lines[i-t.histCount]
}

// rewrap joins main lines first..last, one logical line, and appends it split
// at the terminal's width to the reflow's lines, moving the anchors inside it.
func (t *Terminal) rewrap(first, last int, anchors *[3]reflowAnchor) {
	r := &t.reflow
	r.cells, r.links, r.marks, r.run = r.cells[:0], r.links[:0], r.marks[:0], r.run[:0]
	linked := false
	for index := first; index <= last; index++ {
		l := t.mainLine(index)
		r.run = append(r.run, l)
		width := l.contentWidth()
		base := len(r.cells)
		for i := range anchors {
			if a := &anchors[i]; !a.moved && a.index == index {
				if a.cursor {
					// A cursor past the text keeps its column: the blanks up to
					// it are part of the line.
					width = max(width, min(a.col+1, len(l.cells)))
				}
				a.offset, a.inRun = base+min(a.col, max(width-1, 0)), true
			}
		}
		r.cells = append(r.cells, l.cells[:width]...)
		if l.hyperlinks != nil && !linked {
			linked = true
			r.links = append(r.links[:0], make([]uint32, base)...)
		}
		if l.hyperlinks != nil {
			r.links = append(r.links, (*l.hyperlinks)[:width]...)
		} else if linked {
			r.links = append(r.links, make([]uint32, width)...)
		}
		for _, m := range l.marks {
			if int(m.Col) < width {
				r.marks = append(r.marks, reflowMark{offset: base + int(m.Col), r: m.R})
			}
		}
	}

	// Split it again, a wide character that would straddle the edge moving to
	// the next row whole.
	r.ends = r.ends[:0]
	for at := 0; at < len(r.cells) || len(r.ends) == 0; {
		col := 0
		for at < len(r.cells) && col < t.cols {
			if r.cells[at].Attr&WideHead != 0 && t.cols >= 2 && col == t.cols-1 {
				break
			}
			step := 1
			if r.cells[at].Attr&WideHead != 0 && at+1 < len(r.cells) && r.cells[at+1].Attr&WideTail != 0 && t.cols >= 2 {
				step = 2
			}
			at += step
			col += step
		}
		r.ends = append(r.ends, at)
	}

	from := 0
	for k, to := range r.ends {
		var l *line
		if k < len(r.run) {
			l = r.run[k]
			l.version++
		} else {
			t.nextID++
			l = &line{id: t.nextID, at: r.run[0].at}
		}
		l.cells = append(l.cells[:0], r.cells[from:to]...)
		for x := range l.cells {
			// A wide character in a one-column terminal, or half of one, cannot
			// be shown; its cell is left blank.
			c := l.cells[x]
			if c.Attr&WideHead != 0 && (x+1 >= len(l.cells) || l.cells[x+1].Attr&WideTail == 0) ||
				c.Attr&WideTail != 0 && (x == 0 || l.cells[x-1].Attr&WideHead == 0) {
				l.cells[x] = Cell{BG: c.BG}
			}
		}
		l.used = len(l.cells)
		l.hyperlinks = nil
		if linked {
			links := append([]uint32(nil), r.links[from:to]...)
			l.hyperlinks = &links
		}
		l.marks = l.marks[:0]
		for _, m := range r.marks {
			if m.offset >= from && m.offset < to && len(l.marks) < maxMarks && l.cells[m.offset-from].R != 0 {
				l.marks = append(l.marks, Mark{Col: uint16(m.offset - from), R: m.r})
			}
		}
		l.wrapped = k < len(r.ends)-1
		for i := range anchors {
			if a := &anchors[i]; a.inRun && !a.moved && (a.offset < to || k == len(r.ends)-1) {
				a.index, a.col, a.moved = len(r.lines), min(max(a.offset-from, 0), t.cols-1), true
			}
		}
		r.lines = append(r.lines, l)
		from = to
	}
	if t.images != nil {
		for _, l := range r.run[min(len(r.ends), len(r.run)):] {
			t.images.dropLine(l.id)
		}
	}
	clear(r.run)
}

// refillHistory replaces the history with lines, oldest first, each stored
// without its trailing blanks. Lines beyond the history's capacity are dropped
// from the oldest end; the line count since the start follows the change.
func (t *Terminal) refillHistory(lines []*line) {
	oldCount := t.histCount
	if drop := len(lines) - t.histMax; drop > 0 {
		if t.images != nil {
			for _, l := range lines[:drop] {
				t.images.dropLine(l.id)
			}
		}
		lines = lines[drop:]
	}
	t.scrolled = t.scrolled - uint64(oldCount) + uint64(len(lines))
	if len(lines) > 0 && t.hist == nil {
		t.hist = make([]*line, t.histMax)
	}
	clear(t.hist)
	t.histHead, t.histCount, t.histBytes = 0, len(lines), 0
	for i, l := range lines {
		l.trimForHistory()
		t.hist[i] = l
		t.histBytes += lineHistoryBytes(l)
	}
	t.trimHistory()
	t.view = min(t.view, t.histCount)
}

// trimForHistory drops l's trailing empty cells, as history stores them.
func (l *line) trimForHistory() {
	used := len(l.cells)
	for used > 0 && l.cells[used-1] == (Cell{}) && l.hyperlinkAt(used-1) == 0 {
		used--
	}
	l.used = used
	if cap(l.cells) > 4*used+64 {
		l.cells = append([]Cell(nil), l.cells[:used]...)
	} else {
		l.cells = l.cells[:used]
	}
	if l.hyperlinks != nil {
		if used == 0 {
			l.hyperlinks = nil
		} else {
			links := append([]uint32(nil), (*l.hyperlinks)[:used]...)
			l.hyperlinks = &links
		}
	}
}

// contentWidth is how many leading cells of l hold anything worth keeping
// through a reflow: a character, an attribute or a link. A blank that only
// carries a background color is padding.
func (l *line) contentWidth() int {
	used := len(l.cells)
	for used > 0 {
		c := l.cells[used-1]
		if c.R != 0 || c.Attr != 0 || l.hyperlinkAt(used-1) != 0 {
			break
		}
		used--
	}
	return used
}
