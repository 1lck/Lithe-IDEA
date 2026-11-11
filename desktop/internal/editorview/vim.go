package editorview

import (
	"strings"
	"unicode/utf8"

	"github.com/vivaui/viva/gfx"
)

// vim.go is the Vim mode of a view: its modes, the keys each mode takes, and the bookkeeping that
// makes a command one undo step and lets "." repeat the last change.
//
// With the mode on, Normal and Visual modes take every key as a command. Insert and Replace take
// typed text the way the view always did, and Escape returns to Normal. A typed character reaches
// the view as text input (see applyText), and the keys that name themselves (arrows, Escape,
// Enter, Backspace) as key events (see key); both are turned into tokens here. A token is what
// "." replays, so the keys of a change are recorded as they are taken.
//
// Motions are in vim_motion.go, operators and text objects in vim_op.go and search in vim_search.go.

// vimMode is the mode the Vim keys are in. A document turned on starts in Normal mode.
type vimMode uint8

const (
	vimNormal vimMode = iota
	vimInsert
	vimReplace
	vimVisual
	vimVisualLine
)

// The text the Vim mode reads for the keys that do not type a character.
const (
	vimEscape    = "\x1b"
	vimEnter     = "\r"
	vimBackspace = "\b"
	vimCtrlB     = "\x02"
	vimCtrlF     = "\x06"
	vimCtrlR     = "\x12"
)

// vimToken is one key the Vim mode took: the text it typed, or a named key that Insert mode
// hands to the ordinary key handling when it replays.
type vimToken struct {
	text string
	key  gfx.Key
	mods gfx.Modifiers
}

// vimState is the Vim mode of a view.
type vimState struct {
	on   bool
	mode vimMode
	// count is the count typed before the command, and opCount the one typed before its
	// operator; both are zero when none was typed.
	count, opCount int
	// op is the pending operator (d, c, y, > or <), zero for none. pend is the key the command
	// waits for: r, f, F, t, T, g, i or a (the text object's inner or around). Both are zero when
	// nothing is pending.
	op, pend byte
	// searching says a / or ? prompt is open, searchBack is its direction and prompt the text
	// typed so far. pattern is the last search and searchBackward its direction, for n and N.
	searching, searchBack bool
	prompt                []rune
	pattern               string
	searchBackward        bool
	// findKind is the last f, F, t or T and findChar its character; findValid says there was one.
	findKind  byte
	findChar  string
	findValid bool
	// reg is the unnamed register and regLine says it holds whole lines, without the line break
	// that ends the last of them. The register is the view's own: it does not touch the
	// clipboard, as the editor it replaces did not.
	reg     string
	regLine bool
	// cur is the tokens of the command in progress, and changed says it changed the text. dot is
	// the tokens of the last change and dotCount its count, which "." replays.
	cur      []vimToken
	changed  bool
	dot      []vimToken
	dotCount int
	// grouped says the edits made since the command began are one undo step, which is open.
	grouped bool
	// replaying says "." is replaying dot; its tokens are not recorded again.
	replaying bool
}

// vimMove is where a motion takes the caret, and how an operator reads its range.
type vimMove struct {
	to int
	// incl says the character at to belongs to an operator's range, line says the range is whole
	// lines, and vertical says the motion aims at a column that keeps (see goal).
	incl, line, vertical bool
}

// SetVimMode turns the Vim keys on or off. A document turned on starts in Normal mode. The unnamed
// register is kept, so yanks made in one session paste in the next.
func (v *View) SetVimMode(on bool) {
	if v.vim.on == on {
		return
	}
	reg, regLine := v.vim.reg, v.vim.regLine
	v.vim = vimState{on: on, reg: reg, regLine: regLine}
	if on {
		v.vimClamp()
		return
	}
	v.anchor = v.caret
	v.moved()
}

// VimOn says whether the Vim keys are on.
func (v *View) VimOn() bool { return v.vim.on }

// VimStatus is the Vim mode's name for the status bar, or the search prompt while one is being
// typed. It is empty while the Vim keys are off.
func (v *View) VimStatus() string {
	st := &v.vim
	if !st.on {
		return ""
	}
	if st.searching {
		prefix := "/"
		if st.searchBack {
			prefix = "?"
		}
		return prefix + string(st.prompt)
	}
	switch st.mode {
	case vimInsert:
		return v.words.VimInsert
	case vimReplace:
		return v.words.VimReplace
	case vimVisual:
		return v.words.VimVisual
	case vimVisualLine:
		return v.words.VimVisualLine
	}
	return v.words.VimNormal
}

// vimBlock says the caret is drawn as a block over its character: in Normal and Visual modes.
func (v *View) vimBlock() bool {
	return v.vim.on && (v.vim.mode == vimNormal || v.vim.mode == vimVisual || v.vim.mode == vimVisualLine)
}

// vimSelection widens the selection of the Visual modes: Visual takes the character the caret is
// on, Visual Line the whole lines from the first to the last. start and end are in order.
func (v *View) vimSelection(start, end int) (int, int) {
	switch v.vim.mode {
	case vimVisual:
		return start, v.nextRune(end)
	case vimVisualLine:
		first, last := v.text.LineOf(start), v.text.LineOf(end)
		end = v.text.Len()
		if last+1 < v.text.LineCount() {
			end = v.text.LineStart(last + 1)
		}
		return v.text.LineStart(first), end
	}
	return start, end
}

// vimKey takes a key event the Vim mode owns. The second result is false for a key that the
// ordinary key handling must still run: the keys Insert mode edits with, after the mode has
// recorded them.
func (v *View) vimKey(event gfx.KeyEvent) (gfx.EventResult, bool) {
	st := &v.vim
	if !st.on || st.replaying {
		return gfx.EventResult{}, false
	}
	if st.mode == vimInsert || st.mode == vimReplace {
		if event.Key == gfx.KeyEscape {
			v.vimFeed(vimToken{text: vimEscape})
			return handled, true
		}
		if event.Key != gfx.KeyUnknown {
			v.vimRecord(vimToken{key: event.Key, mods: event.Modifiers})
		}
		return gfx.EventResult{}, false
	}
	if st.searching && event.Key != gfx.KeyEscape && event.Key != gfx.KeyEnter && event.Key != gfx.KeyBackspace {
		return handled, true
	}
	if text, ok := vimKeyText(event.Key); ok {
		v.vimFeed(vimToken{text: text})
	}
	// Normal and Visual modes take no other key: it does nothing rather than edit.
	return handled, true
}

// vimKeyText is the text a named key stands for in Normal and Visual modes.
func vimKeyText(key gfx.Key) (string, bool) {
	switch key {
	case gfx.KeyLeft:
		return "h", true
	case gfx.KeyRight:
		return "l", true
	case gfx.KeyUp:
		return "k", true
	case gfx.KeyDown:
		return "j", true
	case gfx.KeyHome:
		return "0", true
	case gfx.KeyEnd:
		return "$", true
	case gfx.KeyDelete:
		return "x", true
	case gfx.KeyBackspace:
		return vimBackspace, true
	case gfx.KeyEnter:
		return vimEnter, true
	case gfx.KeyEscape:
		return vimEscape, true
	case gfx.KeyPageUp:
		return vimCtrlB, true
	case gfx.KeyPageDown:
		return vimCtrlF, true
	}
	return "", false
}

// vimText takes typed text (see applyText). Each character is a token of its own.
func (v *View) vimText(text string) {
	for _, r := range text {
		v.vimFeed(vimToken{text: string(r)})
	}
}

// vimChord takes the Control chords the Vim mode owns: Ctrl+R redoes, and Ctrl+B and Ctrl+F page.
// Ctrl+W and Ctrl+T are left to nothing, so the workbench does not take them either (see
// windowShortcuts). The second result is false for any other chord.
func (v *View) vimChord(text string) (gfx.EventResult, bool) {
	var token string
	switch strings.ToLower(text) {
	case "r":
		token = vimCtrlR
	case "b":
		token = vimCtrlB
	case "f":
		token = vimCtrlF
	case "w", "t":
		return handled, true
	default:
		return gfx.EventResult{}, false
	}
	if v.vim.mode != vimInsert && v.vim.mode != vimReplace {
		v.vimFeed(vimToken{text: token})
	}
	return handled, true
}

// vimFeed takes a token the Vim mode owns: it is recorded for "." and then runs.
func (v *View) vimFeed(tok vimToken) {
	v.vimRecord(tok)
	v.vimToken(tok)
}

// vimRecord adds tok to the command in progress, unless "." is replaying.
func (v *View) vimRecord(tok vimToken) {
	if !v.vim.replaying {
		v.vim.cur = append(v.vim.cur, tok)
	}
}

// vimBusy says a command is not finished: it waits for a key, or the mode is not Normal.
func (v *View) vimBusy() bool {
	st := &v.vim
	return st.mode != vimNormal || st.pend != 0 || st.op != 0 || st.count != 0 || st.opCount != 0 || st.searching
}

// vimToken runs one token. A change that completes a command in Normal mode becomes the one "."
// repeats (see vimIdle).
func (v *View) vimToken(tok vimToken) {
	st := &v.vim
	if !v.vimBusy() {
		// A command starts: its edits open a new undo step, whatever the step before was.
		st.grouped = false
	}
	if st.mode == vimInsert || st.mode == vimReplace {
		v.vimInsertToken(tok)
	} else {
		v.vimCommandToken(tok)
	}
	if !v.vimBusy() {
		v.vimIdle()
	}
}

// vimIdle ends a command that is done. A command that changed the text is the one "." repeats,
// and its edits are one undo step.
func (v *View) vimIdle() {
	st := &v.vim
	if st.replaying {
		return
	}
	if st.changed {
		st.dot, st.dotCount = vimStripCount(st.cur)
	}
	st.cur, st.changed, st.grouped = nil, false, false
}

// vimStripCount is tokens without the count that starts them, and that count. A "0" with no count
// before it is a motion, not a count.
func vimStripCount(tokens []vimToken) ([]vimToken, int) {
	count, i := 0, 0
	for ; i < len(tokens); i++ {
		d := tokens[i].text
		if len(d) != 1 || d[0] < '0' || d[0] > '9' || (d == "0" && count == 0) {
			break
		}
		count = count*10 + int(d[0]-'0')
	}
	return append([]vimToken(nil), tokens[i:]...), count
}

// vimRepeat is "." : it replays the last change, with count instead of its own count when one is
// typed. The replayed keys are not recorded, so the change stays the one "." repeats.
func (v *View) vimRepeat(count int) {
	st := &v.vim
	if len(st.dot) == 0 {
		return
	}
	if count == 0 {
		count = st.dotCount
	}
	st.replaying = true
	if count > 0 {
		for _, d := range vimDigits(count) {
			v.vimToken(vimToken{text: string(d)})
		}
	}
	for _, tok := range st.dot {
		if tok.key != gfx.KeyUnknown {
			v.key(gfx.KeyEvent{Key: tok.key, Modifiers: tok.mods, Target: v.cfg.HitID})
			continue
		}
		v.vimToken(tok)
	}
	st.replaying = false
	// The command "." is the one being run; the change it replayed stays the one to repeat.
	st.cur, st.changed, st.grouped = nil, false, false
}

// vimDigits is the digits of n.
func vimDigits(n int) string {
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

// vimInsertToken takes a token in Insert or Replace mode. Escape returns to Normal mode; the rest is
// typed text, which Replace mode writes over the character under the caret.
func (v *View) vimInsertToken(tok vimToken) {
	st := &v.vim
	if tok.text == vimEscape {
		v.vimLeaveInsert()
		return
	}
	if st.mode == vimInsert {
		v.insert(tok.text, editTyping)
		return
	}
	for _, r := range tok.text {
		at := v.caret
		if at < v.lineEnd(v.text.LineOf(at)) {
			v.edit(at, v.nextRune(at), string(r), editOther)
		} else {
			v.edit(at, at, string(r), editOther)
		}
	}
}

// vimLeaveInsert returns to Normal mode, and the caret steps back onto the character before it.
func (v *View) vimLeaveInsert() {
	st := &v.vim
	st.mode = vimNormal
	if line := v.text.LineOf(v.caret); v.caret > v.text.LineStart(line) {
		v.moveTo(v.prevRune(v.caret), false)
	}
	v.vimClamp()
}

// vimEnterInsert starts Insert or Replace mode with the caret at at, a command that changes the
// text.
func (v *View) vimEnterInsert(mode vimMode, at int) {
	v.vim.mode = mode
	v.vim.changed = true
	v.moveTo(at, false)
}

// vimClamp keeps the caret on a character in Normal and Visual modes, where a line has no caret past
// its last character. It leaves the goal column alone.
func (v *View) vimClamp() {
	st := &v.vim
	if !st.on || st.mode == vimInsert || st.mode == vimReplace {
		return
	}
	line := v.text.LineOf(v.caret)
	start, end := v.text.LineStart(line), v.lineEnd(line)
	if v.caret >= end {
		if end > start {
			v.caret = v.prevRune(end)
		} else {
			v.caret = start
		}
	}
	if st.mode == vimNormal {
		v.anchor = v.caret
	}
}

// vimLastChar is the offset of the last character of line, or the line's start when it is empty.
func (v *View) vimLastChar(line int) int {
	start, end := v.text.LineStart(line), v.lineEnd(line)
	if end > start {
		return v.prevRune(end)
	}
	return start
}

// vimFirstNB is the first character of line that is not a space, or the line's end when there is none.
func (v *View) vimFirstNB(line int) int {
	at, end := v.text.LineStart(line), v.lineEnd(line)
	for at < end && (v.text.ByteAt(at) == ' ' || v.text.ByteAt(at) == '\t') {
		at++
	}
	return at
}

// vimPageRows is how many rows a page moves the caret.
func (v *View) vimPageRows() int {
	return max(int(v.area.Height/max(v.lineH, 1))-1, 1)
}

// vimCommandToken takes a token in Normal or Visual mode, and the pending key of a command.
func (v *View) vimCommandToken(tok vimToken) {
	st := &v.vim
	s := tok.text
	if s == "" {
		return
	}
	switch st.pend {
	case 'g':
		st.pend = 0
		if s == "g" {
			v.vimMotionCmd("gg")
		} else {
			v.vimCancel()
		}
		return
	case 'f', 'F', 't', 'T':
		kind := st.pend
		st.pend = 0
		r, _ := utf8.DecodeRuneInString(s)
		if !vimPrintable(r) {
			v.vimCancel()
			return
		}
		st.findKind, st.findChar, st.findValid = kind, s, true
		v.vimFindCmd(kind, s, max(st.count, 1))
		v.vimCancel()
		return
	}
	if vimDigit(s) && (s != "0" || st.count > 0) {
		st.count = st.count*10 + int(s[0]-'0')
		return
	}
	v.vimCommand(s)
}

// vimDigit says s is one digit.
func vimDigit(s string) bool { return len(s) == 1 && s[0] >= '0' && s[0] <= '9' }

// vimPrintable says r is a character a command can take: a printable one, not a line break or a
// control character.
func vimPrintable(r rune) bool { return r >= ' ' && r != 0x7f && r != utf8.RuneError }

// vimCancel ends the command in progress: its count, operator and pending key.
func (v *View) vimCancel() {
	st := &v.vim
	st.count, st.opCount, st.op, st.pend = 0, 0, 0, 0
}

// vimCommand runs a command key in Normal or Visual mode, the count and operator already typed.
func (v *View) vimCommand(s string) {
	st := &v.vim
	visual := st.mode == vimVisual || st.mode == vimVisualLine
	switch s {
	case vimEscape:
		if visual {
			st.mode = vimNormal
			v.vimClamp()
		}
		v.vimCancel()
		return
	case "i", "a", "I", "A", "R":
		if visual {
			break
		}
		v.vimInsertCmd(s)
		v.vimCancel()
		return
	case "v", "V":
		v.vimVisualCmd(s)
		v.vimCancel()
		return
	case "g":
		st.pend = 'g'
		return
	case "f", "F", "t", "T":
		st.pend = s[0]
		return
	case ";", ",":
		if !st.findValid {
			v.vimCancel()
			return
		}
		kind := st.findKind
		if s == "," {
			kind = vimReverseFind(kind)
		}
		v.vimFindCmd(kind, st.findChar, max(st.count, 1))
		v.vimCancel()
		return
	case ".":
		count := st.count
		v.vimCancel()
		v.vimRepeat(count)
		return
	case "u":
		if !visual {
			v.Undo()
		}
		v.vimCancel()
		return
	case vimCtrlR:
		if !visual {
			v.Redo()
		}
		v.vimCancel()
		return
	}
	if strings.Contains("hl jk+-\r\b$0^wWbBeE%G"+vimCtrlB+vimCtrlF, s) {
		v.vimMotionCmd(s)
		return
	}
	v.vimCancel()
}

// vimReverseFind is the find that "," repeats: the opposite direction of kind.
func vimReverseFind(kind byte) byte {
	switch kind {
	case 'f':
		return 'F'
	case 'F':
		return 'f'
	case 't':
		return 'T'
	}
	return 't'
}

// vimVisualCmd turns Visual mode on, or off when it is already the mode v or V asks for.
func (v *View) vimVisualCmd(s string) {
	st := &v.vim
	want := vimVisual
	if s == "V" {
		want = vimVisualLine
	}
	switch {
	case st.mode == want:
		st.mode = vimNormal
		v.vimClamp()
	case st.mode == vimNormal:
		v.anchor = v.caret
		st.mode = want
	default:
		st.mode = want
	}
}

// vimInsertCmd starts Insert mode the way the key says: i at the caret, a after it, I at the first
// character of the line, A at its end, and R in Replace mode.
func (v *View) vimInsertCmd(s string) {
	line := v.text.LineOf(v.caret)
	at := v.caret
	mode := vimInsert
	switch s {
	case "a":
		if at < v.lineEnd(line) {
			at = v.nextRune(at)
		}
	case "I":
		at = v.vimFirstNB(line)
	case "A":
		at = v.lineEnd(line)
	case "R":
		mode = vimReplace
	}
	v.vimEnterInsert(mode, at)
}

// vimMotionCmd moves the caret, or with an operator pending, makes the operator's range of the
// motion. count is the count typed, if any.
func (v *View) vimMotionCmd(s string) {
	st := &v.vim
	m, ok := v.vimMotionOf(s, v.vimRawCount(), st.op != 0)
	if !ok {
		v.vimCancel()
		return
	}
	v.vimApply(m)
}

// vimRawCount is the count of the command: the count typed, multiplied by the count before its
// operator. It is zero when none was typed.
func (v *View) vimRawCount() int {
	st := &v.vim
	n := st.count
	if st.opCount > 0 {
		if n == 0 {
			n = st.opCount
		} else {
			n *= st.opCount
		}
	}
	return n
}

// vimApply runs the motion m: it moves the caret, or with an operator pending, applies it to the
// range.
func (v *View) vimApply(m vimMove) {
	st := &v.vim
	if st.op == 0 {
		v.vimMoveCaret(m)
	}
	v.vimCancel()
}

// vimMoveCaret puts the caret where motion m takes it. A vertical motion keeps the column it aims at.
func (v *View) vimMoveCaret(m vimMove) {
	goal := v.goal
	extend := v.vim.mode == vimVisual || v.vim.mode == vimVisualLine
	v.moveTo(m.to, extend)
	if m.vertical {
		v.goal = goal
	}
	v.vimClamp()
}

// vimFindCmd finds the count-th ch in the caret's line in the direction kind and moves to it, or
// makes the operator's range to it.
func (v *View) vimFindCmd(kind byte, ch string, count int) {
	to, ok := v.vimFindChar(kind, ch, count)
	if !ok {
		v.vimCancel()
		return
	}
	var m vimMove
	switch kind {
	case 'f':
		m = vimMove{to: to, incl: true}
	case 't':
		m = vimMove{to: v.prevRune(to), incl: true}
	case 'F':
		m = vimMove{to: to}
	default:
		m = vimMove{to: v.nextRune(to)}
	}
	v.vimApply(m)
}
