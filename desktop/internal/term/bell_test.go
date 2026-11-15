package term

import "testing"

func TestBellRingsForBELButNotForTheByteThatEndsAString(t *testing.T) {
	screen := New(40, 5, 10)
	rings := 0
	screen.SetBell(func() { rings++ })

	screen.Write([]byte("a\ab\a"))
	if rings != 2 {
		t.Fatalf("two BEL bytes rang %d times", rings)
	}

	// BEL ends an OSC string (a title, a hyperlink, a prompt marker) and is
	// not a bell there; inside an escape sequence it still is one.
	screen.Write([]byte("\x1b]0;title\a\x1b]133;A\a\x1b]8;;https://example.test\a"))
	if rings != 2 {
		t.Fatalf("the terminator of an OSC string rang: %d", rings)
	}
	screen.Write([]byte("\x1b[3\a1m"))
	if rings != 3 {
		t.Fatalf("a BEL inside a CSI sequence rang %d times in total", rings)
	}
}

func TestBellIsIgnoredWithoutAReceiver(t *testing.T) {
	screen := New(40, 5, 10)
	screen.Write([]byte("\a\a"))
	if got := screen.RowText(0); got != "" {
		t.Fatalf("BEL left %q on the screen", got)
	}
}
