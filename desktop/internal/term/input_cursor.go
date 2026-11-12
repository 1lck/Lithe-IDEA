package term

// Moving the shell's cursor to a clicked cell. A terminal has no way to place
// another program's cursor, so the owner sends cursor keys, and the shell's own
// line editor decides what they do. That is only sound while the cursor is on
// the line being edited, which the shell's OSC 133 markers delimit: B, the end
// of the prompt, is where the input starts, and A, C and D end it.

// maxInputMove bounds the cursor keys one click may ask for, so a line pasted
// from a huge buffer cannot turn a click into a flood.
const maxInputMove = 4096

// markInputStart records the cursor at OSC 133 B as the start of the input. Only
// the owning shell's marker counts: a program that echoes the sequence must not
// be taken for a prompt. A cursor with a pending wrap has no settled position
// yet, so it records nothing.
func (t *Terminal) markInputStart(own bool) {
	t.inputStartSet = false
	if !own || t.onAlt || t.pend {
		return
	}
	t.inputStart = Point{Line: t.scrolled + uint64(t.cy) + 1, Column: t.cx}
	t.inputStartSet = true
}

// InputMove is the number of characters the shell's editing cursor has to move
// to stand on the cell at position: negative to the left, zero when it already
// is there. ok is false whenever the move cannot be derived from the screen:
// the shell is not at a prompt it reported, the cell is outside the input, or
// the input is not one soft-wrapped logical line. A cell past the end of the
// text counts as the end of the text, so the move never asks the shell for
// more than it has.
//
// Characters are counted, not cells, because that is what cursor keys step
// over: the second cell of a wide character is skipped.
func (t *Terminal) InputMove(position Position) (moves int, ok bool) {
	if !t.inputStartSet || t.onAlt || t.pend ||
		position.Row < 0 || position.Row >= t.rows || position.Column < 0 || position.Column >= t.cols {
		return 0, false
	}
	base, count := t.lineBase(), uint64(t.bufferLineCount())
	target := t.PointAt(position)
	cursor := Point{Line: t.scrolled + uint64(t.cy) + 1, Column: t.cx}
	start := t.inputStart
	last := max(target.Line, cursor.Line)
	if pointLess(target, start) || pointLess(cursor, start) || start.Line < base || last-base >= count {
		return 0, false
	}
	for line := start.Line; line < last; line++ {
		if !t.bufferLine(int(line - base)).wrapped {
			return 0, false
		}
	}
	// The input ends on the last row of its soft-wrapped run, at the end of what
	// is written there; a click further right means the end.
	if target.Line == last {
		limit := t.bufferLine(int(last - base)).contentWidth()
		if cursor.Line == last {
			limit = max(limit, cursor.Column)
		}
		target.Column = min(target.Column, limit)
	}
	if row := t.bufferLine(int(target.Line - base)); target.Column < len(row.cells) &&
		row.cells[target.Column].Attr&WideTail != 0 && target.Column > 0 {
		target.Column--
	}
	if pointLess(target, start) {
		return 0, false
	}
	sign, from, to := 1, cursor, target
	if pointLess(target, cursor) {
		sign, from, to = -1, target, cursor
	}
	moves = t.charactersBetween(from, to, base)
	if moves > maxInputMove {
		return 0, false
	}
	return sign * moves, true
}

// charactersBetween counts the characters from one buffer point up to, not
// including, a later one. Cells a row never wrote are empty characters.
func (t *Terminal) charactersBetween(from, to Point, base uint64) int {
	total := 0
	for line := from.Line; line <= to.Line; line++ {
		first, stop := 0, t.cols
		if line == from.Line {
			first = from.Column
		}
		if line == to.Line {
			stop = to.Column
		}
		cells := t.bufferLine(int(line - base)).cells
		for column := first; column < stop; column++ {
			if column >= len(cells) || cells[column].Attr&WideTail == 0 {
				total++
			}
		}
	}
	return total
}
