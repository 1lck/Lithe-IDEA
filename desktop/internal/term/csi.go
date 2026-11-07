package term

import "strconv"

// escDispatch runs ESC <final>.
func (t *Terminal) escDispatch(b byte) {
	switch b {
	case '7':
		t.saveCursor()
	case '8':
		t.restoreCursor()
	case 'D':
		t.pend = false
		t.index()
	case 'E':
		t.pend = false
		t.cx = 0
		t.index()
	case 'H':
		t.tabs[t.cx] = true
	case 'M':
		t.pend = false
		t.reverseIndex()
	case 'c':
		t.Reset()
	case 'Z':
		t.answerDA1()
	case '=':
		t.modes.AppKeypad = true
	case '>':
		t.modes.AppKeypad = false
	case 'n':
		t.gl = 2
	case 'o':
		t.gl = 3
	}
}

// escDispatchInter runs ESC <intermediate> <final>.
func (t *Terminal) escDispatchInter(inter, b byte) {
	switch inter {
	case '(', ')', '*', '+':
		set := charsetASCII
		if b == '0' || b == '2' {
			set = charsetGraphics
		}
		t.charsets[inter-'('] = set
	case '#':
		if b == '8' { // DECALN: fill the screen with E
			t.top, t.bot = 0, t.rows-1
			t.cx, t.cy, t.pend = 0, 0, false
			for _, l := range t.scr.lines {
				cells := l.span(0, len(l.cells))
				for i := range cells {
					cells[i] = Cell{R: 'E'}
				}
				l.marks = l.marks[:0]
				l.hyperlinks = nil
				l.version++
			}
		}
	}
}

// arg is parameter i, or def when it is absent or was left empty.
func (t *Terminal) arg(i, def int) int {
	if i >= t.np || t.params[i] < 0 {
		return def
	}
	return int(t.params[i])
}

// num is a repeat count: absent, empty and 0 all mean 1.
func (t *Terminal) num(i int) int {
	if v := t.arg(i, 1); v > 0 {
		return v
	}
	return 1
}

func (t *Terminal) csiDispatch(final byte) {
	switch {
	case t.priv == 0 && t.ninter == 0:
		t.csiStandard(final)
	case t.priv == '?' && t.ninter == 0:
		t.csiPrivate(final)
	case t.priv == '>' && t.ninter == 0:
		switch final {
		case 'c':
			t.send(append(t.scratch[:0], "\x1b[>1;10;0c"...))
		case 'q':
			t.send(append(t.scratch[:0], "\x1bP>|motty\x1b\\"...))
		case 'u':
			t.kittyPush(uint32(t.arg(0, 0)))
		}
	case t.priv == '=' && t.ninter == 0:
		if final == 'u' {
			t.kittySet(uint32(t.arg(0, 0)), t.arg(1, 1))
		}
	case t.priv == '<' && t.ninter == 0:
		if final == 'u' {
			t.kittyPop(t.num(0))
		}
	case t.priv == 0 && t.ninter == 1:
		switch {
		case t.inter[0] == ' ' && final == 'q':
			t.setCursorStyle(t.arg(0, 0))
		case t.inter[0] == '!' && final == 'p':
			t.softReset()
		case t.inter[0] == '$' && final == 'p':
			t.answerModeQuery(t.arg(0, 0), false)
		}
	case t.priv == '?' && t.ninter == 1 && t.inter[0] == '$' && final == 'p':
		t.answerModeQuery(t.arg(0, 0), true)
	}
}

func (t *Terminal) csiStandard(final byte) {
	n := t.num(0)
	l := t.scr.lines[t.cy]
	switch final {
	case '@':
		t.insertCells(l, t.cx, n)
	case 'A', 'B':
		t.moveVertical(final, n)
	case 'e':
		t.pend = false
		t.cy = min(t.cy+n, t.rows-1)
	case 'C':
		t.pend = false
		t.cx = min(t.cx+n, t.cols-1)
	case 'D':
		t.pend = false
		t.cx = max(t.cx-n, 0)
	case 'E':
		t.moveVertical('B', n)
		t.cx = 0
	case 'F':
		t.moveVertical('A', n)
		t.cx = 0
	case 'G', '`':
		t.pend = false
		t.cx = min(n-1, t.cols-1)
	case 'a':
		t.pend = false
		t.cx = min(t.cx+n, t.cols-1)
	case 'H', 'f':
		t.moveTo(t.arg(0, 1), t.arg(1, 1))
	case 'd':
		t.moveTo(t.arg(0, 1), t.cx+1)
		t.pend = false
	case 'I':
		t.tabForward(n)
	case 'Z':
		t.tabBackward(n)
	case 'J':
		t.eraseDisplay(t.arg(0, 0))
	case 'K':
		t.eraseLine(t.arg(0, 0))
	case 'L':
		if t.cy >= t.top && t.cy <= t.bot {
			t.pend = false
			t.rotate(t.cy, t.bot, n, false, false)
		}
	case 'M':
		if t.cy >= t.top && t.cy <= t.bot {
			t.pend = false
			t.rotate(t.cy, t.bot, n, true, false)
		}
	case 'P':
		t.deleteCells(l, t.cx, n)
	case 'S':
		t.scrollUp(n)
	case 'T':
		if t.np <= 1 {
			t.scrollDown(n)
		}
	case 'X':
		t.eraseRange(l, t.cx, t.cx+n)
	case 'b':
		if t.lastRune != 0 {
			for i := 0; i < n; i++ {
				t.print(t.lastRune)
			}
		}
	case 'c':
		if t.arg(0, 0) == 0 {
			t.answerDA1()
		}
	case 'g':
		switch t.arg(0, 0) {
		case 0:
			t.tabs[t.cx] = false
		case 3:
			clear(t.tabs)
		}
	case 'h', 'l':
		t.setModes(final == 'h')
	case 'm':
		t.sgr()
	case 'n':
		t.deviceStatus(false)
	case 'r':
		t.setMargins()
	case 's':
		if t.np == 0 {
			t.saveCursor()
		}
	case 'u':
		if t.np == 0 {
			t.restoreCursor()
		}
	case 't':
		if t.arg(0, 0) == 18 {
			b := append(t.scratch[:0], "\x1b[8;"...)
			b = strconv.AppendInt(b, int64(t.rows), 10)
			b = append(b, ';')
			b = strconv.AppendInt(b, int64(t.cols), 10)
			b = append(b, 't')
			t.send(b)
		}
	}
}

// moveVertical moves the cursor like CUU ('A') or CUD ('B'): it stops at a
// margin the cursor starts inside of.
func (t *Terminal) moveVertical(direction byte, n int) {
	t.pend = false
	if direction == 'A' {
		limit := 0
		if t.cy >= t.top {
			limit = t.top
		}
		t.cy = max(t.cy-n, limit)
		return
	}
	limit := t.rows - 1
	if t.cy <= t.bot {
		limit = t.bot
	}
	t.cy = min(t.cy+n, limit)
}

func (t *Terminal) csiPrivate(final byte) {
	switch final {
	case 'h', 'l':
		t.setModes(final == 'h')
	case 'J':
		t.eraseDisplay(t.arg(0, 0)) // DECSED: no protected cells here
	case 'K':
		t.eraseLine(t.arg(0, 0))
	case 'n':
		t.deviceStatus(true)
	case 'u':
		t.answerKittyFlags()
	}
}

// moveTo is CUP: 1-based row and column, relative to the margins in origin mode.
func (t *Terminal) moveTo(row, col int) {
	row, col = max(row, 1), max(col, 1)
	t.pend = false
	if t.modes.Origin {
		t.cy = clampInt(t.top+row-1, t.top, t.bot)
	} else {
		t.cy = min(row-1, t.rows-1)
	}
	t.cx = min(col-1, t.cols-1)
}

func (t *Terminal) setMargins() {
	top, bottom := max(t.arg(0, 1), 1), t.arg(1, t.rows)
	if bottom == 0 || bottom > t.rows {
		bottom = t.rows
	}
	if top >= bottom {
		return
	}
	t.top, t.bot = top-1, bottom-1
	t.moveTo(1, 1)
}

func (t *Terminal) eraseDisplay(mode int) {
	lines := t.scr.lines
	switch mode {
	case 0:
		t.eraseRange(lines[t.cy], t.cx, t.cols)
		for y := t.cy + 1; y < t.rows; y++ {
			t.eraseLine2(lines[y])
		}
	case 1:
		for y := 0; y < t.cy; y++ {
			t.eraseLine2(lines[y])
		}
		t.eraseRange(lines[t.cy], 0, t.cx+1)
	case 2:
		for _, l := range lines {
			t.eraseLine2(l)
		}
	case 3:
		t.clearHistory()
		t.version++
	}
}

func (t *Terminal) eraseLine2(l *line) {
	t.eraseRange(l, 0, t.cols)
	l.wrapped = false
}

func (t *Terminal) eraseLine(mode int) {
	l := t.scr.lines[t.cy]
	switch mode {
	case 0:
		t.eraseRange(l, t.cx, t.cols)
	case 1:
		t.eraseRange(l, 0, t.cx+1)
	case 2:
		t.eraseLine2(l)
	}
}

// insertCells shifts the cells from x right by n, blanking the gap.
func (t *Terminal) insertCells(l *line, x, n int) {
	n = min(n, t.cols-x)
	if n <= 0 {
		return
	}
	if t.images != nil {
		t.images.insert(l.id, x, n, t.cols)
	}
	// The shift carries the row's text to the right, so it can now reach the
	// last column.
	l.touch(t.cols)
	copy(l.cells[x+n:], l.cells[x:t.cols-n])
	if l.hyperlinks != nil {
		links := *l.hyperlinks
		copy(links[x+n:], links[x:t.cols-n])
		clear(links[x : x+n])
	}
	l.fill(x, x+n, t.blankCell())
	if len(l.marks) > 0 {
		kept := l.marks[:0]
		for _, m := range l.marks {
			if int(m.Col) >= x {
				m.Col += uint16(n)
				if int(m.Col) >= t.cols {
					continue
				}
			}
			kept = append(kept, m)
		}
		l.marks = kept
	}
	t.repairWide(l, x-1)
	t.repairWide(l, x+n)
	t.repairWide(l, t.cols-1)
	l.version++
}

// deleteCells removes n cells at x, pulling the rest of the line left.
func (t *Terminal) deleteCells(l *line, x, n int) {
	n = min(n, t.cols-x)
	if n <= 0 {
		return
	}
	if t.images != nil {
		t.images.deleteCells(l.id, x, n)
	}
	copy(l.cells[x:], l.cells[x+n:])
	if l.hyperlinks != nil {
		links := *l.hyperlinks
		copy(links[x:], links[x+n:])
		clear(links[t.cols-n:])
	}
	l.fill(t.cols-n, t.cols, t.blankCell())
	if len(l.marks) > 0 {
		kept := l.marks[:0]
		for _, m := range l.marks {
			switch {
			case int(m.Col) >= x+n:
				m.Col -= uint16(n)
			case int(m.Col) >= x:
				continue
			}
			kept = append(kept, m)
		}
		l.marks = kept
	}
	t.repairWide(l, x-1)
	t.repairWide(l, x)
	l.version++
}

func (t *Terminal) saveCursor() {
	t.scr.saved = savedCursor{
		valid: true, x: t.cx, y: t.cy, pend: t.pend, pen: t.pen,
		origin: t.modes.Origin, charsets: t.charsets, gl: t.gl,
	}
}

func (t *Terminal) restoreCursor() {
	s := t.scr.saved
	if !s.valid {
		t.cx, t.cy, t.pend = 0, 0, false
		t.pen, t.modes.Origin = pen{}, false
		t.charsets, t.gl = [4]charset{}, 0
		return
	}
	t.cx, t.cy = min(s.x, t.cols-1), min(s.y, t.rows-1)
	t.pend, t.pen, t.modes.Origin = s.pend, s.pen, s.origin
	t.charsets, t.gl = s.charsets, s.gl
}

func (t *Terminal) enterAlt(clearScreen bool) {
	if t.onAlt {
		return
	}
	t.onAlt, t.scr, t.modes.AltScreen = true, &t.alt, true
	t.inputStartSet = false
	t.view = 0
	if clearScreen {
		if t.images != nil {
			for _, line := range t.alt.lines {
				t.images.dropLine(line.id)
			}
		}
		for i, l := range t.alt.lines {
			t.alt.lines[i] = t.recycle(l)
		}
	}
	t.top, t.bot = 0, t.rows-1
	t.pend = false
	t.version++
}

func (t *Terminal) leaveAlt(clearScreen bool) {
	if !t.onAlt {
		return
	}
	if clearScreen {
		if t.images != nil {
			for _, line := range t.alt.lines {
				t.images.dropLine(line.id)
			}
		}
		for i, l := range t.alt.lines {
			t.alt.lines[i] = t.recycle(l)
		}
	}
	t.onAlt, t.scr, t.modes.AltScreen = false, &t.main, false
	t.top, t.bot = 0, t.rows-1
	t.pend = false
	t.version++
}

func (t *Terminal) softReset() {
	t.modes.Insert, t.modes.Origin, t.modes.AppCursorKeys, t.modes.AppKeypad = false, false, false, false
	t.modes.CursorVisible = true
	t.top, t.bot = 0, t.rows-1
	t.pen = pen{}
	t.charsets, t.gl = [4]charset{}, 0
	t.cursor, t.cursorSteady = t.defaultCursor, false
	t.cursorStyled = false
	t.scr.saved = savedCursor{}
}

func (t *Terminal) setCursorStyle(n int) {
	t.cursorSteady = n == 2 || n == 4 || n == 6
	t.cursorStyled = true
	switch n {
	case 3, 4:
		t.cursor = CursorUnderline
	case 5, 6:
		t.cursor = CursorBar
	default:
		t.cursor = CursorBlock
	}
}

func (t *Terminal) setModes(set bool) {
	for i := 0; i < t.np; i++ {
		mode := int(t.params[i])
		if t.priv == '?' {
			t.setPrivateMode(mode, set)
		} else {
			switch mode {
			case 4:
				t.modes.Insert = set
			case 20:
				t.modes.Newline = set
			}
		}
	}
}

func (t *Terminal) setPrivateMode(mode int, set bool) {
	m := &t.modes
	switch mode {
	case 1:
		m.AppCursorKeys = set
	case 5:
		m.ReverseVideo = set
	case 6:
		m.Origin = set
		t.moveTo(1, 1)
	case 7:
		m.Autowrap = set
		if !set {
			t.pend = false
		}
	case 25:
		m.CursorVisible = set
	case 47:
		if set {
			t.enterAlt(false)
		} else {
			t.leaveAlt(false)
		}
	case 1047:
		if set {
			t.enterAlt(false)
		} else {
			t.leaveAlt(true)
		}
	case 1048:
		if set {
			t.saveCursor()
		} else {
			t.restoreCursor()
		}
	case 1049:
		if set {
			if !t.onAlt {
				t.saveCursor()
			}
			t.enterAlt(true)
		} else if t.onAlt {
			t.leaveAlt(false)
			t.restoreCursor()
		}
	case 9, 1000, 1002, 1003:
		level := MouseX10
		switch mode {
		case 1000:
			level = MouseButton
		case 1002:
			level = MouseDrag
		case 1003:
			level = MouseAny
		}
		if set {
			m.Mouse = level
		} else if m.Mouse == level {
			m.Mouse = MouseOff
		}
	case 1004:
		m.FocusReporting = set
	case 1005, 1006, 1015:
		encoding := MouseEncodingUTF8
		switch mode {
		case 1006:
			encoding = MouseEncodingSGR
		case 1015:
			encoding = MouseEncodingURXVT
		}
		if set {
			m.MouseEncoding = encoding
		} else if m.MouseEncoding == encoding {
			m.MouseEncoding = MouseEncodingX10
		}
	case 1007:
		m.AlternateScroll = set
	case 2004:
		m.BracketedPaste = set
	case 2026:
		t.setSync(set)
	case 9001:
		if win32InputSupported {
			m.Win32Input = set
		}
	}
}

// modeState is the DECRQM status of a mode: 0 unknown, 1 set, 2 reset.
func (t *Terminal) modeState(mode int, private bool) int {
	known, on := true, false
	m := t.modes
	if !private {
		switch mode {
		case 4:
			on = m.Insert
		case 20:
			on = m.Newline
		default:
			known = false
		}
	} else {
		switch mode {
		case 1:
			on = m.AppCursorKeys
		case 5:
			on = m.ReverseVideo
		case 6:
			on = m.Origin
		case 7:
			on = m.Autowrap
		case 25:
			on = m.CursorVisible
		case 47, 1047, 1049:
			on = m.AltScreen
		case 1000:
			on = m.Mouse == MouseButton
		case 1002:
			on = m.Mouse == MouseDrag
		case 1003:
			on = m.Mouse == MouseAny
		case 1004:
			on = m.FocusReporting
		case 1006:
			on = m.MouseEncoding == MouseEncodingSGR
		case 1007:
			on = m.AlternateScroll
		case 2004:
			on = m.BracketedPaste
		case 2026:
			on = m.Sync
		case 9001:
			if win32InputSupported {
				on = m.Win32Input
			} else {
				known = false
			}
		default:
			known = false
		}
	}
	switch {
	case !known:
		return 0
	case on:
		return 1
	}
	return 2
}

func (t *Terminal) answerModeQuery(mode int, private bool) {
	b := append(t.scratch[:0], "\x1b["...)
	if private {
		b = append(b, '?')
	}
	b = strconv.AppendInt(b, int64(mode), 10)
	b = append(b, ';')
	b = strconv.AppendInt(b, int64(t.modeState(mode, private)), 10)
	b = append(b, "$y"...)
	t.send(b)
}

func (t *Terminal) answerDA1() { t.send(append(t.scratch[:0], "\x1b[?62;22c"...)) }

func (t *Terminal) deviceStatus(private bool) {
	switch t.arg(0, 0) {
	case 5:
		if !private {
			t.send(append(t.scratch[:0], "\x1b[0n"...))
		}
	case 6:
		row := t.cy + 1
		if t.modes.Origin {
			row = t.cy - t.top + 1
		}
		b := append(t.scratch[:0], "\x1b["...)
		if private {
			b = append(b, '?')
		}
		b = strconv.AppendInt(b, int64(row), 10)
		b = append(b, ';')
		b = strconv.AppendInt(b, int64(t.cx+1), 10)
		b = append(b, 'R')
		t.send(b)
	}
}

// sgr applies Select Graphic Rendition.
func (t *Terminal) sgr() {
	if t.np == 0 {
		t.pen = pen{}
		return
	}
	p := &t.pen
	for i := 0; i < t.np; i++ {
		v := int(max(t.params[i], 0))
		switch {
		case v == 0:
			*p = pen{}
		case v == 1:
			p.attr |= Bold
		case v == 2:
			p.attr |= Dim
		case v == 3:
			p.attr |= Italic
		case v == 4:
			p.attr |= Underline
			if i+1 < t.np && t.colon[i+1] { // 4:n selects a style; 4:0 is none
				if t.params[i+1] == 0 {
					p.attr &^= Underline
				}
				for i+1 < t.np && t.colon[i+1] {
					i++
				}
			}
		case v == 5 || v == 6:
			p.attr |= Blink
		case v == 7:
			p.attr |= Inverse
		case v == 8:
			p.attr |= Hidden
		case v == 9:
			p.attr |= Strike
		case v == 21:
			p.attr |= Underline
		case v == 22:
			p.attr &^= Bold | Dim
		case v == 23:
			p.attr &^= Italic
		case v == 24:
			p.attr &^= Underline
		case v == 25:
			p.attr &^= Blink
		case v == 27:
			p.attr &^= Inverse
		case v == 28:
			p.attr &^= Hidden
		case v == 29:
			p.attr &^= Strike
		case v >= 30 && v <= 37:
			p.fg = Indexed(uint8(v - 30))
		case v == 38:
			i = t.extendedColor(i, &p.fg)
		case v == 39:
			p.fg = 0
		case v >= 40 && v <= 47:
			p.bg = Indexed(uint8(v - 40))
		case v == 48:
			i = t.extendedColor(i, &p.bg)
		case v == 49:
			p.bg = 0
		case v == 58:
			i = t.extendedColor(i, nil)
		case v >= 90 && v <= 97:
			p.fg = Indexed(uint8(v - 90 + 8))
		case v >= 100 && v <= 107:
			p.bg = Indexed(uint8(v - 100 + 8))
		}
	}
}

func clamp8(v int32) uint8 { return uint8(clampInt(int(v), 0, 255)) }

// extendedColor reads the color that follows an SGR 38, 48 or 58 at index i,
// in either the semicolon (38;5;n, 38;2;r;g;b) or colon (38:5:n, 38:2::r:g:b)
// form, stores it in dst unless dst is nil, and returns the index of the last
// parameter it consumed.
func (t *Terminal) extendedColor(i int, dst *Color) int {
	if i+1 < t.np && t.colon[i+1] {
		j := i + 1
		for j < t.np && t.colon[j] {
			j++
		}
		sub := t.params[i+1 : j]
		if dst != nil && len(sub) > 0 {
			switch sub[0] {
			case 5:
				if len(sub) >= 2 {
					*dst = Indexed(clamp8(sub[1]))
				}
			case 2:
				rgb := sub[1:]
				if len(rgb) >= 4 { // a color-space id precedes the components
					rgb = rgb[1:]
				}
				if len(rgb) >= 3 {
					*dst = RGB(clamp8(rgb[0]), clamp8(rgb[1]), clamp8(rgb[2]))
				}
			}
		}
		return j - 1
	}
	if i+1 >= t.np {
		return i
	}
	switch t.params[i+1] {
	case 5:
		if i+2 < t.np {
			if dst != nil {
				*dst = Indexed(clamp8(t.params[i+2]))
			}
			return i + 2
		}
		return t.np - 1
	case 2:
		if i+4 < t.np {
			if dst != nil {
				*dst = RGB(clamp8(t.params[i+2]), clamp8(t.params[i+3]), clamp8(t.params[i+4]))
			}
			return i + 4
		}
		return t.np - 1
	}
	return i + 1
}
