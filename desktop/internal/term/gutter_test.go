package term

import "testing"

func TestLinesKeepTheirWriteTimeIntoScrollback(t *testing.T) {
	screen := New(10, 3, 100)
	now := int64(0)
	screen.SetClock(func() int64 { return now })

	for i, text := range []string{"one\r\n", "two\r\n", "three\r\n", "four\r\n", "five"} {
		now = int64(100 + i)
		screen.Write([]byte(text))
	}
	// "one" and "two" scrolled off; the view shows three, four, five.
	if screen.Scrollback() != 2 {
		t.Fatalf("scrollback = %d, want 2", screen.Scrollback())
	}
	if got := screen.Row(0).Written; got != 102 {
		t.Fatalf("row 0 written = %d, want 102", got)
	}
	screen.Scroll(2)
	for i, want := range []int64{100, 101, 102} {
		if got := screen.Row(i).Written; got != want {
			t.Fatalf("history view row %d written = %d, want %d (%q)", i, got, want, screen.RowText(i))
		}
		if got := screen.LineNumber(i); got != uint64(i+1) {
			t.Fatalf("row %d number = %d, want %d", i, got, i+1)
		}
	}
}

func TestLineNumbersSurviveDroppedHistory(t *testing.T) {
	screen := New(10, 3, 2)
	for range 20 {
		screen.Write([]byte("x\r\n"))
	}
	// 20 lines were written, the screen holds the last 2 plus the blank cursor row.
	if got := screen.LineNumber(2); got != 21 {
		t.Fatalf("cursor row number = %d, want 21", got)
	}
	screen.Scroll(2)
	if got := screen.LineNumber(0); got != 17 {
		t.Fatalf("oldest retained line number = %d, want 17", got)
	}
}

func TestNoClockRecordsNothing(t *testing.T) {
	screen := New(10, 3, 10)
	screen.Write([]byte("hello\r\n"))
	if got := screen.Row(0).Written; got != 0 {
		t.Fatalf("written = %d without a clock", got)
	}
}
