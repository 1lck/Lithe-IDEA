package term

import "testing"

// The user's default shape is the cursor's until a program asks for its own, and comes back
// when the program asks for the default with DECSCUSR 0 or resets the terminal.
func TestDefaultCursorShapeYieldsToProgramsAndComesBack(t *testing.T) {
	screen := New(20, 4, 0)
	if got := screen.Cursor().Style; got != CursorBlock {
		t.Fatalf("a new terminal's cursor = %v, want the block", got)
	}
	screen.SetDefaultCursor(CursorBar)
	if got := screen.Cursor().Style; got != CursorBar {
		t.Fatalf("after a bar default the cursor = %v, want the bar", got)
	}

	screen.Write([]byte("\x1b[2 q"))
	if got := screen.Cursor().Style; got != CursorBlock {
		t.Fatalf("after a program asked for a steady block the cursor = %v", got)
	}
	screen.SetDefaultCursor(CursorUnderline)
	if got := screen.Cursor().Style; got != CursorBlock {
		t.Fatalf("a new default replaced the shape a program asked for: %v", got)
	}

	screen.Write([]byte("\x1b[0 q"))
	if got := screen.Cursor().Style; got != CursorUnderline {
		t.Fatalf("DECSCUSR 0 gave %v, want the user's underline", got)
	}
	screen.SetDefaultCursor(CursorBar)
	if got := screen.Cursor().Style; got != CursorBar {
		t.Fatalf("after DECSCUSR 0 the default no longer applies: %v", got)
	}

	screen.Write([]byte("\x1b[3 q\x1bc"))
	if got := screen.Cursor().Style; got != CursorBar {
		t.Fatalf("after a reset the cursor = %v, want the user's bar", got)
	}
}
