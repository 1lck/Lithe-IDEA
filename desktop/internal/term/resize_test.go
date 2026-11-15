package term

import (
	"fmt"
	"math/rand"
	"reflect"
	"strings"
	"testing"
)

func TestResizeReflowsLongLinesInsteadOfClippingThem(t *testing.T) {
	terminal := New(10, 4, 20)
	feed(terminal, "0123456789ABCDE\r\n$ ")
	terminal.Resize(20, 4)
	expectText(t, terminal, "0123456789ABCDE\n$")
	expectCursor(t, terminal, 2, 1)
	terminal.Resize(5, 4)
	expectText(t, terminal, "01234\n56789\nABCDE\n$")
	expectCursor(t, terminal, 2, 3)
	if !terminal.Row(0).Wrapped || !terminal.Row(1).Wrapped || terminal.Row(2).Wrapped {
		t.Fatal("the rows of one line are not marked as continued")
	}
}

func TestResizeRestoresTheTextAfterNarrowingAndWideningAgain(t *testing.T) {
	terminal := New(16, 4, 20)
	feed(terminal, "0123456789ABCDEF\r\nsecond-row-END\r\nprompt> ")
	firstID := terminal.Row(0).ID
	for _, width := range []int{8, 4, 12, 6, 16} {
		terminal.Resize(width, 4)
		checkInvariants(t, terminal)
	}
	expectText(t, terminal, "0123456789ABCDEF\nsecond-row-END\nprompt>")
	expectCursor(t, terminal, 8, 2)
	if terminal.Row(0).ID != firstID {
		t.Fatal("reflowing changed the identity of the first row of a line")
	}
	if terminal.Scrollback() != 0 || terminal.histBytes != terminal.historyBytes() {
		t.Fatalf("scrollback = %d, history bytes %d, counted %d", terminal.Scrollback(), terminal.histBytes, terminal.historyBytes())
	}
}

func TestResizeKeepsCellMetadataThroughAReflow(t *testing.T) {
	terminal := New(16, 3, 20)
	terminal.SetClock(func() int64 { return 123 })
	feed(terminal, "\x1b[31;44mabc界é\x1b]8;;https://example.test\x07LINK\x1b]8;;\x07")
	before := terminal.Row(0)
	cells := append([]Cell(nil), before.Cells...)
	marks := append([]Mark(nil), before.Marks...)
	terminal.Resize(4, 3) // The wide character no longer fits after "abc".
	checkInvariants(t, terminal)
	if row := terminal.Row(1); row.Cells[0].R != '界' || row.Cells[0].Attr&WideHead == 0 {
		t.Fatalf("the wide character did not move to the next row whole: %+v", row.Cells)
	}
	if row := terminal.Row(1); len(row.Marks) != 1 || row.Marks[0] != (Mark{Col: 2, R: '́'}) {
		t.Fatalf("combining mark = %+v", row.Marks)
	}
	if link, ok := terminal.LinksAt(BufferPosition{Line: 1, Column: 3}); !ok || link.Target != "https://example.test" {
		t.Fatalf("narrow OSC 8 link = %+v, %v", link, ok)
	}
	terminal.Resize(16, 3)
	after := terminal.Row(0)
	if !reflect.DeepEqual(after.Cells, cells) || !reflect.DeepEqual(after.Marks, marks) || after.Written != 123 {
		t.Fatalf("rejoined row lost cells, marks or timestamp: %+v", after)
	}
	link, ok := terminal.LinksAt(BufferPosition{Line: 0, Column: 6})
	if !ok || link.Target != "https://example.test" {
		t.Fatalf("rejoined OSC 8 link = %+v, %v", link, ok)
	}
}

func TestResizeRejoinsRowsEditedWhileNarrow(t *testing.T) {
	for _, test := range []struct {
		name, edit, want string
	}{
		{"overwrite", "\rXY", "abcdXYGH"},
		{"erase", "\r\x1b[2K", "abcd"},
		{"insert", "\r\x1b[@", "abcd EFG"},
		{"delete", "\r\x1b[P", "abcdFGH"},
	} {
		t.Run(test.name, func(t *testing.T) {
			terminal := New(8, 3, 20)
			feed(terminal, "abcdEFGH")
			terminal.Resize(4, 3)
			feed(terminal, test.edit)
			terminal.Resize(8, 3)
			expectText(t, terminal, test.want)
		})
	}
}

func TestResizeReflowsHistory(t *testing.T) {
	terminal := New(8, 2, 20)
	feed(terminal, "ABCDEFGHijkl\r\nmn\r\nx")
	if terminal.Scrollback() != 2 {
		t.Fatalf("scrollback = %d", terminal.Scrollback())
	}
	terminal.Resize(12, 2)
	expectText(t, terminal, "mn\nx")
	if terminal.Scrollback() != 1 {
		t.Fatalf("scrollback = %d after widening, want the joined line", terminal.Scrollback())
	}
	terminal.Resize(4, 2)
	if got := string(terminal.AppendRetainedText(nil)); got != "ABCDEFGHijkl\nmn\nx" {
		t.Fatalf("retained output = %q", got)
	}
	if terminal.Scrollback() != 3 || terminal.histBytes != terminal.historyBytes() {
		t.Fatalf("scrollback = %d, history bytes %d, counted %d", terminal.Scrollback(), terminal.histBytes, terminal.historyBytes())
	}
	if number := terminal.LineNumber(0); number != 4 {
		t.Fatalf("first screen line number = %d, want 4", number)
	}
}

func TestResizeKeepsTheCursorOnItsCharacter(t *testing.T) {
	terminal := New(20, 3, 20)
	feed(terminal, "hello world\r\x1b[6C")
	terminal.Resize(5, 3)
	expectText(t, terminal, "hello\n worl\nd")
	expectCursor(t, terminal, 1, 1)
	terminal.Resize(20, 3)
	expectText(t, terminal, "hello world")
	expectCursor(t, terminal, 6, 0)
}

func TestResizeKeepsABottomPromptAtTheBottom(t *testing.T) {
	terminal := New(10, 3, 20)
	feed(terminal, "one\r\ntwo\r\n0123456789abcdefghij\r\n$ ")
	expectText(t, terminal, "0123456789\nabcdefghij\n$")
	terminal.Resize(20, 3)
	expectText(t, terminal, "two\n0123456789abcdefghij\n$")
	expectCursor(t, terminal, 2, 2)
	terminal.Resize(10, 3)
	expectText(t, terminal, "0123456789\nabcdefghij\n$")
	expectCursor(t, terminal, 2, 2)
}

func TestResizeKeepsTheTopOfAScreenThatIsNotFull(t *testing.T) {
	terminal := New(10, 5, 20)
	feed(terminal, "history\r\n\x1b[2J\x1b[H0123456789abc\r\n$ ")
	terminal.Resize(20, 5)
	expectText(t, terminal, "0123456789abc\n$")
	expectCursor(t, terminal, 2, 1)
}

func TestResizeMovesAWideCharacterThatWouldStraddleTheEdge(t *testing.T) {
	terminal := newTerm(6, 2)
	feed(terminal, "ab世")
	terminal.Resize(3, 2)
	checkInvariants(t, terminal)
	expectText(t, terminal, "ab\n世")
	terminal.Resize(1, 2)
	checkInvariants(t, terminal)
	terminal.Resize(6, 2)
	checkInvariants(t, terminal)
}

func TestResizeRetainsBackgroundMainButNotAlternateScreen(t *testing.T) {
	terminal := New(8, 3, 20)
	feed(terminal, "main-END\x1b[?1049h\x1b[Halt-END")
	terminal.Resize(4, 3)
	terminal.Resize(8, 3)
	expectText(t, terminal, "alt-")
	feed(terminal, "\x1b[?1049l")
	expectText(t, terminal, "main-END")
}

func TestResizeReflowsTheMainScreenUnderTheAlternateScreen(t *testing.T) {
	terminal := New(8, 3, 20)
	feed(terminal, "main-END\x1b[?1049h\x1b[Halt")
	terminal.Resize(4, 3)
	feed(terminal, "\x1b[?1049l")
	expectText(t, terminal, "main\n-END")
	checkInvariants(t, terminal)
}

func TestResizeUnderTheAlternateScreenKeepsTheSavedCursorLine(t *testing.T) {
	terminal := New(10, 3, 20)
	feed(terminal, "one\r\n0123456789abc\r\n$ \x1b[?1049h\x1b[Halt")
	terminal.Resize(5, 3)
	feed(terminal, "\x1b[?1049l")
	expectText(t, terminal, "56789\nabc\n$")
	expectCursor(t, terminal, 2, 2)
}

func TestResizeReflowKeepsInvariantsAndText(t *testing.T) {
	random := rand.New(rand.NewSource(1))
	pieces := []string{"word ", "世界", "é", "\x1b[44mblue\x1b[m", "\x1b]8;;https://x.test\x07link\x1b]8;;\x07", "\r\n", "0123456789"}
	for round := 0; round < 200; round++ {
		terminal := New(12, 4, 1000)
		var input strings.Builder
		for range 40 {
			input.WriteString(pieces[random.Intn(len(pieces))])
		}
		feed(terminal, input.String())
		// What a terminal too wide to wrap anything retains, where no space
		// can be mistaken for the end of a wrapped row.
		wide := New(1000, 4, 1000)
		feed(wide, input.String())
		want := string(wide.AppendRetainedText(nil))
		for range 6 {
			// From two columns up, where every character still fits a row.
			terminal.Resize(2+random.Intn(30), 1+random.Intn(8))
			checkInvariants(t, terminal)
		}
		terminal.Resize(1000, 4)
		checkInvariants(t, terminal)
		if got := string(terminal.AppendRetainedText(nil)); got != want {
			t.Fatalf("round %d: input %q\nretained %q\nwant     %q", round, input.String(), got, want)
		}
	}
}

func TestResizeReflowRespectsTheHistoryLimit(t *testing.T) {
	terminal := New(20, 2, 3)
	for index := 0; index < 6; index++ {
		feed(terminal, fmt.Sprintf("line-%d-0123456789\r\n", index))
	}
	terminal.Resize(5, 2)
	checkInvariants(t, terminal)
	if terminal.Scrollback() != 3 {
		t.Fatalf("scrollback = %d, want the limit", terminal.Scrollback())
	}
}

// A program on the alternate screen leaves the main screen's cursor saved on a
// row a shorter window no longer has (vim, less and tmux all do). A width
// change then reflows the main screen, and the saved cursor must be clamped to
// the buffer instead of indexing past it.
func TestResizeKeepsASavedCursorInsideAShrunkenScreen(t *testing.T) {
	terminal := New(10, 40, 20)
	feed(terminal, "0123456789ABCDEF")
	feed(terminal, "\x1b[40;1H")
	feed(terminal, "\x1b[?1049h") // save the cursor on the bottom row, then switch
	terminal.Resize(10, 3)
	terminal.Resize(60, 3)
	checkInvariants(t, terminal)
	if !terminal.onAlt {
		t.Fatal("the resize left the alternate screen")
	}
	feed(terminal, "\x1b[?1049l")
	checkInvariants(t, terminal)
	if terminal.cy > terminal.rows-1 || terminal.cx > terminal.cols-1 {
		t.Fatalf("restored cursor %d,%d is not on a %dx%d screen", terminal.cx, terminal.cy, terminal.cols, terminal.rows)
	}
}

// The same clamp for a DECSC saved cursor on the main screen.
func TestResizeClampsASavedCursorTheShrunkScreenDoesNotHave(t *testing.T) {
	terminal := New(20, 40, 20)
	feed(terminal, "\x1b[40;1H\x1b7")
	terminal.Resize(20, 3)
	terminal.Resize(60, 3)
	feed(terminal, "\x1b8")
	checkInvariants(t, terminal)
	if terminal.cy > terminal.rows-1 || terminal.cx > terminal.cols-1 {
		t.Fatalf("restored cursor %d,%d is not on a %dx%d screen", terminal.cx, terminal.cy, terminal.cols, terminal.rows)
	}
}
