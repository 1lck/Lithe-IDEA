package term

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func newTerm(cols, rows int) *Terminal { return New(cols, rows, 100) }

func feed(t *Terminal, s string) { t.Write([]byte(s)) }

func expectText(t *testing.T, term *Terminal, want string) {
	t.Helper()
	if got := term.Text(); got != want {
		t.Fatalf("screen =\n%s\nwant\n%s", visible(got), visible(want))
	}
}

func visible(s string) string { return strings.ReplaceAll(s, " ", "·") }

func expectCursor(t *testing.T, term *Terminal, x, y int) {
	t.Helper()
	if c := term.Cursor(); c.X != x || c.Y != y {
		t.Fatalf("cursor = (%d,%d), want (%d,%d)", c.X, c.Y, x, y)
	}
}

func cellAt(term *Terminal, x, y int) Cell { return term.Row(y).Cells[x] }

func TestPrintsTextAndHonorsLineFeeds(t *testing.T) {
	term := newTerm(10, 4)
	feed(term, "hello\r\nworld")
	expectText(t, term, "hello\nworld")
	expectCursor(t, term, 5, 1)

	// A bare line feed moves down without returning the carriage.
	feed(term, "\nab")
	expectText(t, term, "hello\nworld\n     ab")
}

func TestAutowrapIsDelayedUntilTheNextCharacter(t *testing.T) {
	term := newTerm(5, 3)
	feed(term, "abcde")
	expectCursor(t, term, 4, 0)
	feed(term, "\r\nxy")
	// Filling the row and then breaking the line must not leave a blank row.
	expectText(t, term, "abcde\nxy")

	term = newTerm(5, 3)
	feed(term, "abcdefg")
	expectText(t, term, "abcde\nfg")
	if !term.Row(0).Wrapped || term.Row(1).Wrapped {
		t.Errorf("wrapped flags = %v %v, want true false", term.Row(0).Wrapped, term.Row(1).Wrapped)
	}

	term = newTerm(5, 3)
	feed(term, "\x1b[?7labcdefg")
	expectText(t, term, "abcdg")
	feed(term, "\x1b[?7h")
	if !term.Modes().Autowrap {
		t.Error("DECAWM did not turn back on")
	}
}

func TestCursorMovement(t *testing.T) {
	term := newTerm(10, 5)
	feed(term, "\x1b[3;4H")
	expectCursor(t, term, 3, 2)
	feed(term, "\x1b[2A\x1b[3C")
	expectCursor(t, term, 6, 0)
	feed(term, "\x1b[99B\x1b[99D")
	expectCursor(t, term, 0, 4)
	feed(term, "\x1b[H")
	expectCursor(t, term, 0, 0)
	feed(term, "\x1b[;5H")
	expectCursor(t, term, 4, 0)
	feed(term, "\x1b[3d")
	expectCursor(t, term, 4, 2)
	feed(term, "\x1b[7G")
	expectCursor(t, term, 6, 2)
	feed(term, "\x1b[2E")
	expectCursor(t, term, 0, 4)
	feed(term, "\x1b[3F")
	expectCursor(t, term, 0, 1)
	feed(term, "\x1b[0A") // 0 counts as 1
	expectCursor(t, term, 0, 0)
}

func TestSaveAndRestoreCursor(t *testing.T) {
	term := newTerm(10, 5)
	feed(term, "\x1b[3;4H\x1b[31m\x1b7\x1b[H\x1b[0mx\x1b8y")
	expectCursor(t, term, 4, 2)
	if c := cellAt(term, 3, 2); c.R != 'y' || c.FG != Indexed(1) {
		t.Errorf("cell after restore = %+v, want red y", c)
	}
	feed(term, "\x1b[1;1H\x1b[s\x1b[5;5H\x1b[u")
	expectCursor(t, term, 0, 0)
}

func TestEraseInLineAndDisplay(t *testing.T) {
	term := newTerm(6, 3)
	feed(term, "aaaaaa\r\nbbbbbb\r\ncccccc")
	feed(term, "\x1b[2;3H\x1b[K")
	expectText(t, term, "aaaaaa\nbb\ncccccc")
	feed(term, "\x1b[2;2H\x1b[1K")
	expectText(t, term, "aaaaaa\n\ncccccc")
	feed(term, "\x1b[2;3H\x1b[J")
	expectText(t, term, "aaaaaa")
	feed(term, "\x1b[2;1Hxy\x1b[1;3H\x1b[1J")
	expectText(t, term, "   aaa\nxy")
	feed(term, "\x1b[2J")
	expectText(t, term, "")
}

func TestErasePaintsTheCurrentBackground(t *testing.T) {
	term := newTerm(6, 2)
	feed(term, "\x1b[44m\x1b[2K")
	if c := cellAt(term, 3, 0); c.BG != Indexed(4) || c.R != 0 {
		t.Errorf("erased cell = %+v, want an empty blue cell", c)
	}
	feed(term, "\x1b[0m\x1b[2J")
	if c := cellAt(term, 3, 0); c.BG != 0 {
		t.Errorf("erase with the default pen left %+v", c)
	}
}

func TestInsertAndDeleteCharacters(t *testing.T) {
	term := newTerm(8, 2)
	feed(term, "abcdefgh\x1b[1;3H\x1b[2@")
	expectText(t, term, "ab  cdef")
	feed(term, "\x1b[2P")
	expectText(t, term, "abcdef")
	feed(term, "\x1b[3X")
	expectText(t, term, "ab   f")
	feed(term, "\x1b[4h\x1b[1;1HXY\x1b[4l")
	expectText(t, term, "XYab   f")
}

func TestRepeatCharacter(t *testing.T) {
	term := newTerm(10, 2)
	feed(term, "a\x1b[4b")
	expectText(t, term, "aaaaa")
	feed(term, "\x1b[2J\x1b[Hz\x1b[2b")
	expectText(t, term, "zzz")
}

func TestScrollbackCollectsLinesThatLeaveTheTop(t *testing.T) {
	term := newTerm(6, 3)
	for i := 1; i <= 5; i++ {
		feed(term, fmt.Sprintf("line%d\r\n", i))
	}
	// Five lines of output plus the cursor row on a 3-row screen.
	expectText(t, term, "line4\nline5")
	if got := term.Scrollback(); got != 3 {
		t.Fatalf("scrollback = %d, want 3", got)
	}
	term.Scroll(10) // clamps to the history
	if term.ViewOffset() != 3 {
		t.Fatalf("view offset = %d, want 3", term.ViewOffset())
	}
	expectText(t, term, "line1\nline2\nline3")
	if term.Cursor().Visible {
		t.Error("the cursor shows while the view is scrolled past it")
	}
	term.ScrollToBottom()
	expectText(t, term, "line4\nline5")
	if !term.Cursor().Visible {
		t.Error("the cursor disappeared after returning to the bottom")
	}
}

func TestClearScreenKeepsThePromptLineAndDropsEverythingAboveIt(t *testing.T) {
	terminal := New(16, 4, 20)
	for i := 0; i < 8; i++ {
		feed(terminal, fmt.Sprintf("old%d\r\n", i))
	}
	feed(terminal, "prompt$ ls -l")
	if terminal.Scrollback() == 0 {
		t.Fatal("the test needs history to clear")
	}
	terminal.Scroll(2)
	if !terminal.ClearScreen() {
		t.Fatal("ClearScreen refused the main screen")
	}
	if terminal.Scrollback() != 0 || terminal.ViewOffset() != 0 {
		t.Fatalf("history = %d, view = %d after a clear", terminal.Scrollback(), terminal.ViewOffset())
	}
	if got, want := terminal.RowText(0), "prompt$ ls -l"; got != want {
		t.Fatalf("first row = %q, want the cursor's line %q", got, want)
	}
	for row := 1; row < 4; row++ {
		if got := terminal.RowText(row); got != "" {
			t.Fatalf("row %d = %q, want it cleared", row, got)
		}
	}
	cursor := terminal.Cursor()
	if cursor.X != len("prompt$ ls -l") || cursor.Y != 0 || !cursor.Visible {
		t.Fatalf("cursor = %+v, want column %d of the first row", cursor, len("prompt$ ls -l"))
	}
	// The shell keeps writing where it was: its next prompt lands under the one
	// it left, on the row after it rather than on a cleared screen's top.
	feed(terminal, "\r\nnext")
	if got, want := terminal.RowText(1), "next"; got != want {
		t.Fatalf("row after the prompt = %q, want %q", got, want)
	}
}

func TestClearScreenLeavesTheAlternateScreenToItsProgram(t *testing.T) {
	terminal := New(30, 3, 20)
	feed(terminal, "kept on the main screen\r\n")
	feed(terminal, "\x1b[?1049h\x1b[Hfull screen")
	before := terminal.Text()
	if terminal.ClearScreen() {
		t.Fatal("ClearScreen cleared the screen of a full-screen program")
	}
	if got := terminal.Text(); got != before {
		t.Fatalf("alternate screen = %q, want it untouched: %q", got, before)
	}
	feed(terminal, "\x1b[?1049l")
	if got := terminal.RowText(0); !strings.Contains(got, "kept on the main screen") {
		t.Fatalf("main screen = %q after leaving the alternate one", got)
	}
}

func TestAppendRetainedTextIncludesHistoryAndJoinsSoftWraps(t *testing.T) {
	terminal := New(5, 2, 8)
	terminal.Write([]byte("first\r\nwide界\r\ne\u0301nd"))

	got := string(terminal.AppendRetainedText([]byte("prefix:")))
	if want := "prefix:first\nwide界\nénd"; got != want {
		t.Fatalf("retained text = %q, want %q", got, want)
	}

	terminal = New(4, 2, 0)
	terminal.Write([]byte("abcdef"))
	if got, want := string(terminal.AppendRetainedText(nil)), "abcdef"; got != want {
		t.Fatalf("soft-wrapped retained text = %q, want %q", got, want)
	}
}

func TestAppendRetainedTextDoesNotExportConcealedCells(t *testing.T) {
	terminal := New(12, 2, 0)
	terminal.Write([]byte("shown \x1b[8msecret\x1b[0m"))
	if got, want := string(terminal.AppendRetainedText(nil)), "shown"; got != want {
		t.Fatalf("concealed retained text = %q, want %q", got, want)
	}
}

func TestViewStaysPutWhileOutputArrives(t *testing.T) {
	term := newTerm(6, 3)
	for i := 1; i <= 6; i++ {
		feed(term, fmt.Sprintf("l%d\r\n", i))
	}
	term.Scroll(2)
	before := term.Text()
	feed(term, "l7\r\nl8\r\n")
	if term.Text() != before {
		t.Fatalf("scrolled-back view moved:\n%s\nwant\n%s", term.Text(), before)
	}
}

func TestScrollbackIsBounded(t *testing.T) {
	term := New(8, 3, 4)
	for i := 0; i < 50; i++ {
		feed(term, fmt.Sprintf("n%d\r\n", i))
	}
	if term.Scrollback() != 4 {
		t.Fatalf("scrollback = %d, want 4", term.Scrollback())
	}
	term.Scroll(100)
	expectText(t, term, "n44\nn45\nn46")
}

func TestScrollbackKeepsAttributesAndTrimsBlanks(t *testing.T) {
	term := newTerm(10, 2)
	feed(term, "\x1b[31mred\x1b[0m\r\n\r\n\r\n")
	if term.Scrollback() == 0 {
		t.Fatal("nothing scrolled off")
	}
	term.Scroll(term.Scrollback())
	row := term.Row(0)
	if len(row.Cells) != 3 || row.Cells[0].FG != Indexed(1) {
		t.Fatalf("history row = %+v, want three red cells", row.Cells)
	}
}

func TestLinesKeepTheirIdentityWhileScrolling(t *testing.T) {
	term := newTerm(6, 3)
	feed(term, "a\r\nb\r\nc")
	idB, versionB := term.Row(1).ID, term.Row(1).Version
	feed(term, "\r\nd") // scrolls: b is now row 0
	if got := term.Row(0); got.ID != idB || got.Version != versionB {
		t.Fatalf("b changed identity while scrolling: %d/%d, want %d/%d", got.ID, got.Version, idB, versionB)
	}
	feed(term, "\x1b[1;2Hz")
	if got := term.Row(0); got.ID != idB || got.Version == versionB {
		t.Fatalf("editing b kept its version %d", got.Version)
	}
}

func TestScrollRegion(t *testing.T) {
	term := newTerm(4, 5)
	feed(term, "1\r\n2\r\n3\r\n4\r\n5")
	feed(term, "\x1b[2;4r") // rows 2-4; the cursor goes home
	expectCursor(t, term, 0, 0)
	feed(term, "\x1b[4;1H\n")
	expectText(t, term, "1\n3\n4\n\n5")
	if term.Scrollback() != 0 {
		t.Error("a partial region pushed a line into the history")
	}
	feed(term, "\x1b[2;1H\x1bM") // reverse index at the top margin scrolls down
	expectText(t, term, "1\n\n3\n4\n5")
	feed(term, "\x1b[r")
	expectCursor(t, term, 0, 0)
}

func TestInsertAndDeleteLines(t *testing.T) {
	term := newTerm(4, 5)
	feed(term, "1\r\n2\r\n3\r\n4\r\n5\x1b[2;1H\x1b[2L")
	expectText(t, term, "1\n\n\n2\n3")
	feed(term, "\x1b[1M")
	expectText(t, term, "1\n\n2\n3")
	feed(term, "\x1b[2S")
	expectText(t, term, "2\n3")
	feed(term, "\x1b[1T")
	expectText(t, term, "\n2\n3")
}

func TestOriginModeIsRelativeToTheMargins(t *testing.T) {
	term := newTerm(6, 6)
	feed(term, "\x1b[3;5r\x1b[?6h\x1b[1;1Hx")
	if term.Row(2).Cells[0].R != 'x' {
		t.Fatalf("origin-mode home landed elsewhere: %q", term.Text())
	}
	feed(term, "\x1b[9;1Hy")
	if term.Row(4).Cells[0].R != 'y' {
		t.Fatalf("origin-mode row was not clamped to the region: %q", term.Text())
	}
}

func TestAlternateScreenRestoresTheMainScreen(t *testing.T) {
	term := newTerm(12, 3)
	feed(term, "shell$ ls\r\nfile")
	feed(term, "\x1b[?1049h")
	if !term.Modes().AltScreen {
		t.Fatal("alternate screen not entered")
	}
	expectText(t, term, "")
	feed(term, "\x1b[1;1Hvim\x1b[3;1H~")
	expectText(t, term, "vim\n\n~")
	feed(term, "\x1b[?1049l")
	expectText(t, term, "shell$ ls\nfile")
	expectCursor(t, term, 4, 1)
	// The next visit starts blank again.
	feed(term, "\x1b[?1049h")
	expectText(t, term, "")
	if term.Scrollback() != 0 {
		t.Error("the alternate screen produced history")
	}
}

func TestSGRColorsAndAttributes(t *testing.T) {
	term := newTerm(40, 2)
	feed(term, "\x1b[1;3;4;7;9mA\x1b[22;23;24;27;29mB")
	a, b := cellAt(term, 0, 0), cellAt(term, 1, 0)
	if a.Attr != Bold|Italic|Underline|Inverse|Strike {
		t.Errorf("A attr = %b", a.Attr)
	}
	if b.Attr != 0 {
		t.Errorf("B attr = %b, want none", b.Attr)
	}

	for _, test := range []struct {
		seq      string
		fg, bg   Color
		describe string
	}{
		{"\x1b[31;42m", Indexed(1), Indexed(2), "ansi"},
		{"\x1b[91;102m", Indexed(9), Indexed(10), "bright"},
		{"\x1b[38;5;200;48;5;17m", Indexed(200), Indexed(17), "256 semicolon"},
		{"\x1b[38:5:99m", Indexed(99), 0, "256 colon"},
		{"\x1b[38;2;10;20;30;48;2;1;2;3m", RGB(10, 20, 30), RGB(1, 2, 3), "truecolor semicolon"},
		{"\x1b[38:2::10:20:30m", RGB(10, 20, 30), 0, "truecolor colon with colorspace"},
		{"\x1b[38:2:10:20:30m", RGB(10, 20, 30), 0, "truecolor colon without colorspace"},
		{"\x1b[1;38;2;1;2;3m", RGB(1, 2, 3), 0, "color after an attribute"},
		{"\x1b[38;5m", 0, 0, "truncated color"},
		{"\x1b[38;2;999;0;0m", RGB(255, 0, 0), 0, "components are clamped"},
		{"\x1b[31;49;39m", 0, 0, "defaults"},
	} {
		term.Reset()
		feed(term, test.seq+"Z")
		if c := cellAt(term, 0, 0); c.R != 'Z' || c.FG != test.fg || c.BG != test.bg {
			t.Errorf("%s: cell = %+v, want fg %v bg %v", test.describe, c, test.fg, test.bg)
		}
	}

	term.Reset()
	feed(term, "\x1b[4:3mU\x1b[4:0mN\x1b[58;2;1;2;3mC")
	if cellAt(term, 0, 0).Attr&Underline == 0 || cellAt(term, 1, 0).Attr&Underline != 0 {
		t.Errorf("underline styles: %b %b", cellAt(term, 0, 0).Attr, cellAt(term, 1, 0).Attr)
	}
	if c := cellAt(term, 2, 0); c.FG != 0 || c.BG != 0 {
		t.Errorf("underline color leaked into the cell: %+v", c)
	}

	term.Reset()
	feed(term, "\x1b[1;31;44mx\x1b[my")
	if c := cellAt(term, 1, 0); c.FG != 0 || c.BG != 0 || c.Attr != 0 {
		t.Errorf("SGR 0 left %+v", c)
	}
}

func TestUTF8DecodesAcrossWriteBoundaries(t *testing.T) {
	text := "héllo 世界 ✓ 😀"
	for split := 1; split < len(text); split++ {
		term := newTerm(30, 2)
		term.Write([]byte(text[:split]))
		term.Write([]byte(text[split:]))
		if got := term.Text(); got != text {
			t.Fatalf("split at %d: %q, want %q", split, got, text)
		}
	}
}

func TestInvalidUTF8BecomesReplacementCharacters(t *testing.T) {
	term := newTerm(20, 2)
	// Stray continuation, truncated sequence, overlong NUL, surrogate, > U+10FFFF.
	feed(term, "a\x80b\xe4\xb8c\xc0\x80d\xed\xa0\x80e\xf4\x90\x80\x80f")
	got := term.Text()
	if strings.Count(got, "�") < 5 || !strings.HasPrefix(got, "a�b�") || !strings.Contains(got, "c") || !strings.HasSuffix(got, "f") {
		t.Fatalf("got %q", got)
	}
}

func TestWideCharactersTakeTwoCells(t *testing.T) {
	term := newTerm(6, 3)
	feed(term, "a世b")
	head, tail := cellAt(term, 1, 0), cellAt(term, 2, 0)
	if head.R != '世' || head.Attr&WideHead == 0 || tail.R != 0 || tail.Attr&WideTail == 0 {
		t.Fatalf("cells = %+v %+v", head, tail)
	}
	expectCursor(t, term, 4, 0)
	expectText(t, term, "a世b")

	// A wide character that does not fit wraps whole; the last cell stays empty.
	term = newTerm(5, 3)
	feed(term, "abcd世")
	expectText(t, term, "abcd\n世")
}

func TestOverwritingHalfAWideCharacterBlanksTheOtherHalf(t *testing.T) {
	term := newTerm(6, 2)
	feed(term, "世界\x1b[1;2Hx") // lands on the tail of 世
	if c := cellAt(term, 0, 0); c.R != 0 || c.Attr&WideHead != 0 {
		t.Errorf("orphan head = %+v", c)
	}
	expectText(t, term, " x界")

	term = newTerm(6, 2)
	feed(term, "世界\x1b[1;1Hx") // lands on the head of 世
	if c := cellAt(term, 1, 0); c.Attr&WideTail != 0 {
		t.Errorf("orphan tail = %+v", c)
	}
	expectText(t, term, "x 界")

	term = newTerm(6, 2)
	feed(term, "世界\x1b[1;2H\x1b[K")
	expectText(t, term, "")

	term = newTerm(6, 2)
	feed(term, "世界\x1b[1;2H\x1b[P")
	if c := cellAt(term, 1, 0); c.Attr&WideTail != 0 && cellAt(term, 0, 0).Attr&WideHead == 0 {
		t.Errorf("delete left a dangling tail")
	}
}

func TestCombiningMarksAttachToTheirBase(t *testing.T) {
	term := newTerm(10, 2)
	feed(term, "éx")
	expectCursor(t, term, 2, 0)
	row := term.Row(0)
	if len(row.Marks) != 1 || row.Marks[0].Col != 0 || row.Marks[0].R != 0x301 {
		t.Fatalf("marks = %+v", row.Marks)
	}
	expectText(t, term, "éx")

	// Overwriting the base drops its marks.
	feed(term, "\x1b[1;1Hq")
	if len(term.Row(0).Marks) != 0 {
		t.Errorf("marks survived overwrite: %+v", term.Row(0).Marks)
	}

	// A mark right after a full row attaches to the last cell.
	term = newTerm(3, 2)
	feed(term, "abć")
	if marks := term.Row(0).Marks; len(marks) != 1 || marks[0].Col != 2 {
		t.Errorf("marks = %+v, want one on column 2", marks)
	}
	// A mark with nothing before it is dropped.
	term = newTerm(3, 2)
	feed(term, "́")
	if len(term.Row(0).Marks) != 0 {
		t.Error("a mark with no base was kept")
	}
}

func TestTabs(t *testing.T) {
	term := newTerm(30, 2)
	feed(term, "a\tb\tc")
	expectCursor(t, term, 17, 0)
	if cellAt(term, 8, 0).R != 'b' || cellAt(term, 16, 0).R != 'c' {
		t.Fatalf("default tab stops wrong: %q", term.Text())
	}
	feed(term, "\x1b[3g\r\x1bH") // clear all stops, set one at column 0
	feed(term, "\x1b[1;5H\x1bH\r\tx")
	if cellAt(term, 4, 0).R != 'x' {
		t.Fatalf("custom stop ignored: %q", term.Text())
	}
	feed(term, "\x1b[1;20H\x1b[Z")
	expectCursor(t, term, 4, 0)
	feed(term, "\x1b[1;1H\x1b[2I")
	expectCursor(t, term, 29, 0)
}

func TestDECSpecialGraphics(t *testing.T) {
	term := newTerm(10, 2)
	feed(term, "\x1b(0lqk\x1b(B lqk")
	expectText(t, term, "┌─┐ lqk")
	feed(term, "\r\n\x0e") // SO selects G1, still ASCII
	feed(term, "q\x0f")
	expectText(t, term, "┌─┐ lqk\nq")
	feed(term, "\x1b)0\x0eq\x0fq")
	expectText(t, term, "┌─┐ lqk\nq─q")
}

func TestRepliesToQueries(t *testing.T) {
	term := newTerm(80, 24)
	var replies []string
	term.SetReply(func(b []byte) { replies = append(replies, string(b)) })
	term.SetDefaultColors([3]uint8{0xaa, 0xbb, 0xcc}, [3]uint8{1, 2, 3})
	feed(term, "\x1b[5n")
	feed(term, "\x1b[3;7H\x1b[6n")
	feed(term, "\x1b[?6n")
	feed(term, "\x1b[c\x1b[0c\x1b[>c\x1bZ")
	feed(term, "\x1b[?25$p\x1b[?2004$p\x1b[?9999$p\x1b[4$p")
	feed(term, "\x1b[?1h\x1b[?1$p")
	feed(term, "\x1b]10;?\x07\x1b]11;?\x1b\\")
	feed(term, "\x1b[>q\x1b[18t")
	want := []string{
		"\x1b[0n",
		"\x1b[3;7R",
		"\x1b[?3;7R",
		"\x1b[?62;22c", "\x1b[?62;22c", "\x1b[>1;10;0c", "\x1b[?62;22c",
		"\x1b[?25;1$y", "\x1b[?2004;2$y", "\x1b[?9999;0$y", "\x1b[4;2$y",
		"\x1b[?1;1$y",
		"\x1b]10;rgb:aaaa/bbbb/cccc\x1b\\", "\x1b]11;rgb:0101/0202/0303\x1b\\",
		"\x1bP>|motty\x1b\\", "\x1b[8;24;80t",
	}
	if strings.Join(replies, "|") != strings.Join(want, "|") {
		t.Fatalf("replies:\n%q\nwant:\n%q", replies, want)
	}

	// Without defaults installed the color queries stay unanswered.
	bare := newTerm(10, 2)
	bare.SetReply(func([]byte) { t.Error("unexpected reply") })
	feed(bare, "\x1b]11;?\x07")
}

func TestCursorPositionReportInOriginMode(t *testing.T) {
	term := newTerm(20, 10)
	var got string
	term.SetReply(func(b []byte) { got = string(b) })
	feed(term, "\x1b[4;8r\x1b[?6h\x1b[2;3H\x1b[6n")
	if got != "\x1b[2;3R" {
		t.Fatalf("report = %q", got)
	}
}

func TestTitleFromOSC(t *testing.T) {
	term := newTerm(20, 2)
	feed(term, "\x1b]0;user@host: ~\x07")
	if term.Title() != "user@host: ~" {
		t.Fatalf("title = %q", term.Title())
	}
	feed(term, "\x1b]2;中文标题\x1b\\")
	if term.Title() != "中文标题" {
		t.Fatalf("title = %q", term.Title())
	}
	feed(term, "\x1b]1;icon\x07\x1b]52;c;aGVsbG8=\x07\x1b]8;;http://x\x07")
	if term.Title() != "中文标题" {
		t.Fatalf("an unrelated OSC changed the title to %q", term.Title())
	}
	expectText(t, term, "")

	// An over-long string is ignored whole and does not poison the next one.
	feed(term, "\x1b]0;"+strings.Repeat("x", 2*maxOSC)+"\x07\x1b]0;ok\x07")
	if term.Title() != "ok" {
		t.Fatalf("title = %q", term.Title())
	}
	// Control characters never reach the title.
	feed(term, "\x1b]0;a\x01b\x07")
	if term.Title() != "ab" {
		t.Fatalf("title = %q", term.Title())
	}
}

func TestUTF8TitlePreservesTerminalContentAcrossWrites(t *testing.T) {
	for _, title := range []string{"✳ Issue 和 PR 的相关反馈", "А", "М", "Н", "П", "😀 中文"} {
		for _, command := range []string{"0", "2"} {
			for _, end := range []string{"\x07", "\x1b\\"} {
				data := []byte("\x1b]" + command + ";" + title + end)
				for split := -1; split <= len(data); split++ {
					t.Run(fmt.Sprintf("%s/OSC%s/%x/split%d", title, command, end, split), func(t *testing.T) {
						screen := newTerm(60, 3)
						feed(screen, "history\r\nfirst\r\nsecond\r\n❯ ")
						for _, offset := range []int{0, 1} {
							screen.Scroll(offset)
							before := screen.AppendRetainedText(nil)
							cursor, history, view := screen.Cursor(), screen.Scrollback(), screen.ViewOffset()
							rows := make([]Row, 3)
							for i := range rows {
								rows[i] = screen.Row(i)
								rows[i].Cells = append([]Cell(nil), rows[i].Cells...)
							}
							if split == -1 {
								for _, b := range data {
									screen.Write([]byte{b})
								}
							} else {
								screen.Write(data[:split])
								screen.Write(data[split:])
							}
							if got := screen.Title(); got != title {
								t.Fatalf("title = %q, want %q; screen = %q", got, title, screen.Text())
							}
							if got := string(screen.AppendRetainedText(nil)); got != string(before) || screen.Cursor() != cursor || screen.Scrollback() != history || screen.ViewOffset() != view {
								t.Fatalf("title changed terminal content: retained=%q cursor=%+v history=%d view=%d", got, screen.Cursor(), screen.Scrollback(), screen.ViewOffset())
							}
							for i, row := range rows {
								if !reflect.DeepEqual(screen.Row(i), row) {
									t.Fatalf("title changed visible row %d", i)
								}
							}
							checkInvariants(t, screen)
						}
					})
				}
			}
		}
	}
}

func TestUnsupportedStringsAreSkipped(t *testing.T) {
	term := newTerm(20, 2)
	feed(term, "a\x1bPsome;dcs\x1b\\b\x1b_apc\x1b\\c\x1b^pm\x1b\\d\x1bXsos\x1b\\e")
	expectText(t, term, "abcde")
}

func TestC1BytesAreNotStringControls(t *testing.T) {
	for _, b := range []byte{0x90, 0x9C, 0x9D, 0x9F} {
		screen := newTerm(40, 3)
		feed(screen, string([]byte{b})+"plain\x07")
		expectText(t, screen, "�plain")
		if screen.Title() != "" || screen.state != stGround {
			t.Fatalf("bare %x opened a control string", b)
		}

		for _, payload := range []string{string([]byte{b}), string(rune(b))} {
			screen := newTerm(40, 3)
			feed(screen, "\x1b]0;previous\x07\x1b]0;left"+payload+"right")
			if screen.Title() != "previous" || screen.Text() != "" || screen.state != stOSC {
				t.Fatalf("payload %x changed string state: title=%q screen=%q state=%v", payload, screen.Title(), screen.Text(), screen.state)
			}
			feed(screen, "\x1b\\")
			if want := "left" + strings.ToValidUTF8(payload, "�") + "right"; screen.Title() != want {
				t.Fatalf("payload %x: title=%q, want %q", payload, screen.Title(), want)
			}
			feed(screen, "\x1b]2;next\x07ok")
			if screen.Title() != "next" {
				t.Fatalf("payload %x poisoned the next title", payload)
			}
			expectText(t, screen, "ok")
		}
	}
}

func TestUTF8ControlStringsRecoverWithoutLeaking(t *testing.T) {
	const payload = "✳ АМНП 😀 中文"
	for _, start := range []string{"\x1b]0;", "\x1bP", "\x1b_", "\x1b^", "\x1bX"} {
		for _, end := range []string{"\x1b\\", "\x18", "\x1a", "\x1b[0m", "reset"} {
			t.Run(fmt.Sprintf("%x/%x", start, end), func(t *testing.T) {
				screen := newTerm(40, 3)
				feed(screen, "before"+start)
				for _, b := range []byte(payload) {
					screen.Write([]byte{b})
				}
				if end == "reset" {
					screen.Reset()
				} else {
					feed(screen, end)
				}
				feed(screen, "\x1b]2;next\x07after")
				want := "beforeafter"
				if end == "reset" {
					want = "after"
				}
				expectText(t, screen, want)
				if screen.Title() != "next" {
					t.Fatalf("recovery title = %q", screen.Title())
				}
				checkInvariants(t, screen)
			})
		}
	}
}

func TestOversizedUTF8TitleIsDiscardedUntilTerminator(t *testing.T) {
	for _, end := range []string{"\x07", "\x1b\\"} {
		screen := newTerm(40, 3)
		feed(screen, "prompt\x1b]0;previous\x07\x1b]0;")
		for range maxOSC {
			feed(screen, "✳АМНП😀")
		}
		if len(screen.osc) > maxOSC || !screen.oscOverflow {
			t.Fatalf("oversized payload: buffered=%d overflow=%v", len(screen.osc), screen.oscOverflow)
		}
		feed(screen, end)
		if screen.Title() != "previous" {
			t.Fatalf("overflow replaced title with %q", screen.Title())
		}
		expectText(t, screen, "prompt")
		feed(screen, "\x1b]2;next"+end+"after")
		if screen.Title() != "next" {
			t.Fatalf("overflow poisoned next title: %q", screen.Title())
		}
		expectText(t, screen, "promptafter")
		checkInvariants(t, screen)
	}
}

func TestControlCharactersInsideSequencesStillRun(t *testing.T) {
	term := newTerm(20, 3)
	feed(term, "ab\x1b[\n2Ccd")
	// The line feed ran in the middle of the CSI; then the cursor moved right 2.
	expectText(t, term, "ab\n    cd")
}

func TestCancelAbortsASequence(t *testing.T) {
	term := newTerm(20, 2)
	feed(term, "a\x1b[1;\x18bc\x1b[3\x1ad")
	expectText(t, term, "abcd")
}

func TestModes(t *testing.T) {
	term := newTerm(20, 5)
	feed(term, "\x1b[?1h\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[?25l\x1b=")
	m := term.Modes()
	if !m.AppCursorKeys || !m.BracketedPaste || m.Mouse != MouseButton || m.MouseEncoding != MouseEncodingSGR ||
		!m.FocusReporting || m.CursorVisible || !m.AppKeypad {
		t.Fatalf("modes = %+v", m)
	}
	feed(term, "\x1b[?1l\x1b[?2004l\x1b[?1000l\x1b[?1006l\x1b[?1004l\x1b[?25h\x1b>")
	m = term.Modes()
	if m.AppCursorKeys || m.BracketedPaste || m.Mouse != MouseOff || m.MouseEncoding != MouseEncodingX10 ||
		m.FocusReporting || !m.CursorVisible || m.AppKeypad {
		t.Fatalf("modes after reset = %+v", m)
	}
	feed(term, "\x1b[?1003h\x1b[?1002l") // resetting a different level leaves any-motion on
	if term.Modes().Mouse != MouseAny {
		t.Errorf("mouse = %v", term.Modes().Mouse)
	}
	feed(term, "\x1b[20h\nx")
	expectCursor(t, term, 1, 1)
	feed(term, "\x1b[?25l\x1b[4h\x1b[1 q\x1b[!p")
	m = term.Modes()
	if !m.CursorVisible || m.Insert {
		t.Errorf("soft reset left %+v", m)
	}
	feed(term, "\x1b[5 q")
	if term.Cursor().Style != CursorBar {
		t.Errorf("cursor style = %v", term.Cursor().Style)
	}
	feed(term, "\x1b[4 q")
	if term.Cursor().Style != CursorUnderline {
		t.Errorf("cursor style = %v", term.Cursor().Style)
	}
	if !term.Cursor().Steady {
		t.Error("an even DECSCUSR asks for a steady cursor")
	}
	feed(term, "\x1b[5 q")
	if term.Cursor().Steady {
		t.Error("an odd DECSCUSR asks for a blinking one")
	}
}

func TestSynchronizedUpdateHoldsAtTheStartOfTheBlock(t *testing.T) {
	term := newTerm(20, 3)
	var holds []bool
	var at []string
	term.SetSyncHold(func(on bool) {
		holds = append(holds, on)
		at = append(at, term.Text())
	})
	feed(term, "before")
	feed(term, "\x1b[?2026hAFTER")
	if !term.Modes().Sync {
		t.Fatal("2026h did not set the synchronized update mode")
	}
	if len(holds) != 1 || !holds[0] {
		t.Fatalf("holds = %v", holds)
	}
	if at[0] != "before" {
		t.Fatalf("snapshot saw %q, want the screen before the block", at[0])
	}
	if term.modeState(2026, true) != 1 {
		t.Fatal("DECRQM did not report the mode set")
	}
	feed(term, "\x1b[?2026l")
	if term.Modes().Sync {
		t.Fatal("2026l did not clear the synchronized update mode")
	}
	if len(holds) != 2 || holds[1] {
		t.Fatalf("holds = %v", holds)
	}
	if at[1] != "beforeAFTER" {
		t.Fatalf("end snapshot saw %q", at[1])
	}
	if term.modeState(2026, true) != 2 {
		t.Fatal("DECRQM did not report the mode reset")
	}
	feed(term, "\x1b[?2026h")
	feed(term, "\x1bc")
	if term.Modes().Sync || len(holds) != 4 || holds[3] {
		t.Fatalf("full reset left the hold: modes=%+v holds=%v", term.Modes(), holds)
	}
}

func TestFullResetClearsTheScreen(t *testing.T) {
	term := newTerm(10, 3)
	feed(term, "text\x1b[31m\x1b[?1h\x1bc")
	expectText(t, term, "")
	expectCursor(t, term, 0, 0)
	if term.Modes().AppCursorKeys {
		t.Error("RIS kept a mode")
	}
	feed(term, "x")
	if c := cellAt(term, 0, 0); c.FG != 0 {
		t.Errorf("RIS kept the pen: %+v", c)
	}
}

func TestScreenAlignmentPattern(t *testing.T) {
	term := newTerm(4, 2)
	feed(term, "\x1b#8")
	expectText(t, term, "EEEE\nEEEE")
}

func TestResizeShrinkingKeepsTheCursorLineAndPushesHistory(t *testing.T) {
	term := newTerm(10, 5)
	feed(term, "1\r\n2\r\n3\r\n4\r\n5")
	term.Resize(10, 3)
	expectText(t, term, "3\n4\n5")
	expectCursor(t, term, 1, 2)
	if term.Scrollback() != 2 {
		t.Fatalf("scrollback = %d, want 2", term.Scrollback())
	}
	term.Resize(10, 5)
	expectText(t, term, "1\n2\n3\n4\n5")
	expectCursor(t, term, 1, 4)
	if term.Scrollback() != 0 {
		t.Fatalf("scrollback = %d after growing back", term.Scrollback())
	}
}

func TestResizeAlternateColumnsTruncateAndPad(t *testing.T) {
	term := newTerm(10, 3)
	feed(term, "\x1b[?1049h\x1b[H")
	feed(term, "abcdefghij\x1b[1;10H")
	term.Resize(4, 3)
	expectText(t, term, "abcd")
	expectCursor(t, term, 3, 0)
	term.Resize(8, 3)
	expectText(t, term, "abcd")
	feed(term, "\x1b[1;8Hz")
	expectText(t, term, "abcd   z")
	if len(term.Row(0).Cells) != 8 {
		t.Errorf("row has %d cells", len(term.Row(0).Cells))
	}

	// Cutting through a wide character blanks it.
	term = newTerm(6, 2)
	feed(term, "ab世")
	term.Resize(3, 2)
	if c := cellAt(term, 2, 0); c.R != 0 || c.Attr&WideHead != 0 {
		t.Errorf("cut wide head survived: %+v", c)
	}
}

func TestResizeWithinWarmCapacityDoesNotAllocate(t *testing.T) {
	terminal := New(120, 30, 100)
	terminal.Resize(80, 30)
	terminal.Resize(110, 30)
	allocations := testing.AllocsPerRun(100, func() {
		terminal.Resize(80, 30)
		terminal.Resize(110, 30)
	})
	if allocations != 0 {
		t.Fatalf("warm column resize allocations = %v", allocations)
	}
}

func TestResizeWhileOnTheAlternateScreen(t *testing.T) {
	term := newTerm(10, 4)
	feed(term, "main1\r\nmain2\x1b[?1049h\x1b[4;1Hbottom")
	term.Resize(6, 2)
	expectCursor(t, term, 5, 1)
	feed(term, "\x1b[?1049l")
	expectText(t, term, "main1\nmain2")
	term.Resize(12, 6)
	expectText(t, term, "main1\nmain2")
}

func TestSetScrollbackLimitPreservesNewestHistoryAndReleasesExcess(t *testing.T) {
	terminal := New(8, 2, 6)
	for index := 0; index < 8; index++ {
		terminal.Write([]byte(fmt.Sprintf("line-%d\r\n", index)))
	}
	if terminal.Scrollback() != 6 {
		t.Fatalf("initial scrollback = %d", terminal.Scrollback())
	}
	terminal.SetScrollbackLimit(2)
	if terminal.Scrollback() != 2 || cap(terminal.hist) != 2 {
		t.Fatalf("shrunk history = %d/%d", terminal.Scrollback(), cap(terminal.hist))
	}
	if matches, _ := terminal.Search(nil, "line-5", 1); len(matches) != 1 {
		t.Fatalf("newest retained history was lost: %+v", matches)
	}
	if matches, _ := terminal.Search(nil, "line-4", 1); len(matches) != 0 {
		t.Fatalf("discarded history remained searchable: %+v", matches)
	}
	terminal.SetScrollbackLimit(4)
	if terminal.Scrollback() != 2 || terminal.histMax != 4 {
		t.Fatalf("grown history = %d max %d", terminal.Scrollback(), terminal.histMax)
	}
	terminal.SetScrollbackLimit(0)
	if terminal.Scrollback() != 0 || terminal.hist != nil || terminal.ViewOffset() != 0 {
		t.Fatalf("cleared history = %d, slice=%v, view=%d", terminal.Scrollback(), terminal.hist, terminal.ViewOffset())
	}
}

func TestResizeIsClampedAndAlwaysConsistent(t *testing.T) {
	term := newTerm(10, 4)
	term.Resize(0, 0)
	if c, r := term.Size(); c != 1 || r != 1 {
		t.Fatalf("size = %dx%d", c, r)
	}
	term.Resize(1<<20, 1<<20)
	if c, r := term.Size(); c != maxCols || r != maxRows {
		t.Fatalf("size = %dx%d", c, r)
	}
	feed(term, "ok")
	checkInvariants(t, term)
}

func TestWideCharacterInAOneColumnTerminalDoesNotPanic(t *testing.T) {
	term := newTerm(1, 3)
	feed(term, "世界á")
	checkInvariants(t, term)
}

func TestBackspaceCancelsPendingWrapAndTabClamps(t *testing.T) {
	term := newTerm(5, 2)
	feed(term, "abcde\bX")
	expectText(t, term, "abcXe")
	term = newTerm(5, 2)
	feed(term, "ab\t\tcd")
	expectText(t, term, "ab  c\nd")
	expectCursor(t, term, 1, 1)
}

func TestTokenAtIsTheRunOfTextUnderACellWithoutWrappingPunctuation(t *testing.T) {
	screen := New(60, 4, 0)
	screen.Write([]byte("see (/var/log/syslog), host 10.0.0.5:22. 中文路径/a.tgz end\r\n"))
	for _, test := range []struct {
		column int
		want   string
	}{
		{8, "/var/log/syslog"}, // inside the parentheses and before the comma
		{35, "10.0.0.5:22"},    // before the sentence's full stop
		{0, "see"},
		{3, ""},  // the space is no token
		{59, ""}, // blank, past the text
	} {
		if got := screen.TokenAt(Position{Row: 0, Column: test.column}); got != test.want {
			t.Errorf("TokenAt(column %d) = %q, want %q", test.column, got, test.want)
		}
	}
	if got := screen.TokenAt(Position{Row: 0, Column: 41}); got != "中文路径/a.tgz" {
		t.Errorf("a token with wide characters = %q", got)
	}
}

func TestALongPlainASCIITextRunKeepsItsCellsAndColor(t *testing.T) {
	term := New(200, 3, 0)
	text := strings.Repeat("x", 150)
	term.Write([]byte("\x1b[32m" + text + "\x1b[0m"))
	row := term.Row(0)
	for index := range len(text) {
		cell := row.Cells[index]
		if cell.R != 'x' || cell.FG != Indexed(2) || cell.Attr != 0 {
			t.Fatalf("cell %d = %+v", index, cell)
		}
	}
	if cursor := term.Cursor(); cursor.X != len(text) || cursor.Y != 0 {
		t.Fatalf("cursor = %+v", cursor)
	}
}
