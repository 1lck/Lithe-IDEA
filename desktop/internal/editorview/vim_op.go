package editorview

import (
	"strings"
	"unicode/utf8"
)

// vim_op.go is the Vim operators (d, c, y, > and <) and the commands built on them: the text
// objects an operator takes (iw, aw, i", a(, ...), the line edits (J, o, O, r) and the pastes. Every
// change of text goes through edit, so one command is one undo step (see vim.go).

// vimOperateMotion applies the operator op to the range of motion m from the caret.
func (v *View) vimOperateMotion(op byte, m vimMove) {
	from, to := min(v.caret, m.to), max(v.caret, m.to)
	if m.line {
		v.vimOperate(op, from, to, true)
		return
	}
	if m.incl {
		to = v.nextRune(to)
	}
	v.vimOperate(op, from, to, false)
}

// vimOperate applies op to the range from..to, a byte range of the text ending before to. A
// linewise range is the whole lines from the line of from to the line of to.
func (v *View) vimOperate(op byte, from, to int, linewise bool) {
	st := &v.vim
	first := v.text.LineOf(from)
	var delFrom, delTo int
	var text string
	if linewise {
		last := v.text.LineOf(to)
		delFrom, delTo, text = v.vimLines(first, last)
	} else {
		delFrom, delTo = from, to
		text = string(v.text.AppendRange(nil, from, to))
	}
	switch op {
	case 'y':
		v.vimSetReg(op, text, linewise)
		if linewise {
			// Yanking upward moves the caret to the first line yanked; otherwise it stays.
			if v.text.LineOf(v.caret) != first {
				v.moveTo(v.vimFirstNB(first), false)
			}
		} else {
			v.moveTo(from, false)
		}
	case 'd':
		v.vimSetReg(op, text, linewise)
		st.changed = true
		v.edit(delFrom, delTo, "", editOther)
		if linewise {
			v.moveTo(v.vimFirstNB(v.text.LineOf(delFrom)), false)
		} else {
			v.moveTo(delFrom, false)
		}
		v.vimClamp()
	case 'c':
		v.vimSetReg(op, text, linewise)
		if linewise {
			// cc keeps the indentation of the first line, as an editor that indents does.
			start := v.vimFirstNB(first)
			v.edit(start, v.lineEnd(v.text.LineOf(to)), "", editOther)
			v.vimEnterInsert(vimInsert, start)
		} else {
			v.edit(from, to, "", editOther)
			v.vimEnterInsert(vimInsert, from)
		}
	case '>', '<':
		st.changed = true
		v.vimShift(op, first, v.text.LineOf(to))
	}
}

// vimLines is the lines first..last as an operator takes them: the range of text that deletes
// them, and their text for the register, without the line break after the last one. The last
// line of the text takes the line break before it instead, so no empty line is left behind.
func (v *View) vimLines(first, last int) (int, int, string) {
	text := string(v.text.AppendRange(nil, v.text.LineStart(first), v.lineEnd(last)))
	from, to := v.text.LineStart(first), v.text.Len()
	switch {
	case last+1 < v.text.LineCount():
		to = v.text.LineStart(last + 1)
	case first > 0:
		from, to = v.lineEnd(first-1), v.lineEnd(last)
	}
	return from, to, text
}

// vimShift indents (op '>') or outdents (op '<') the lines first..last by one indent unit.
func (v *View) vimShift(op byte, first, last int) {
	from, to := v.text.LineStart(first), v.lineEnd(last)
	lines := strings.Split(string(v.text.AppendRange(nil, from, to)), "\n")
	for i, l := range lines {
		if op == '>' {
			if strings.TrimSpace(l) != "" {
				lines[i] = v.indentUnit + l
			}
			continue
		}
		switch {
		case strings.HasPrefix(l, "\t"):
			lines[i] = l[1:]
		default:
			n := 0
			for n < len(l) && n < tabSize && l[n] == ' ' {
				n++
			}
			lines[i] = l[n:]
		}
	}
	v.edit(from, to, strings.Join(lines, "\n"), editOther)
	v.moveTo(v.vimFirstNB(first), false)
	v.vimClamp()
}

// vimOpMotion is the operator op over the motion (see vimMotionOf) from the caret, for x, D, C and
// the like, which name their operator and motion themselves.
func (v *View) vimOpMotion(op byte, motion string) {
	if m, ok := v.vimMotionOf(motion, v.vimRawCount(), true); ok {
		v.vimOperateMotion(op, m)
	}
	v.vimCancel()
}

// vimLinesOp is the operator over the count lines from the caret's line: dd, cc, yy, >> and <<, and
// S and Y.
func (v *View) vimLinesOp(op byte) {
	line := v.text.LineOf(v.caret)
	last := min(line+max(v.vimRawCount(), 1)-1, v.text.LineCount()-1)
	v.vimOperate(op, v.text.LineStart(line), v.text.LineStart(last), true)
	v.vimCancel()
}

// vimVisualOp applies op to the selection, which ends Visual mode.
func (v *View) vimVisualOp(op byte) {
	st := &v.vim
	linewise := st.mode == vimVisualLine
	from, to := v.Selection()
	if linewise && to > from {
		// The selection of whole lines ends at the start of the next line; the operator reads the
		// line break that ends the last one.
		to = v.prevRune(to)
	}
	st.mode = vimNormal
	v.vimOperate(op, from, to, linewise)
	v.vimClamp()
}

// vimVisualPaste replaces the selection with the register the command names. The text replaced
// goes to the unnamed register, as in Vim; the named register is left as it was.
func (v *View) vimVisualPaste() {
	st := &v.vim
	text, line := v.vimReadReg(st.regName)
	v.vimVisualPasteText(text, line)
}

// vimVisualPasteText replaces the selection with text (line for whole lines).
func (v *View) vimVisualPasteText(text string, line bool) {
	st := &v.vim
	if text == "" {
		return
	}
	name := st.regName
	st.regName = 0
	v.vimVisualOp('d')
	st.regName = name
	v.vimPasteText(text, line, false)
}

// vimPaste puts the register the command names after the caret (p) or before it (P). Lines paste as
// whole lines below or above the caret's line.
func (v *View) vimPaste(after bool) {
	text, line := v.vimReadReg(v.vim.regName)
	v.vimPasteText(text, line, after)
}

// vimPasteText puts text after the caret or before it. Lines paste as whole lines.
func (v *View) vimPasteText(text string, line, after bool) {
	if text == "" {
		return
	}
	v.vim.changed = true
	lineNo := v.text.LineOf(v.caret)
	if line {
		if after {
			at := v.lineEnd(lineNo)
			v.edit(at, at, "\n"+text, editOther)
			v.moveTo(v.vimFirstNB(lineNo+1), false)
		} else {
			at := v.text.LineStart(lineNo)
			v.edit(at, at, text+"\n", editOther)
			v.moveTo(v.vimFirstNB(lineNo), false)
		}
		v.vimClamp()
		return
	}
	at := v.caret
	if after && at < v.lineEnd(lineNo) {
		at = v.nextRune(at)
	}
	v.edit(at, at, text, editOther)
	v.moveTo(v.prevRune(at+len(text)), false)
	v.vimClamp()
}

// vimReplaceChars replaces the count characters from the caret with s (r). It fails when the line
// has fewer characters from the caret than that.
func (v *View) vimReplaceChars(s string) {
	n := max(v.vimRawCount(), 1)
	line := v.text.LineOf(v.caret)
	end := v.lineEnd(line)
	to := v.caret
	for i := 0; i < n; i++ {
		if to >= end {
			return
		}
		to = v.nextRune(to)
	}
	v.vim.changed = true
	v.edit(v.caret, to, strings.Repeat(s, n), editOther)
	v.moveTo(v.prevRune(v.caret), false)
	v.vimClamp()
}

// vimJoin joins the caret's line with the lines after it (J): count lines, and two when none is
// typed. A space separates the lines, unless the next one starts with a closing bracket or is
// empty, or the line before ends in a space.
func (v *View) vimJoin(count int) {
	st := &v.vim
	line := v.text.LineOf(v.caret)
	last := min(line+max(count, 2)-1, v.text.LineCount()-1)
	if last == line {
		return
	}
	var b strings.Builder
	b.WriteString(v.vimLineText(line))
	at := -1
	for l := line + 1; l <= last; l++ {
		next := strings.TrimLeft(v.vimLineText(l), " \t")
		sep := " "
		cur := b.String()
		if next == "" || strings.HasPrefix(next, ")") || strings.HasSuffix(cur, " ") || strings.HasSuffix(cur, "\t") {
			sep = ""
		}
		if at < 0 {
			at = b.Len()
		}
		b.WriteString(sep)
		b.WriteString(next)
	}
	st.changed = true
	from := v.text.LineStart(line)
	v.edit(from, v.lineEnd(last), b.String(), editOther)
	v.moveTo(from+at, false)
	v.vimClamp()
}

// vimLineText is the text of line, without its line break.
func (v *View) vimLineText(line int) string {
	return string(v.text.AppendRange(nil, v.text.LineStart(line), v.lineEnd(line)))
}

// vimOpenLine opens a line below the caret's line (o) or above it (O), indented as that line is,
// and starts Insert mode on it.
func (v *View) vimOpenLine(below bool) {
	line := v.text.LineOf(v.caret)
	indent := v.leadingSpace(line)
	if below {
		at := v.lineEnd(line)
		v.edit(at, at, "\n"+indent, editOther)
		v.vimEnterInsert(vimInsert, at+1+len(indent))
		return
	}
	at := v.text.LineStart(line)
	v.edit(at, at, indent+"\n", editOther)
	v.vimEnterInsert(vimInsert, at+len(indent))
}

// vimObject is the range of the text object key names (w, ", (, {, ...), inner or around. The
// second result is false when the caret is not in one.
func (v *View) vimObject(inner bool, key string) (int, int, bool) {
	switch key {
	case "w":
		return v.vimWordObject(inner, false)
	case "W":
		return v.vimWordObject(inner, true)
	case "\"", "'", "`":
		r, _ := utf8.DecodeRuneInString(key)
		return v.vimQuoteObject(r, inner)
	case "(", ")", "b":
		return v.vimBlockObject('(', ')', inner)
	case "[", "]":
		return v.vimBlockObject('[', ']', inner)
	case "{", "}", "B":
		return v.vimBlockObject('{', '}', inner)
	}
	return 0, 0, false
}

// vimWordObject is the word under the caret (iw, or iW for a WORD). Around it (aw) it takes the
// spaces after the word, or before it when no spaces follow.
func (v *View) vimWordObject(inner, big bool) (int, int, bool) {
	if v.text.Len() == 0 {
		return 0, 0, false
	}
	c := v.caret
	line := v.text.LineOf(c)
	ls, le := v.text.LineStart(line), v.lineEnd(line)
	cls := v.vimClass(c, big)
	if cls == 0 || c >= le {
		return 0, 0, false
	}
	start, end := c, v.nextRune(c)
	for start > ls && v.vimClass(v.prevRune(start), big) == cls {
		start = v.prevRune(start)
	}
	for end < le && v.vimClass(end, big) == cls {
		end = v.nextRune(end)
	}
	if inner {
		return start, end, true
	}
	if cls == 1 {
		// Around spaces: the spaces and the word after them.
		if end < le {
			next := v.vimClass(end, big)
			for end < le && v.vimClass(end, big) == next {
				end = v.nextRune(end)
			}
		}
		return start, end, true
	}
	spaces := end
	for spaces < le && v.vimClass(spaces, big) == 1 {
		spaces = v.nextRune(spaces)
	}
	if spaces > end {
		return start, spaces, true
	}
	for start > ls && v.vimClass(v.prevRune(start), big) == 1 {
		start = v.prevRune(start)
	}
	return start, end, true
}

// vimQuoteObject is the text between the quotes q that hold the caret, on its line (i" and a").
// Around the quotes it includes them.
func (v *View) vimQuoteObject(q rune, inner bool) (int, int, bool) {
	c := v.caret
	line := v.text.LineOf(c)
	ls, le := v.text.LineStart(line), v.lineEnd(line)
	var quotes []int
	for p := ls; p < le; p = v.nextRune(p) {
		if v.runeAt(p) == q {
			quotes = append(quotes, p)
		}
	}
	for i := 0; i+1 < len(quotes); i += 2 {
		a, b := quotes[i], quotes[i+1]
		if c < a || c > b {
			continue
		}
		if inner {
			return v.nextRune(a), b, true
		}
		end := v.nextRune(b)
		for end < le && v.vimClass(end, false) == 1 {
			end = v.nextRune(end)
		}
		return a, end, true
	}
	return 0, 0, false
}

// vimBlockObject is the text between the brackets open and close around the caret, across lines.
// Around the brackets it includes them.
func (v *View) vimBlockObject(open, close rune, inner bool) (int, int, bool) {
	c := v.caret
	n := v.text.Len()
	o := -1
	if v.runeAt(c) == open {
		o = c
	} else {
		depth := 0
		for p := c; p > 0; {
			p = v.prevRune(p)
			switch v.runeAt(p) {
			case close:
				depth++
			case open:
				if depth == 0 {
					o = p
				} else {
					depth--
				}
			}
			if o >= 0 {
				break
			}
		}
	}
	if o < 0 {
		return 0, 0, false
	}
	depth := 0
	for p := o; p < n; p = v.nextRune(p) {
		switch v.runeAt(p) {
		case open:
			depth++
		case close:
			depth--
		}
		if depth == 0 {
			if inner {
				return v.nextRune(o), p, true
			}
			return o, v.nextRune(p), true
		}
	}
	return 0, 0, false
}
