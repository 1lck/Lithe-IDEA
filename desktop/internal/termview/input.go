package termview

import (
	"runtime"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// wheelStepLimit caps how many wheel reports, or arrow keys standing in for them, one
// scroll event sends. A fast flick can carry dozens of lines, and a program that is busy
// would take them all as a burst of scrolling long after the wheel stopped.
const wheelStepLimit = 5

// clipboardAction is what a clipboard chord asks of the terminal.
type clipboardAction uint8

const (
	clipboardNone clipboardAction = iota
	clipboardCopy
	clipboardPaste
)

// clipboardChord says whether a key event is one of the terminal's clipboard chords. The
// chords differ by platform because the plain Control chords belong to the program: on
// macOS Command is free for the terminal, elsewhere Control+Shift is the convention.
// Shift+Insert and Control+Insert are the classic aliases every terminal honors on every
// platform. Both Text spellings of the letter are accepted, since a platform may report
// the shifted one for a chord that holds Shift.
func clipboardChord(event ui.KeyEvent) clipboardAction {
	switch event.Key {
	case ui.KeyInsert:
		switch event.Modifiers {
		case ui.ModifierShift:
			return clipboardPaste
		case ui.ModifierControl:
			return clipboardCopy
		}
		return clipboardNone
	case ui.KeyUnknown:
		// A printable chord: Text holds its character without the modifiers.
	default:
		return clipboardNone
	}
	want := ui.ModifierControl | ui.ModifierShift
	if runtime.GOOS == "darwin" {
		want = ui.ModifierMeta
	}
	if event.Modifiers != want {
		return clipboardNone
	}
	switch {
	case strings.EqualFold(event.Text, "c"):
		return clipboardCopy
	case strings.EqualFold(event.Text, "v"):
		return clipboardPaste
	}
	return clipboardNone
}

// Key encodes a key the text system left to the application, and sends it to the shell. The
// second result is false for a key of another target. A named key arrives here; a printable
// character arrives as text (see terminalText), except while a program has negotiated the
// kitty keyboard protocol or win32-input-mode, when Viva delivers the whole keyboard as
// presses and releases.
func (v *View) Key(event ui.KeyEvent) (ui.EventResult, bool) {
	if event.Target != v.cfg.HitID {
		return ui.EventResult{}, false
	}
	handled := ui.EventResult{Handled: true}
	if action := clipboardChord(event); action != clipboardNone {
		// The window's shortcut hook normally takes the lettered chords first. The named
		// Insert keys never reach it, and a lettered chord it let through also ends here,
		// rather than reaching the program as a key it never asked for. The release of a
		// chord is swallowed with its press.
		if event.Release {
			return handled, true
		}
		if action == clipboardCopy {
			return v.copySelection(), true
		}
		v.paste()
		return ui.EventResult{Handled: true, Repaint: true}, true
	}
	modes := v.screen.Modes()
	flags := v.screen.KeyboardFlags()
	if v.preedit.Composing && event.Key == ui.KeyEnter && event.Modifiers == 0 && !modes.AltScreen {
		// The input method used this Enter to commit its composition, which the text
		// system reports on its own; sent as well, it would end the line the composition
		// went into.
		return handled, true
	}
	if event.Modifiers&ui.ModifierMeta != 0 && !event.Key.IsModifier() {
		if letter, ok := term.CommandLineEdit(event.Key, event.Modifiers); ok && runtime.GOOS == "darwin" {
			// Command+Left, Command+Right and Command+Backspace are the Mac's line edits.
			// They go on as the Control letters that shells and full-screen programs
			// understand without any setup.
			event.Key, event.Modifiers, event.Text, event.Typed = ui.KeyUnknown, ui.ModifierControl, letter, ""
		} else if flags == 0 {
			// A Command chord the window did not claim is still not the program's: it
			// never asked for a Super key. Once it negotiated kitty keyboard reports it
			// did, and the chord is forwarded below.
			return handled, true
		}
	}
	if v.shell == nil {
		// Nothing is listening: Enter starts the session again. Every other key is
		// swallowed, and the ended session has already said why on the screen.
		if event.Key == ui.KeyEnter && !event.Repeat && !event.Release && v.restart() {
			return ui.EventResult{Handled: true, Repaint: true}, true
		}
		return handled, true
	}
	if event.Modifiers&ui.ModifierShift != 0 && event.Modifiers&ui.ModifierMeta == 0 && !modes.AltScreen {
		// Shift with the page keys pages through the history, as every terminal does. The
		// alternate screen has none, so its program gets the keys.
		_, rows := v.screen.Size()
		lines := 0
		switch event.Key {
		case ui.KeyPageUp:
			lines = rows - 1
		case ui.KeyPageDown:
			lines = -(rows - 1)
		}
		if lines != 0 {
			if event.Release {
				return handled, true
			}
			return v.scrollView(lines), true
		}
	}
	var encoded []byte
	if modes.Win32Input {
		encoded = term.EncodeWin32Key(event)
	} else if runtime.GOOS == "darwin" && flags == 0 && !modes.AltScreen &&
		event.Modifiers == ui.ModifierAlt && !event.Release {
		// Match macOS Terminal's word movement when the shell owns the key. Alternate-screen
		// programs and negotiated keyboard modes keep their keys.
		//
		// This lives here on purpose: which bytes a Mac terminal sends for Option+arrow is
		// terminal behavior, layered on top of a shell that negotiated nothing, and not
		// something the key protocol defines. The modifiers must be exactly Alt, because
		// Shift+Option is macOS's "select a whole word", a different intent that the
		// default encoding serves.
		switch event.Key {
		case ui.KeyRight:
			encoded = []byte("\x1bf")
		case ui.KeyLeft:
			encoded = []byte("\x1bb")
		}
	}
	if len(encoded) == 0 {
		encoded = term.EncodeKeyEvent(event, flags, modes.AppCursorKeys)
	}
	if len(encoded) == 0 {
		return handled, true
	}
	// Sending returns the view to the live screen and drops the selection; a frame is only
	// needed when there was something to change.
	moved := v.screen.ViewOffset() > 0 || v.selection.selected
	handled.Repaint = v.sendInput(encoded) && moved
	return handled, true
}

// Shortcut handles the chords the terminal owns, copy and paste, before the text system
// sees them. The second result is false for everything else, which then goes on as text or
// as a key.
func (v *View) Shortcut(event ui.KeyEvent) (ui.EventResult, bool) {
	if event.Target != v.cfg.HitID || event.Release {
		return ui.EventResult{}, false
	}
	switch clipboardChord(event) {
	case clipboardCopy:
		return v.copySelection(), true
	case clipboardPaste:
		v.paste()
		return ui.EventResult{Handled: true, Repaint: true}, true
	}
	return ui.EventResult{}, false
}

// TextInput resolves the native text surface for the focused terminal: a preedit surface at
// the cursor cell, where input methods compose, and the receiver of typed text and pastes.
// It is nil for any other hit, so the text system leaves those alone. The returned value is
// reused, so resolving it each frame allocates nothing.
func (v *View) TextInput(ctx app.TextInputContext) *app.TextInput {
	if ctx.ID != v.cfg.HitID {
		return nil
	}
	cursor := v.screen.Cursor()
	cells := 1
	if v.preedit.Composing {
		cells += displayCells(v.preedit.Value)
	}
	v.input.Bounds = ui.Rect{
		X:     v.layout.left + float32(cursor.X)*v.cellW,
		Y:     v.layout.top + float32(cursor.Y)*v.cellH,
		Width: float32(cells) * v.cellW, Height: v.cellH,
	}
	v.input.FontSize = fontSize
	v.input.MonoFace = v.face
	v.input.Color = v.pal.termFG
	v.input.State = v.preedit
	// Option stays a composing key (it types accents and symbols on a Mac keyboard), so the
	// text system keeps it and the shell does not get Escape-prefixed Meta sequences.
	v.input.AltSendsEscape = false
	// A program that asked for kitty keyboard enhancements needs presses, releases and raw
	// printable keys, which Viva only delivers when the terminal asks for key releases.
	// win32-input-mode is the same on Windows.
	v.input.KeyReleases = v.screen.KeyboardFlags() != 0 || v.screen.Modes().Win32Input
	if v.input.OnEvent == nil {
		v.input.OnEvent = func(event app.TextEvent) (app.TextState, error) {
			return v.terminalText(event), nil
		}
	}
	return &v.input
}

// terminalText applies a text-system event to the terminal: typed text and pastes go to the
// shell, and an input method's composition is kept for the grid to draw over the cursor. It
// returns the state the surface mirrors.
func (v *View) terminalText(event app.TextEvent) app.TextState {
	// Typing returns the view to the live screen and drops the selection, which is a change
	// to paint although the text system sees none.
	moved := v.screen.ViewOffset() > 0 || v.selection.selected
	redraw := false
	switch event.Kind {
	case app.TextInsert:
		v.preedit = app.TextState{}
		redraw = v.sendInput([]byte(event.Text)) && moved
	case app.TextPaste:
		redraw = v.sendInput(term.EncodePaste(event.Text, v.screen.Modes().BracketedPaste)) && moved
	case app.TextPasteNoText:
		// A clipboard with no words in it is not an empty one: a program that reads
		// pictures from the clipboard itself waits for a paste with no content to do so, as
		// it gets from other terminals. Without bracketed paste an empty paste is no event
		// at all, and nothing is sent.
		redraw = v.sendInput(term.EncodePaste("", v.screen.Modes().BracketedPaste)) && moved
	case app.TextSetMarked:
		runes := utf8.RuneCountInString(event.Text)
		v.preedit = app.TextState{
			Value: event.Text, Selection: event.MarkedSelection,
			Composition: app.TextRange{End: runes}, Composing: runes > 0,
		}
	case app.TextUnmark:
		v.preedit = app.TextState{}
	}
	result := v.preedit
	result.Redraw = redraw
	return result
}

// copySelection hands the selected text to the clipboard. It is handled either way, so a
// copy chord with nothing selected is not sent on to the program.
func (v *View) copySelection() ui.EventResult {
	if !v.selection.selected {
		return ui.EventResult{Handled: true}
	}
	return ui.EventResult{Handled: true, ClipboardText: v.selection.text(v.screen)}
}

// paste sends the system clipboard to a live shell as a paste. A clipboard that cannot be
// read is skipped without a word: there is nothing to paste, and the keyboard shortcut is
// no place for a dialog.
func (v *View) paste() {
	if v.shell == nil {
		return
	}
	value, err := v.cfg.Clipboard()
	if err != nil {
		return
	}
	// An empty clipboard sends an empty paste under bracketed paste and nothing otherwise,
	// for the reason given at TextPasteNoText.
	v.sendInput(term.EncodePaste(value, v.screen.Modes().BracketedPaste))
}

// scrollView moves the view by lines, positive going back into history. It is handled even
// when the view does not move, so the key or press that asked is not taken for something
// else.
func (v *View) scrollView(lines int) ui.EventResult {
	if lines == 0 {
		return ui.EventResult{Handled: true}
	}
	return ui.EventResult{Handled: true, Repaint: v.screen.Scroll(lines)}
}

// Scroll turns the wheel into a program's mouse reports, into arrow keys on the alternate
// screen, where a pager or editor owns the display and has no history, and otherwise into
// scrolling of the history. The second result is false for an event of another target.
func (v *View) Scroll(event ui.ScrollEvent) (ui.EventResult, bool) {
	if event.Target != v.cfg.HitID && event.Target != v.cfg.BarID {
		return ui.EventResult{}, false
	}
	if v.cellW <= 0 || v.cellH <= 0 {
		return ui.EventResult{}, false
	}
	handled := ui.EventResult{Handled: true}
	modes := v.screen.Modes()
	// Shift hands the wheel back to the terminal. With no shell there is no program to
	// report to, and its modes may still be armed, so the wheel keeps working on the history.
	if modes.Mouse != term.MouseOff && v.shell != nil && event.Target == v.cfg.HitID &&
		event.Modifiers&ui.ModifierShift == 0 {
		return v.mouseScroll(event), true
	}
	if modes.AltScreen && (modes.Mouse != term.MouseOff || !modes.AlternateScroll) {
		return handled, true
	}
	// A small wheel step is not worth a line, so the distance is kept until it adds up to one.
	v.wheelY += event.StepY(v.cellH) / v.cellH
	lines := int(v.wheelY)
	if lines == 0 {
		return handled, true
	}
	v.wheelY -= float32(lines)
	// Positive deltas reveal content below, that is, newer output.
	if modes.AltScreen {
		key := ui.KeyDown
		if lines < 0 {
			key, lines = ui.KeyUp, -lines
		}
		for range min(lines, wheelStepLimit) {
			v.sendInput(term.EncodeKey(key, 0, "", modes.AppCursorKeys))
		}
		return handled, true
	}
	return v.scrollView(-lines), true
}

// mouseScroll reports the wheel to a program that asked for the mouse, as wheel presses at
// the cell under the pointer. The distance is kept in whole cells, as it is for the history,
// and the horizontal wheel is reported the same way.
func (v *View) mouseScroll(event ui.ScrollEvent) ui.EventResult {
	position := v.positionAt(event.X, event.Y)
	modifiers := terminalMouseModifiers(event.Modifiers)
	repaint := false
	report := func(button term.MouseEventButton, count int) {
		for range min(count, wheelStepLimit) {
			repaint = v.sendMouse(term.MouseEvent{
				Kind: term.MouseWheel, Button: button, Modifiers: modifiers,
				Column: position.Column, Row: position.Row,
			}) || repaint
		}
	}

	v.wheelY += event.StepY(v.cellH) / v.cellH
	vertical := int(v.wheelY)
	v.wheelY -= float32(vertical)
	button := term.MouseWheelDown
	if vertical < 0 {
		button, vertical = term.MouseWheelUp, -vertical
	}
	report(button, vertical)

	v.wheelX += event.StepX(v.cellW) / v.cellW
	horizontal := int(v.wheelX)
	v.wheelX -= float32(horizontal)
	button = term.MouseWheelRight
	if horizontal < 0 {
		button, horizontal = term.MouseWheelLeft, -horizontal
	}
	report(button, horizontal)
	return ui.EventResult{Handled: true, Repaint: repaint}
}
