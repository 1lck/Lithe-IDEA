package term

import "testing"

// A program that enables its own input modes and is then killed cannot restore
// them: on Windows a Ctrl+C that ends the process raises no teardown, and a
// pager handed the terminal never knew about the modes the TUI armed. The
// shell's next prompt proves the program is gone, so the modes it armed there
// must not survive into the prompt that the user then types at.
func TestShellPromptReclaimsTheModesAKilledProgramLeft(t *testing.T) {
	term := newTerm(40, 10)
	term.SetPromptToken("tok")
	// The first prompt, then a command that arms a full-screen TUI's modes.
	term.Write([]byte("\x1b]133;A;motty=tok\a$ \x1b]133;B;motty=tok\a"))
	term.Write([]byte("\x1b]133;C;motty=tok\a"))
	term.Write([]byte("\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?1h\x1b[?2004h\x1b[?25l"))
	term.Write([]byte("\x1b[>1u")) // the kitty keyboard protocol, as Bubble Tea asks for it
	if modes := term.Modes(); modes.Mouse != MouseAny || !modes.AltScreen {
		t.Fatalf("the program's modes were not taken: %+v", modes)
	}
	// The program is killed; the shell reports the command as finished and
	// draws its next prompt itself.
	term.Write([]byte("\x1b]133;D;130;motty=tok\a\x1b]133;A;motty=tok\a$ \x1b]133;B;motty=tok\a"))

	modes := term.Modes()
	if modes.AltScreen {
		t.Error("the alternate screen outlived the program that entered it")
	}
	if modes.Mouse != MouseOff {
		t.Errorf("mouse reporting is still armed: %v", modes.Mouse)
	}
	if modes.MouseEncoding != MouseEncodingX10 {
		t.Errorf("mouse encoding was left as %v", modes.MouseEncoding)
	}
	if modes.FocusReporting {
		t.Error("focus reporting outlived the program that asked for it")
	}
	if modes.AppCursorKeys {
		t.Error("application cursor keys outlived the program that asked for them")
	}
	if !modes.CursorVisible {
		t.Error("the cursor stayed hidden after the program that hid it")
	}
	if term.KeyboardFlags() != 0 {
		t.Errorf("kitty keyboard flags were left at %#x", term.KeyboardFlags())
	}
	// Bracketed paste belongs to the line editor that re-arms it for every
	// prompt, and it never garbles a keystroke, so reclaiming must not fight it.
	if !modes.BracketedPaste {
		t.Error("reclaiming dropped the shell's own bracketed paste")
	}
}

// Only this shell's own integration proves the prompt is the user's. A marker a
// program echoed, or a marker from a nested login, says nothing about who owns
// the terminal now.
func TestAForeignPromptMarkerLeavesTheModesAlone(t *testing.T) {
	term := newTerm(40, 10)
	term.SetPromptToken("tok")
	term.Write([]byte("\x1b]133;A;motty=tok\a$ \x1b]133;B;motty=tok\a\x1b]133;C;motty=tok\a"))
	term.Write([]byte("\x1b[?1049h\x1b[?1003h\x1b[?1006h"))
	term.Write([]byte("\x1b]133;D;0;motty=other\a\x1b]133;A;motty=other\a\x1b]133;B;motty=other\a"))

	modes := term.Modes()
	if !modes.AltScreen || modes.Mouse != MouseAny {
		t.Fatalf("a foreign marker reclaimed the modes a live program may own: %+v", modes)
	}
}
