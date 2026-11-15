package term

// ReclaimApplicationModes puts the terminal back in the state a shell prompt
// expects. A program arms modes for itself and restores them on the way out;
// one that never got to run its teardown (a Ctrl+C that ends it, a pager handed
// the terminal while the TUI behind it had already asked for mouse reports)
// leaves them armed. The screen then keeps reporting the mouse into the shell's
// line editor and keeps sending the wheel as arrow keys, so the prompt itself
// is unusable until the terminal is reset by hand.
//
// Two things prove that no program owns the terminal any more. The shell
// drawing its own prompt is one: it is the moment the modes belong to nobody.
// A shell that has just started is the other, and the stronger one, because a
// new process never asked for any of them; that is the proof Motty has when a
// connection drops and the program's teardown goes down with it. Bracketed
// paste is left alone, because the line editor arms it for every prompt and it
// never garbles a keystroke.
func (t *Terminal) ReclaimApplicationModes() {
	if t.onAlt {
		// Leave the buffer the program entered. A 1049 program saved the main
		// screen's cursor on the way in; without one the cursor stays where the
		// prompt would have been drawn, rather than jumping to the top corner.
		t.leaveAlt(false)
		if t.scr.saved.valid {
			t.restoreCursor()
		} else {
			t.cx, t.cy = min(t.cx, t.cols-1), min(t.cy, t.rows-1)
			t.pend = false
		}
	}
	t.view = 0
	// A synchronized update left open would hold the presentation forever.
	t.setSync(false)
	// Insert, origin, application cursor keys and the keypad, margins, pen and
	// cursor shape are the DECSTR set: a new prompt starts from these.
	t.softReset()
	t.modes.Mouse, t.modes.MouseEncoding = MouseOff, MouseEncodingX10
	t.modes.FocusReporting, t.modes.Win32Input, t.modes.ReverseVideo = false, false, false
	t.modes.AlternateScroll = true
	t.modes.Newline = false
	// Every keystroke reaches the shell as a kitty report while the flags are
	// set, and the stack would replay a program's negotiation on the next push.
	t.ResetKeyboard()
	t.version++
}
