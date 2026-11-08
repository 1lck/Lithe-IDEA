package editorview

import (
	"runtime"
	"strings"
	"unicode/utf8"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// commandKey is the modifier of the editing chords: Command on a Mac, Control elsewhere.
func commandKey() ui.Modifiers {
	if runtime.GOOS == "darwin" {
		return ui.ModifierMeta
	}
	return ui.ModifierControl
}

// handled is a key or a chord the view took, with a frame to show what it did.
var handled = ui.EventResult{Handled: true, Repaint: true}

// Shortcut does the chords the editor owns before the text system sees them: select all,
// copy, cut, paste, undo, redo and save. The second result is false for any other chord.
func (v *View) Shortcut(event ui.KeyEvent) (ui.EventResult, bool) {
	if event.Target != v.cfg.HitID || event.Release || event.Key != ui.KeyUnknown {
		return ui.EventResult{}, false
	}
	cmd := commandKey()
	shift := event.Modifiers&ui.ModifierShift != 0
	if event.Modifiers&^ui.ModifierShift != cmd {
		return ui.EventResult{}, false
	}
	switch strings.ToLower(event.Text) {
	case "a":
		v.SelectAll()
	case "c":
		if text := v.SelectedText(); text != "" {
			return ui.EventResult{Handled: true, ClipboardText: text}, true
		}
		return ui.EventResult{Handled: true}, true
	case "x":
		text := v.SelectedText()
		if text == "" {
			return ui.EventResult{Handled: true}, true
		}
		v.insert("", editOther)
		return ui.EventResult{Handled: true, Repaint: true, ClipboardText: text}, true
	case "v":
		if text, err := app.ClipboardText(); err == nil && text != "" {
			v.insert(text, editOther)
		}
	case "z":
		if shift {
			v.Redo()
		} else {
			v.Undo()
		}
	case "y":
		if runtime.GOOS == "darwin" {
			return ui.EventResult{}, false
		}
		v.Redo()
	case "s":
		if v.cfg.Save != nil {
			v.cfg.Save()
		}
	default:
		return ui.EventResult{}, false
	}
	return handled, true
}

// Key moves the caret and edits with the named keys. Typed characters come as text input (see
// TextInput); the second result is false for a key of another target.
func (v *View) Key(event ui.KeyEvent) (ui.EventResult, bool) {
	if event.Target != v.cfg.HitID {
		return ui.EventResult{}, false
	}
	if event.Release {
		return ui.EventResult{Handled: true}, true
	}
	if v.preedit.Composing {
		// The input method owns the keys while it composes.
		return ui.EventResult{Handled: true}, true
	}
	mods := event.Modifiers
	extend := mods&ui.ModifierShift != 0
	word := mods&ui.ModifierAlt != 0
	if runtime.GOOS != "darwin" && mods&ui.ModifierControl != 0 {
		word = true
	}
	edge := runtime.GOOS == "darwin" && mods&ui.ModifierMeta != 0
	start, end := v.Selection()
	line := v.text.LineOf(v.caret)
	switch event.Key {
	case ui.KeyLeft:
		switch {
		case edge:
			v.moveTo(v.homeOf(line), extend)
		case word:
			v.moveTo(v.wordLeft(v.caret), extend)
		case start != end && !extend:
			v.moveTo(start, false)
		default:
			v.moveTo(v.prevRune(v.caret), extend)
		}
	case ui.KeyRight:
		switch {
		case edge:
			v.moveTo(v.lineEnd(line), extend)
		case word:
			v.moveTo(v.wordRight(v.caret), extend)
		case start != end && !extend:
			v.moveTo(end, false)
		default:
			v.moveTo(v.nextRune(v.caret), extend)
		}
	case ui.KeyUp:
		switch {
		case edge:
			v.moveTo(0, extend)
		case line == 0:
			v.moveTo(0, extend)
		default:
			v.vertical(line-1, extend)
		}
	case ui.KeyDown:
		switch {
		case edge:
			v.moveTo(v.text.Len(), extend)
		case line >= v.text.LineCount()-1:
			v.moveTo(v.text.Len(), extend)
		default:
			v.vertical(line+1, extend)
		}
	case ui.KeyHome:
		v.moveTo(v.homeOf(line), extend)
	case ui.KeyEnd:
		v.moveTo(v.lineEnd(line), extend)
	case ui.KeyPageUp, ui.KeyPageDown:
		rows := max(int(v.area.Height/max(v.lineH, 1))-1, 1)
		if event.Key == ui.KeyPageUp {
			rows = -rows
		}
		target := min(max(line+rows, 0), v.text.LineCount()-1)
		v.scroll += float32(target-line) * v.lineH
		v.vertical(target, extend)
	case ui.KeyBackspace:
		switch {
		case start != end:
			v.insert("", editOther)
		case edge:
			v.edit(v.text.LineStart(line), v.caret, nil, editOther)
		case word:
			v.edit(v.wordLeft(v.caret), v.caret, nil, editOther)
		default:
			v.edit(v.backspaceFrom(line), v.caret, nil, editDeleting)
		}
	case ui.KeyDelete:
		switch {
		case start != end:
			v.insert("", editOther)
		case edge:
			v.edit(v.caret, v.lineEnd(line), nil, editOther)
		case word:
			v.edit(v.caret, v.wordRight(v.caret), nil, editOther)
		default:
			v.edit(v.caret, v.nextRune(v.caret), nil, editOther)
		}
	case ui.KeyEnter:
		if mods&^ui.ModifierShift != 0 {
			return ui.EventResult{}, false
		}
		v.newline()
	case ui.KeyTab:
		if mods&^ui.ModifierShift != 0 {
			return ui.EventResult{}, false
		}
		v.tab(extend)
	case ui.KeyEscape:
		if start == end {
			return ui.EventResult{}, false
		}
		v.moveTo(v.caret, false)
	default:
		return ui.EventResult{}, false
	}
	return handled, true
}

// vertical moves the caret to line, keeping to the column it aimed at before.
func (v *View) vertical(line int, extend bool) {
	target := v.verticalTarget(line)
	goal := v.goal
	v.moveTo(target, extend)
	v.goal = goal
}

// homeOf is where Home takes the caret on line: to the first character that is not
// indentation, or to the start of the line when it is already there.
func (v *View) homeOf(line int) int {
	start := v.text.LineStart(line)
	first := start + len(v.leadingSpace(line))
	if v.caret == first {
		return start
	}
	return first
}

// backspaceFrom is where Backspace deletes back to: the character before the caret, or a whole
// indent unit of spaces when the caret is in the line's indentation.
func (v *View) backspaceFrom(line int) int {
	start := v.text.LineStart(line)
	if v.indentUnit != "\t" && v.caret > start {
		col := v.caret - start
		indent := v.leadingSpace(line)
		if col <= len(indent) && !strings.Contains(indent[:col], "\t") {
			step := (col-1)%len(v.indentUnit) + 1
			return v.caret - step
		}
	}
	return v.prevRune(v.caret)
}

// closers pairs the brackets Enter indents between.
var closers = map[byte]byte{'{': '}', '(': ')', '[': ']'}

// newline breaks the line at the caret and indents the new line as the one it came from, and
// one unit more after an opening bracket. Between a pair of brackets the closing one goes on a
// line of its own.
func (v *View) newline() {
	start, end := v.Selection()
	line := v.text.LineOf(start)
	indent := v.leadingSpace(line)
	if start-v.text.LineStart(line) < len(indent) {
		indent = indent[:start-v.text.LineStart(line)]
	}
	var before, after byte
	if start > v.text.LineStart(line) {
		before = v.text.ByteAt(start - 1)
	}
	if end < v.lineEnd(v.text.LineOf(end)) {
		after = v.text.ByteAt(end)
	}
	closer, opens := closers[before]
	if !opens {
		v.edit(start, end, []byte("\n"+indent), editOther)
		return
	}
	inner := "\n" + indent + v.indentUnit
	if after == closer {
		v.edit(start, end, []byte(inner+"\n"+indent), editOther)
		v.moveTo(start+len(inner), false)
		return
	}
	v.edit(start, end, []byte(inner), editOther)
}

// tab indents: a selection over lines indents or, with Shift, outdents every line it touches;
// otherwise Tab inserts an indent unit, or spaces to the next tab stop.
func (v *View) tab(outdent bool) {
	start, end := v.Selection()
	first, last := v.text.LineOf(start), v.text.LineOf(end)
	if first == last && !outdent {
		unit := v.indentUnit
		if unit != "\t" {
			l := v.text.Line(first)
			cells := cellsOf(l, start-v.text.LineStart(first))
			unit = strings.Repeat(" ", tabSize-cells%tabSize)
		}
		v.insert(unit, editOther)
		return
	}
	if last > first && end == v.text.LineStart(last) {
		last--
	}
	// The lines are rewritten as one edit, so one undo takes it back.
	from, to := v.text.LineStart(first), v.text.LineEnd(last)
	lines := strings.Split(string(v.text.AppendRange(nil, from, to)), "\n")
	for i, l := range lines {
		switch {
		case !outdent:
			if strings.TrimSpace(l) != "" {
				lines[i] = v.indentUnit + l
			}
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
	joined := strings.Join(lines, "\n")
	v.edit(from, to, []byte(joined), editOther)
	v.anchor, v.caret = from, from+len(joined)
}

// TextInput resolves the platform's text surface for the focused view: a preedit surface at
// the caret, where input methods compose, and the receiver of typed text and pastes. It is
// nil for any other hit. The value is reused, so resolving it each frame allocates nothing.
func (v *View) TextInput(ctx app.TextInputContext) *app.TextInput {
	if ctx.ID != v.cfg.HitID {
		return nil
	}
	cells := 1
	if v.preedit.Composing {
		for _, r := range v.preedit.Value {
			cells += runeCells(r, 0)
		}
	}
	x, y := v.caretPoint()
	v.input.Bounds = ui.Rect{X: x, Y: y + (v.lineH-v.cellH)/2, Width: float32(cells) * v.cellW, Height: v.cellH}
	v.input.FontSize = fontSize
	v.input.Color = v.themeFG
	v.input.State = v.preedit
	v.input.AltSendsEscape = false
	if v.input.OnEvent == nil {
		v.input.OnEvent = func(event app.TextEvent) (app.TextState, error) {
			return v.applyText(event), nil
		}
	}
	return &v.input
}

// applyText applies a text-system event: typed text and pastes replace the selection, and an input
// method's composition is kept for the platform to draw at the caret.
func (v *View) applyText(event app.TextEvent) app.TextState {
	redraw := false
	switch event.Kind {
	case app.TextInsert:
		v.preedit = app.TextState{}
		v.insert(event.Text, editTyping)
		redraw = true
	case app.TextPaste:
		v.insert(event.Text, editOther)
		redraw = true
	case app.TextSetMarked:
		runes := utf8.RuneCountInString(event.Text)
		v.preedit = app.TextState{
			Value: event.Text, Selection: event.MarkedSelection,
			Composition: app.TextRange{End: runes}, Composing: runes > 0,
		}
		redraw = true
	case app.TextUnmark:
		v.preedit = app.TextState{}
		redraw = true
	}
	result := v.preedit
	result.Redraw = redraw
	return result
}

// Pointer places the caret and selects with the pointer: a click puts the caret, a double
// click selects a word and a triple click a line, Shift extends the selection and a drag
// selects by the unit it started with. The second result is false for an event that is not
// the view's.
func (v *View) Pointer(event ui.PointerEvent) (ui.EventResult, bool) {
	switch {
	case event.Kind == ui.PointerDown && event.Target == v.cfg.HitID:
	case v.dragging && (event.Kind == ui.PointerMove || event.Kind == ui.PointerUp):
	default:
		return ui.EventResult{}, false
	}
	if !v.painted {
		return ui.EventResult{Handled: true}, true
	}
	offset := v.offsetAt(event.X, event.Y)
	switch event.Kind {
	case ui.PointerDown:
		if event.Button != ui.PointerButtonPrimary {
			return ui.EventResult{Handled: true, Focus: v.cfg.HitID}, true
		}
		v.dragging = true
		v.dragUnit = min(max(event.ClickCount, 1), 3)
		if event.Modifiers&ui.ModifierShift != 0 && v.dragUnit == 1 {
			v.dragFrom, v.dragTo = v.anchor, v.anchor
		} else {
			v.dragFrom, v.dragTo = v.unitAt(offset)
		}
		v.dragSelect(offset)
		return ui.EventResult{Handled: true, Repaint: true, Focus: v.cfg.HitID}, true
	case ui.PointerMove:
		v.dragSelect(offset)
		return handled, true
	}
	v.dragging = false
	return handled, true
}

// unitAt is the character, word or line at offset, by the unit of the drag.
func (v *View) unitAt(offset int) (int, int) {
	switch v.dragUnit {
	case 2:
		return v.wordAt(offset)
	case 3:
		return v.lineRange(v.text.LineOf(offset))
	}
	return offset, offset
}

// dragSelect selects from the unit the drag started on to the unit at offset.
func (v *View) dragSelect(offset int) {
	from, to := v.unitAt(offset)
	if from < v.dragFrom {
		v.anchor, v.caret = v.dragTo, from
	} else {
		v.anchor, v.caret = v.dragFrom, max(to, v.dragTo)
	}
	v.lastKind = editOther
	v.moved()
}

// offsetAt is the offset of the character edge nearest the point (x, y).
func (v *View) offsetAt(x, y float32) int {
	line := int((y - v.area.Y + v.scroll) / max(v.lineH, 1))
	if y < v.area.Y+0 && line < 0 {
		line = 0
	}
	line = min(max(line, 0), v.text.LineCount()-1)
	cells := (x - v.textLeft + v.scrollX) / max(v.cellW, 1)
	return v.text.LineStart(line) + columnAt(v.text.Line(line), max(cells, 0))
}

// Scroll scrolls the text with the wheel or the trackpad: up and down, and sideways with a
// sideways swipe or with Shift held. The second result is false for an event over another hit.
func (v *View) Scroll(event ui.ScrollEvent) (ui.EventResult, bool) {
	if event.Target != v.cfg.HitID || !v.painted {
		return ui.EventResult{}, false
	}
	dx, dy := event.DeltaX, event.DeltaY
	if dx == 0 && event.Modifiers&ui.ModifierShift != 0 {
		dx, dy = dy, 0
	}
	if !event.Precise {
		dx, dy = notch(dx, v.lineH), notch(dy, v.lineH)
	}
	beforeX, beforeY := v.scrollX, v.scroll
	v.scroll += dy
	v.scrollX += dx
	v.clampScroll()
	return ui.EventResult{Handled: true, Repaint: v.scroll != beforeY || v.scrollX != beforeX}, true
}

// notch makes a mouse wheel's step at least a line, as a trackpad's is exactly what it reports.
func notch(delta, line float32) float32 {
	switch {
	case delta > 0 && delta < line:
		return line
	case delta < 0 && delta > -line:
		return -line
	}
	return delta
}
