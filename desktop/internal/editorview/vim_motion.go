package editorview

import (
	"strings"
	"unicode"
)

// vim_motion.go is where the Vim motions take the caret. A motion is a key and a count; it gives
// the offset it takes the caret to, and whether an operator's range includes that character and
// reads whole lines. See vimMotionOf.

// vimMotionOf is the motion the key s makes from the caret, count times (n is the count typed, zero
// for none). op says an operator waits for the motion, which changes how cw and dw read it. The
// second result is false when the motion cannot be made.
func (v *View) vimMotionOf(s string, n int, op bool) (vimMove, bool) {
	c := v.caret
	line := v.text.LineOf(c)
	last := v.text.LineCount() - 1
	count := max(n, 1)
	big := s == "W" || s == "B" || s == "E"
	switch s {
	case "h", vimBackspace:
		to := c
		for i := 0; i < count && to > v.text.LineStart(line); i++ {
			to = v.prevRune(to)
		}
		return vimMove{to: to}, true
	case "l", " ":
		limit := v.vimLastChar(line)
		if op {
			limit = v.lineEnd(line)
		}
		to := c
		for i := 0; i < count && to < limit; i++ {
			to = v.nextRune(to)
		}
		return vimMove{to: to}, true
	case "j", "k", vimCtrlF, vimCtrlB:
		delta := count
		if s == "k" || s == vimCtrlB {
			delta = -delta
		}
		if s == vimCtrlF || s == vimCtrlB {
			delta *= v.vimPageRows()
		}
		return v.vimLineMove(line, line+delta, false, op)
	case "+", vimEnter:
		return v.vimLineMove(line, line+count, true, op)
	case "-":
		return v.vimLineMove(line, line-count, true, op)
	case "0":
		return vimMove{to: v.text.LineStart(line)}, true
	case "^":
		return vimMove{to: v.vimFirstNB(line)}, true
	case "$":
		end := min(line+count-1, last)
		return vimMove{to: v.lineEnd(end)}, true
	case "G":
		target := last
		if n > 0 {
			target = min(n-1, last)
		}
		return vimMove{to: v.vimFirstNB(target), line: true}, true
	case "gg":
		target := 0
		if n > 0 {
			target = min(n-1, last)
		}
		return vimMove{to: v.vimFirstNB(target), line: true}, true
	case "w", "W":
		if op && v.vim.op == 'c' && v.vimClass(c, big) >= 2 {
			// cw changes to the end of the word, as ce does, and a word's last character alone.
			cls := v.vimClass(c, big)
			to := c
			if v.vimClass(v.nextRune(c), big) == cls {
				to = v.vimWordEnd(c, big)
			}
			for i := 1; i < count; i++ {
				to = v.vimWordEnd(to, big)
			}
			return vimMove{to: to, incl: true}, true
		}
		to := c
		for i := 0; i < count; i++ {
			to = v.vimWordForward(to, big)
		}
		if op && v.text.LineOf(to) > line {
			// dw at the end of a line stops at the line's end rather than taking its break.
			to = v.lineEnd(line)
		}
		return vimMove{to: to}, true
	case "e", "E":
		to := c
		for i := 0; i < count; i++ {
			to = v.vimWordEnd(to, big)
		}
		return vimMove{to: to, incl: true}, true
	case "b", "B":
		to := c
		for i := 0; i < count; i++ {
			to = v.vimWordBack(to, big)
		}
		return vimMove{to: to}, true
	case "%":
		to, ok := v.vimMatchBracket(c)
		return vimMove{to: to, incl: true}, ok
	case ";", ",":
		return vimMove{}, false
	}
	return vimMove{}, false
}

// vimLineMove is the motion to line target from line: the caret keeps its column, or goes to the
// first character of the line with firstNB. A motion past the first or last line stops there, and
// one that cannot move at all fails.
func (v *View) vimLineMove(line, target int, firstNB, op bool) (vimMove, bool) {
	t := min(max(target, 0), v.text.LineCount()-1)
	if t == line {
		return vimMove{}, false
	}
	if firstNB {
		return vimMove{to: v.vimFirstNB(t), line: true}, true
	}
	if v.goal < 0 {
		v.goal = cellsOf(v.text.Line(line), v.caret-v.text.LineStart(line))
	}
	to := v.text.LineStart(t) + columnAt(v.text.Line(t), float32(v.goal))
	return vimMove{to: to, line: true, vertical: true}, true
}

// vimClass sorts the character at offset for the word motions: 0 for a line break, 1 for a space,
// 2 for a word character and 3 for other punctuation. With big (a WORD) every other character is
// one class, so a WORD runs over punctuation.
func (v *View) vimClass(at int, big bool) int {
	if at >= v.text.Len() {
		return 0
	}
	r := v.runeAt(at)
	switch {
	case r == '\n' || r == '\r':
		return 0
	case r == ' ' || r == '\t' || unicode.IsSpace(r):
		return 1
	case big:
		return 2
	}
	return charClass(r)
}

// vimWordForward is the start of the next word after at. An empty line is a word of its own.
func (v *View) vimWordForward(at int, big bool) int {
	n := v.text.Len()
	if cls := v.vimClass(at, big); cls >= 2 {
		for at < n && v.vimClass(at, big) == cls {
			at = v.nextRune(at)
		}
	}
	for at < n {
		switch v.vimClass(at, big) {
		case 0:
			at = v.nextRune(at)
			if at < n && v.vimClass(at, big) == 0 {
				return at
			}
			continue
		case 1:
			at = v.nextRune(at)
			continue
		}
		break
	}
	return at
}

// vimWordEnd is the last character of the word after at.
func (v *View) vimWordEnd(at int, big bool) int {
	n := v.text.Len()
	at = v.nextRune(at)
	for at < n && v.vimClass(at, big) <= 1 {
		at = v.nextRune(at)
	}
	if at >= n {
		if n == 0 {
			return 0
		}
		return v.prevRune(n)
	}
	cls := v.vimClass(at, big)
	for {
		next := v.nextRune(at)
		if next >= n || v.vimClass(next, big) != cls {
			return at
		}
		at = next
	}
}

// vimWordBack is the start of the word before at. An empty line is a word of its own.
func (v *View) vimWordBack(at int, big bool) int {
	if at <= 0 {
		return 0
	}
	at = v.prevRune(at)
	for at > 0 && v.vimClass(at, big) <= 1 {
		if v.vimClass(at, big) == 0 && at == v.text.LineStart(v.text.LineOf(at)) {
			return at
		}
		at = v.prevRune(at)
	}
	cls := v.vimClass(at, big)
	for at > 0 && v.vimClass(v.prevRune(at), big) == cls {
		at = v.prevRune(at)
	}
	return at
}

// vimFindChar is the offset of the count-th ch in the caret's line, searching forward for f and t
// and back for F and T. The second result is false when there is no such character.
func (v *View) vimFindChar(kind byte, ch string, count int) (int, bool) {
	r := []rune(ch)[0]
	line := v.text.LineOf(v.caret)
	start, end := v.text.LineStart(line), v.lineEnd(line)
	at := v.caret
	for i := 0; i < count; i++ {
		found := false
		if kind == 'f' || kind == 't' {
			for p := v.nextRune(at); p < end; p = v.nextRune(p) {
				if v.runeAt(p) == r {
					at, found = p, true
					break
				}
			}
		} else {
			for p := at; p > start; {
				p = v.prevRune(p)
				if v.runeAt(p) == r {
					at, found = p, true
					break
				}
			}
		}
		if !found {
			return 0, false
		}
	}
	return at, true
}

// vimMatchBracket is the bracket that pairs with the first bracket at or after c on its line. The
// second result is false when the line has no bracket after the caret or the pair is not closed.
func (v *View) vimMatchBracket(c int) (int, bool) {
	const brackets = "()[]{}"
	line := v.text.LineOf(c)
	end := v.lineEnd(line)
	at := c
	for at < end && !strings.ContainsRune(brackets, v.runeAt(at)) {
		at = v.nextRune(at)
	}
	if at >= end {
		return 0, false
	}
	r := v.runeAt(at)
	var match rune
	forward := true
	if i := strings.IndexRune("([{", r); i >= 0 {
		match = []rune(")]}")[i]
	} else {
		forward = false
		match = []rune("([{")[strings.IndexRune(")]}", r)]
	}
	depth := 0
	n := v.text.Len()
	p := at
	for {
		ch := v.runeAt(p)
		switch ch {
		case r:
			depth++
		case match:
			depth--
			if depth == 0 {
				return p, true
			}
		}
		if forward {
			next := v.nextRune(p)
			if next >= n {
				return 0, false
			}
			p = next
		} else {
			if p == 0 {
				return 0, false
			}
			p = v.prevRune(p)
		}
	}
}
