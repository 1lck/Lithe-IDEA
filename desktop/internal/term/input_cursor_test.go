package term

import "testing"

const inputMarkA, inputMarkB, inputMarkC = "\x1b]133;A;motty=t\a", "\x1b]133;B;motty=t\a", "\x1b]133;C;motty=t\a"

func promptTerminal(cols int, typed string) *Terminal {
	t := New(cols, 6, 100)
	t.SetPromptToken("t")
	t.Write([]byte(inputMarkA + "$ " + inputMarkB + typed))
	return t
}

func TestInputMoveWithinLine(t *testing.T) {
	term := promptTerminal(40, "echo hello") // cursor at column 12
	for _, tc := range []struct {
		column, want int
	}{{2, -10}, {7, -5}, {12, 0}} {
		got, ok := term.InputMove(Position{Row: 0, Column: tc.column})
		if !ok || got != tc.want {
			t.Errorf("column %d: got %d, %v; want %d", tc.column, got, ok, tc.want)
		}
	}
	// Left of the input start is the prompt, and the shell cannot go there.
	if _, ok := term.InputMove(Position{Row: 0, Column: 1}); ok {
		t.Error("a click on the prompt moved the cursor")
	}
	// Cursor in the middle of the text: clicks right of it move right, and a
	// click past the text means its end.
	term.Write([]byte("\x1b[5D")) // cursor at column 7
	if got, ok := term.InputMove(Position{Row: 0, Column: 10}); !ok || got != 3 {
		t.Errorf("right: got %d, %v; want 3", got, ok)
	}
	if got, ok := term.InputMove(Position{Row: 0, Column: 39}); !ok || got != 5 {
		t.Errorf("past end: got %d, %v; want 5", got, ok)
	}
}

func TestInputMoveCountsWideCharactersOnce(t *testing.T) {
	term := promptTerminal(40, "a你好b") // columns: a=2, 你=3-4, 好=5-6, b=7; cursor at 8
	for _, tc := range []struct {
		column, want int
	}{{7, -1}, {5, -2}, {4, -3}, {3, -3}, {2, -4}} {
		got, ok := term.InputMove(Position{Row: 0, Column: tc.column})
		if !ok || got != tc.want {
			t.Errorf("column %d: got %d, %v; want %d", tc.column, got, ok, tc.want)
		}
	}
}

func TestInputMoveAcrossSoftWrap(t *testing.T) {
	term := promptTerminal(10, "abcdefghijklmno") // "$ " + 15 letters over rows 0-1, cursor at row 1 column 7
	if got, ok := term.InputMove(Position{Row: 0, Column: 4}); !ok || got != -13 {
		t.Errorf("up a row: got %d, %v; want -13", got, ok)
	}
	if got, ok := term.InputMove(Position{Row: 1, Column: 2}); !ok || got != -5 {
		t.Errorf("same row: got %d, %v; want -5", got, ok)
	}
	term.Write([]byte("\x1b[A\x1b[5D")) // cursor at row 0, column 2 (the input start)
	if got, ok := term.InputMove(Position{Row: 1, Column: 3}); !ok || got != 11 {
		t.Errorf("down a row: got %d, %v; want 11", got, ok)
	}
}

func TestInputMoveRefusesWhatItCannotPlace(t *testing.T) {
	click := Position{Row: 0, Column: 4}
	// A line that ends with a hard newline is not one editable line.
	term := promptTerminal(40, "echo \\\r\n> more")
	if _, ok := term.InputMove(click); ok {
		t.Error("moved across a hard line break")
	}
	// A command is running.
	term = promptTerminal(40, "sleep 9")
	term.Write([]byte(inputMarkC))
	if _, ok := term.InputMove(click); ok {
		t.Error("moved while a command runs")
	}
	// A prompt drawn again is a new one.
	term.Write([]byte(inputMarkA))
	if _, ok := term.InputMove(click); ok {
		t.Error("moved before the next prompt ended")
	}
	// The full-screen program's screen is not the shell's line.
	term = promptTerminal(40, "vim")
	term.Write([]byte("\x1b[?1049h"))
	if _, ok := term.InputMove(click); ok {
		t.Error("moved on the alternate screen")
	}
	// Markers without this shell's token, such as ones a program printed.
	term = New(40, 6, 100)
	term.Write([]byte("\x1b]133;A\a$ \x1b]133;B\ahello"))
	if _, ok := term.InputMove(click); ok {
		t.Error("moved on a prompt nobody vouched for")
	}
	// Reflow moves the line.
	term = promptTerminal(40, "echo hello")
	term.Resize(20, 6)
	if _, ok := term.InputMove(click); ok {
		t.Error("moved after a resize")
	}
}
