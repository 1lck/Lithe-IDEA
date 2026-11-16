package termview

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// newInputRig is a font rig whose shell ran a command and waits at its prompt, "$ ", with
// "hello" typed: the cursor is at column 7 of the first row.
func newInputRig(t *testing.T) *fontRig {
	t.Helper()
	rig := newFontRig(t)
	rig.view.screen.SetPromptToken("t")
	output(rig.view, &rig.shell.fakeShell, promptMarks+"hello")
	return rig
}

// clickCell presses and releases the primary button on a cell, with modifiers held.
func clickCell(rig *fontRig, row, column int, modifiers gfx.Modifiers) {
	blockGesture(rig, modifiers, [2]int{row, column})
}

// An Option-click on the line being typed sends the cursor keys that take the shell's
// cursor there, in the encoding the screen asks for.
func TestOptionClickMovesTheShellCursorWithinTheInputLine(t *testing.T) {
	rig := newInputRig(t)
	clickCell(rig, 0, 3, gfx.ModifierAlt)
	left := strings.Repeat("\x1b[D", 4)
	if got := string(rig.shell.input); got != left {
		t.Fatalf("a click to the left sent %q, want %q", got, left)
	}
	// The cursor followed; a program asked for application cursor keys.
	output(rig.view, &rig.shell.fakeShell, "\x1b[4D\x1b[?1h")
	clickCell(rig, 0, 5, gfx.ModifierAlt)
	if got, want := string(rig.shell.input), left+"\x1bOC\x1bOC"; got != want {
		t.Fatalf("a click to the right sent %q, want %q", got, want)
	}
}

// A plain click moves the cursor too, but a press that drags selects and sends nothing.
func TestPlainClickMovesTheCursorButADragDoesNot(t *testing.T) {
	rig := newInputRig(t)
	clickCell(rig, 0, 5, 0)
	if got, want := string(rig.shell.input), "\x1b[D\x1b[D"; got != want {
		t.Fatalf("a click sent %q, want %q", got, want)
	}
	blockGesture(rig, 0, [2]int{0, 2}, [2]int{0, 6})
	if got := string(rig.shell.input); got != "\x1b[D\x1b[D" {
		t.Fatalf("a drag sent keys: %q", got)
	}
	if !rig.view.HasSelection() {
		t.Fatal("the drag selected nothing")
	}
}

// Output still on its way counts: the move is measured from where it leaves the cursor.
func TestAClickMeasuresFromTheCursorThePendingOutputLeaves(t *testing.T) {
	rig := newInputRig(t)
	rig.shell.output = []byte("\x1b[2D") // the echo of two Left keys, not parsed yet
	clickCell(rig, 0, 3, 0)
	if got, want := string(rig.shell.input), "\x1b[D\x1b[D"; got != want {
		t.Fatalf("the click sent %q, want %q from column 5", got, want)
	}
}

// A click sends nothing where the cursor cannot be placed: with other modifiers, on the
// prompt or off the line being typed, while a command or a full-screen program runs, and
// in a shell that does not mark its commands.
func TestAClickLeavesTheKeyboardAloneWhereItCannotPlaceTheCursor(t *testing.T) {
	rig := newInputRig(t)
	clickCell(rig, 0, 3, gfx.ModifierAlt|gfx.ModifierShift)
	clickCell(rig, 0, 3, gfx.ModifierControl)
	clickCell(rig, 0, 0, gfx.ModifierAlt) // the prompt
	clickCell(rig, 1, 3, gfx.ModifierAlt) // below the input
	if got := string(rig.shell.input); got != "" {
		t.Fatalf("the clicks sent %q", got)
	}
	output(rig.view, &rig.shell.fakeShell, "\x1b]133;C;motty=t\a") // a command runs
	clickCell(rig, 0, 3, 0)
	output(rig.view, &rig.shell.fakeShell, "\x1b]133;D;0;motty=t\a\x1b]133;A;motty=t\a$ \x1b]133;B;motty=t\ahi\x1b[?1049h")
	clickCell(rig, 0, 3, 0) // on the alternate screen
	if got := string(rig.shell.input); got != "" {
		t.Fatalf("the clicks sent %q", got)
	}

	// PowerShell and cmd mark their prompt but not their commands, so a program they run
	// could be what reads the keys.
	rig = newFontRig(t)
	rig.view.screen.SetPromptToken("t")
	output(rig.view, &rig.shell.fakeShell, "\x1b]133;A;motty=t\aPS> \x1b]133;B;motty=t\ahello")
	clickCell(rig, 0, 5, 0)
	if got := string(rig.shell.input); got != "" {
		t.Fatalf("a click in a shell without command marks sent %q", got)
	}
}
