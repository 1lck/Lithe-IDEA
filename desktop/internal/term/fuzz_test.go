package term

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
)

// checkInvariants verifies the structural promises the renderer relies on.
func checkInvariants(t testing.TB, term *Terminal) {
	t.Helper()
	cols, rows := term.Size()
	if cols < 1 || cols > maxCols || rows < 1 || rows > maxRows {
		t.Fatalf("size %dx%d out of range", cols, rows)
	}
	if term.cx < 0 || term.cx >= cols || term.cy < 0 || term.cy >= rows {
		t.Fatalf("cursor (%d,%d) outside %dx%d", term.cx, term.cy, cols, rows)
	}
	if term.top < 0 || term.bot >= rows || term.top >= term.bot && rows > 1 {
		t.Fatalf("scroll region %d..%d on %d rows", term.top, term.bot, rows)
	}
	if len(term.tabs) != cols {
		t.Fatalf("%d tab stops for %d columns", len(term.tabs), cols)
	}
	for _, s := range []*screen{&term.main, &term.alt} {
		if len(s.lines) != rows {
			t.Fatalf("%d lines for %d rows", len(s.lines), rows)
		}
		for y, l := range s.lines {
			if len(l.cells) != cols {
				t.Fatalf("line %d has %d cells, want %d", y, len(l.cells), cols)
			}
			checkLine(t, l, cols)
		}
	}
	if term.histCount > term.histMax {
		t.Fatalf("history holds %d lines, max %d", term.histCount, term.histMax)
	}
	if term.histCount > 0 && term.histHead >= len(term.hist) {
		t.Fatalf("history head %d with %d slots", term.histHead, len(term.hist))
	}
	if term.view < 0 || term.view > term.histCount {
		t.Fatalf("view offset %d with %d history lines", term.view, term.histCount)
	}
	if term.histBudget > 0 && term.histBytes > term.histBudget {
		t.Fatalf("history holds %d bytes, budget %d", term.histBytes, term.histBudget)
	}
	for i := 0; i < term.histCount; i++ {
		checkLine(t, term.histAt(i), -1)
	}
	for i := 0; i < rows; i++ {
		row := term.Row(i)
		if len(row.Cells) > cols {
			t.Fatalf("view row %d has %d cells for %d columns", i, len(row.Cells), cols)
		}
	}
	if len(term.title) > 4*maxTitle {
		t.Fatalf("title is %d bytes", len(term.title))
	}
}

func checkLine(t testing.TB, l *line, cols int) {
	t.Helper()
	if l.hyperlinks != nil && len(*l.hyperlinks) != len(l.cells) {
		t.Fatalf("%d hyperlink cells for %d text cells", len(*l.hyperlinks), len(l.cells))
	}
	if l.used < 0 || l.used > len(l.cells) {
		t.Fatalf("used %d outside %d cells", l.used, len(l.cells))
	}
	for x := l.used; x < len(l.cells); x++ {
		if l.cells[x] != (Cell{}) {
			t.Fatalf("cell %d past used %d is not blank: %+v", x, l.used, l.cells[x])
		}
		// pushHistory trims on a blank cell and an empty link slot, so a link
		// left past used would be trimmed away without this check.
		if l.hyperlinkAt(x) != 0 {
			t.Fatalf("hyperlink %d past used %d is set", x, l.used)
		}
	}
	for x, c := range l.cells {
		if c.Attr&WideHead != 0 {
			if x+1 >= len(l.cells) || l.cells[x+1].Attr&WideTail == 0 {
				t.Fatalf("wide head at %d without a tail", x)
			}
		}
		if c.Attr&WideTail != 0 {
			if x == 0 || l.cells[x-1].Attr&WideHead == 0 {
				t.Fatalf("wide tail at %d without a head", x)
			}
		}
	}
	last := -1
	for _, m := range l.marks {
		if int(m.Col) < last {
			t.Fatalf("marks out of order: %+v", l.marks)
		}
		last = int(m.Col)
		if int(m.Col) >= len(l.cells) {
			t.Fatalf("mark at %d beyond %d cells", m.Col, len(l.cells))
		}
		if l.cells[m.Col].R == 0 {
			t.Fatalf("mark at %d on an empty cell", m.Col)
		}
	}
	if len(l.marks) > maxMarks {
		t.Fatalf("%d marks on a line", len(l.marks))
	}
}

// signature is everything observable about a terminal, for comparing two runs.
func signature(term *Terminal) string {
	var b strings.Builder
	cols, rows := term.Size()
	fmt.Fprintf(&b, "%dx%d cursor=%+v modes=%+v title=%q hist=%d view=%d alt=%v\n",
		cols, rows, term.Cursor(), term.Modes(), term.Title(), term.Scrollback(), term.ViewOffset(), term.onAlt)
	for i := 0; i < rows; i++ {
		row := term.Row(i)
		line := term.lineAt(i)
		var hyperlinks []uint32
		if line.hyperlinks != nil {
			hyperlinks = *line.hyperlinks
		}
		fmt.Fprintf(&b, "%v %v %v %v\n", row.Cells, row.Marks, hyperlinks, row.Wrapped)
	}
	return b.String()
}

// corpus is output typical of a shell session and its tools.
var corpus = []string{
	"\x1b[?2004h\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/project\x1b[00m$ ls --color\r\n",
	"\x1b[0m\x1b[01;34mdir\x1b[0m  \x1b[01;31marchive.tar.gz\x1b[0m  file.txt  \x1b[01;32mscript.sh\x1b[0m\r\n",
	"\x1b[38;5;208morange\x1b[0m \x1b[38;2;12;34;56mtruecolor\x1b[0m \x1b[48;5;236mgrey bg\x1b[K\x1b[0m\r\n",
	"中文输出 mixed with ASCII 世界\r\n",
	"\x1b[?1049h\x1b[H\x1b[2J\x1b[1;1Hfull screen\x1b[24;1H~\x1b[1;3r\x1b[3;1H\n\n\x1b[r\x1b[?1049l",
	"progress [=====>    ] 50%\r\x1b[Kdone\r\n",
	"\x1b]0;user@host: ~/project\x07\x1b[6n\x1b[c",
	"\x1b]0;✳ Issue 和 PR 的相关反馈\x07\x1b]2;АМНП😀\x1b\\",
	"\x1b]8;;https://example.test/✳АМНП😀\x1b\\link\x1b]8;;\x07",
	"\x1b]0;✳АМНП😀\x18\x1bP✳АМНП😀\x1a\x1b]2;recovered\x07",
	"\x1b]0;" + strings.Repeat("✳АМНП😀", maxOSC) + "\x07\x1b]2;recovered\x07",
	"\x1b]8;id=docs;https://example.test/文档\x1b\\linked text\x1b]8;;\x07",
	"\x1b]52;c;SGVsbG8sIOS4lueVjA==\x07",
	"tab\tseparated\tvalues\r\n\x1b[2Kcleared\r\n",
	"e\u0301 combining and \U0001F600 emoji\r\n",
	"\x1b(0lqqqk\x1b(B\r\n\x1b[3@ins\x1b[2Pdel\x1b[5Xech\r\n",
	"\x1b[2;4r\x1b[4;1H\n\n\x1b[1T\x1b[1S\x1b[r\x1b[1L\x1b[1M",
}

func TestChunkingNeverChangesTheResult(t *testing.T) {
	stream := strings.Join(corpus, "")
	whole := New(40, 12, 50)
	whole.Write([]byte(stream))
	want := signature(whole)
	checkInvariants(t, whole)

	for _, size := range []int{1, 2, 3, 5, 7, 16, 61} {
		term := New(40, 12, 50)
		for rest := []byte(stream); len(rest) > 0; {
			n := min(size, len(rest))
			term.Write(rest[:n])
			rest = rest[n:]
		}
		if got := signature(term); got != want {
			t.Fatalf("chunk size %d changed the result:\n%s\nwant\n%s", size, got, want)
		}
	}
}

func TestRandomChunkingNeverChangesTheResult(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	stream := []byte(strings.Join(corpus, ""))
	whole := New(33, 9, 20)
	whole.Write(stream)
	want := signature(whole)
	for round := 0; round < 200; round++ {
		term := New(33, 9, 20)
		for rest := stream; len(rest) > 0; {
			n := min(1+rng.Intn(20), len(rest))
			term.Write(rest[:n])
			rest = rest[n:]
		}
		if got := signature(term); got != want {
			t.Fatalf("round %d changed the result", round)
		}
	}
}

func TestRandomBytesNeverBreakInvariants(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	alphabet := []byte("\x1b[]();:?>=!#$ \"'0123456789;:@ABCDEFGHIJKLMNOPQRSTUVWXYZ`abcdefghijklmnopqrstuvwxyz\x07\x08\x09\x0a\r\x0e\x0f\x18\x1a\x7f\xc3\xa9\xe4\xb8\x96\xf0\x9f\x98\x80\x80\xff")
	for round := 0; round < 300; round++ {
		term := New(1+rng.Intn(30), 1+rng.Intn(12), rng.Intn(20))
		var sent []string
		term.SetReply(func(b []byte) { sent = append(sent, string(b)) })
		for step := 0; step < 40; step++ {
			chunk := make([]byte, 1+rng.Intn(200))
			for i := range chunk {
				if rng.Intn(5) == 0 {
					chunk[i] = byte(rng.Intn(256))
				} else {
					chunk[i] = alphabet[rng.Intn(len(alphabet))]
				}
			}
			term.Write(chunk)
			switch rng.Intn(8) {
			case 0:
				term.Resize(1+rng.Intn(40), 1+rng.Intn(15))
			case 1:
				term.Scroll(rng.Intn(10) - 5)
			}
			checkInvariants(t, term)
		}
		for _, r := range sent {
			if len(r) > 64 {
				t.Fatalf("a reply is %d bytes", len(r))
			}
		}
	}
}

func TestHugeParametersAreHarmless(t *testing.T) {
	term := New(20, 5, 10)
	feed(term, "\x1b[99999999999999999999999A\x1b[2147483648;2147483648H\x1b[999999999@\x1b[999999999P")
	feed(term, "\x1b[999999999L\x1b[999999999M\x1b[999999999S\x1b[999999999T\x1b[999999999X")
	feed(term, "\x1b[65535b\x1b[;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;m")
	feed(term, "\x1b[38;2;99999;99999;99999m\x1b["+strings.Repeat("1;", 500)+"H")
	checkInvariants(t, term)
}

func TestMemoryStaysBoundedUnderAFlood(t *testing.T) {
	term := New(120, 40, 1000)
	line := []byte(strings.Repeat("0123456789\x1b[31mabcdef\x1b[0m", 6) + "\r\n")
	for i := 0; i < 20000; i++ {
		term.Write(line)
	}
	checkInvariants(t, term)
	if term.Scrollback() != 1000 {
		t.Fatalf("scrollback = %d", term.Scrollback())
	}
}

func FuzzWrite(f *testing.F) {
	for _, s := range corpus {
		f.Add([]byte(s), uint8(10), uint8(5))
	}
	f.Add([]byte("\x1b[?1049h\x1b[38:2::1:2:3m\x1b]0;t\x07世\u0301"), uint8(3), uint8(2))
	f.Fuzz(func(t *testing.T, data []byte, cols, rows uint8) {
		term := New(int(cols%40)+1, int(rows%15)+1, 10)
		term.SetReply(func([]byte) {})
		term.Write(data)
		term.Resize(int(rows%30)+1, int(cols%10)+1)
		term.Write(data)
		term.Scroll(3)
		checkInvariants(t, term)
	})
}
