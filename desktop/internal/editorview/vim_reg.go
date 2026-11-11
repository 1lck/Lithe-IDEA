package editorview

import (
	"strings"

	"github.com/vivaui/viva/app"
)

// vim_reg.go is the Vim registers and marks. The unnamed register always holds the last text
// yanked, deleted or changed. A named register a-z keeps its text beside it; A-Z appends to a-z.
// "+ and "* are the system clipboard: yanks write it and puts read it. A mark a-z is a position
// that edits move with the text around it.

// vimReg is the text of a register and whether it holds whole lines.
type vimReg struct {
	text string
	line bool
}

// vimSetReg stores the text of operator op (y yanks, the others delete or change) in the register
// the command names, and in the unnamed register. With no name a yank goes to "0; a delete of whole
// lines or of several lines shifts "1 to "9 down and goes to "1; any other delete goes to "-.
func (v *View) vimSetReg(op byte, text string, line bool) {
	st := &v.vim
	st.reg, st.regLine = text, line
	r := vimReg{text, line}
	switch name := st.regName; {
	case name == '+' || name == '*':
		_ = app.SetClipboardText(text)
	case name >= 'a' && name <= 'z':
		st.namedReg(name, r)
	case name >= 'A' && name <= 'Z':
		lower := name + ('a' - 'A')
		old := st.regs[lower]
		st.namedReg(lower, vimReg{old.text + text, old.line || line})
	case op == 'y':
		st.namedReg('0', r)
	case line || strings.Contains(text, "\n"):
		for d := byte('9'); d > '1'; d-- {
			st.namedReg(d, st.regs[d-1])
		}
		st.namedReg('1', r)
	default:
		st.namedReg('-', r)
	}
}

// namedReg stores r in the named register name.
func (st *vimState) namedReg(name byte, r vimReg) {
	if st.regs == nil {
		st.regs = map[byte]vimReg{}
	}
	st.regs[name] = r
}

// vimReadReg is the text and line flag of the register name, which a put reads.
func (v *View) vimReadReg(name byte) (string, bool) {
	st := &v.vim
	switch {
	case name == '+' || name == '*':
		text, err := app.ClipboardText()
		if err != nil {
			return "", false
		}
		return text, false
	case name >= 'a' && name <= 'z' || name >= 'A' && name <= 'Z':
		r := st.regs[name|0x20]
		return r.text, r.line
	case name >= '0' && name <= '9' || name == '-':
		r := st.regs[name]
		return r.text, r.line
	}
	return st.reg, st.regLine
}

// vimPasteAs puts text the way p does, after the caret or over the selection in Visual mode. It is the
// paste of the Vim mode in Normal and Visual modes: the clipboard and pasted text come through it.
func (v *View) vimPasteAs(text string) {
	if text == "" {
		return
	}
	if v.vim.mode == vimVisual || v.vim.mode == vimVisualLine || v.vim.mode == vimVisualBlock {
		v.vimVisualPasteText(text, false)
		return
	}
	v.vimPasteText(text, false, true)
}

// vimSetMark records the caret as mark name.
func (v *View) vimSetMark(name byte) {
	st := &v.vim
	if st.marks == nil {
		st.marks = map[byte]int{}
	}
	st.marks[name] = v.caret
}

// vimMarkMove is the motion to mark name: to its line's first character when linewise (') or to
// its exact position (`). The second result is false when the mark is not set.
func (v *View) vimMarkMove(name byte, linewise bool) (vimMove, bool) {
	at, ok := v.vim.marks[name]
	if !ok {
		return vimMove{}, false
	}
	at = min(at, v.text.Len())
	if linewise {
		return vimMove{to: v.vimFirstNB(v.text.LineOf(at)), line: true}, true
	}
	return vimMove{to: at}, true
}

// vimShiftMarks moves the marks after an edit that replaced start..end with n bytes: a mark after the
// edit moves with the text, and a mark inside it goes to the edit's start.
func (v *View) vimShiftMarks(start, end, n int) {
	for name, at := range v.vim.marks {
		switch {
		case at >= end:
			v.vim.marks[name] = at + n - (end - start)
		case at > start:
			v.vim.marks[name] = start
		}
	}
}
