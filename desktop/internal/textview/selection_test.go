package textview

import (
	"slices"
	"testing"
)

// trimmed is a Source whose oldest lines are gone, as a console's are once it is full: its
// lines are numbered from first on.
type trimmed struct {
	first int
	lines []string
}

func (s trimmed) First() int        { return s.first }
func (s trimmed) Count() int        { return len(s.lines) }
func (s trimmed) Line(n int) string { return s.lines[n-s.first] }

func TestSelectionRunsBetweenAnchorAndFocusEitherWay(t *testing.T) {
	src := Strings{"first line", "second line", "third"}
	var s Selection
	s.Begin(Point{2, 2}, src[2], 1)
	s.Extend(Point{0, 6}, src[0])
	if got, want := s.Text(src), "line\nsecond line\nth"; got != want {
		t.Fatalf("a drag back up selected %q, want %q", got, want)
	}
	s.Begin(Point{1, 3}, src[1], 1)
	if s.Has(src) {
		t.Fatalf("a press alone selected %q", s.Text(src))
	}
}

func TestSelectionByWordsAndLinesKeepsTheWholeUnits(t *testing.T) {
	src := Strings{"at demo.Main.run(Main.java:12)", "next line"}
	var s Selection
	s.Begin(Point{0, 5}, src[0], 2)
	if got := s.Text(src); got != "demo" {
		t.Fatalf("a double click selected %q, want the word", got)
	}
	// A drag after a double click extends by whole words, both ends kept whole.
	s.Extend(Point{0, 15}, src[0])
	if got := s.Text(src); got != "demo.Main.run" {
		t.Fatalf("a drag by words selected %q", got)
	}
	s.Begin(Point{0, 3}, src[0], 3)
	if got, want := s.Text(src), src[0]+"\n"; got != want {
		t.Fatalf("a triple click selected %q, want the line and its newline", got)
	}
	// The last line has no newline after it to take.
	s.Begin(Point{1, 0}, src[1], 3)
	if got := s.Text(src); got != "next line" {
		t.Fatalf("a triple click on the last line selected %q", got)
	}
}

func TestSelectAllAndClear(t *testing.T) {
	src := Strings{"a", "", "b c"}
	var s Selection
	s.SelectAll(src)
	if got := s.Text(src); got != "a\n\nb c" {
		t.Fatalf("Select All selected %q", got)
	}
	s.Clear()
	if s.Has(src) {
		t.Fatal("Clear kept a selection")
	}
	s.SelectAll(Strings{})
	if s.Has(Strings{}) {
		t.Fatal("Select All of nothing selected something")
	}
}

// A console that drops its oldest lines keeps what is left of a selection over them.
func TestSelectionKeepsToItsLinesWhenTheOldestGo(t *testing.T) {
	src := trimmed{first: 0, lines: []string{"zero", "one", "two", "three"}}
	var s Selection
	s.Begin(Point{0, 2}, src.Line(0), 1)
	s.Extend(Point{2, 2}, src.Line(2))
	src = trimmed{first: 1, lines: src.lines[1:]}
	if got, want := s.Text(src), "one\ntw"; got != want {
		t.Fatalf("after the first line went the selection is %q, want %q", got, want)
	}
	src = trimmed{first: 3, lines: src.lines[2:]}
	if s.Has(src) {
		t.Fatalf("after every selected line went %q is still selected", s.Text(src))
	}
}

func TestWordAtSortsSpacesWordsAndPunctuation(t *testing.T) {
	text := "foo_bar1  (x) 中文"
	cases := []struct {
		at       int
		from, to int
	}{
		{0, 0, 8},    // foo_bar1
		{8, 8, 10},   // the two spaces
		{10, 10, 11}, // (
		{len(text), len("foo_bar1  (x) "), len(text)}, // at the end: the word before
		{len("foo_bar1  (x) ") + 3, len("foo_bar1  (x) "), len(text)},
	}
	for _, c := range cases {
		if from, to := wordAt(text, c.at); from != c.from || to != c.to {
			t.Errorf("wordAt(%d) = %d..%d (%q), want %d..%d", c.at, from, to, text[from:to], c.from, c.to)
		}
	}
	if from, to := wordAt("", 0); from != 0 || to != 0 {
		t.Errorf("wordAt of nothing = %d..%d", from, to)
	}
}

// A point inside a character, as a byte offset from another line can be, moves to its start.
func TestRangeClampsToCharacterBoundaries(t *testing.T) {
	src := Strings{"中文", "abc"}
	var s Selection
	s.Begin(Point{0, 1}, "abc", 1) // made with the text of another line
	s.Extend(Point{1, 2}, src[1])
	if got := s.Text(src); got != "中文\nab" {
		t.Fatalf("selected %q, want it to start at the character", got)
	}
}

func TestByteAtPicksTheCellUnderAColumn(t *testing.T) {
	text := "a\tb中c"
	// a: column 0; tab: 1..4; b: 4; 中: 5..7; c: 7.
	cases := []struct {
		column  float32
		nearest bool
		want    int
	}{
		{0.2, true, 0},
		{0.6, true, 1},
		{0.6, false, 0},
		{2, false, 1},
		{4.2, false, 2},
		{5.2, true, 3},
		{6.5, true, 6},
		{6.5, false, 3},
		{7.1, false, 6},
		{40, true, len(text)},
	}
	for _, c := range cases {
		if got := byteAt(text, c.column, c.nearest); got != c.want {
			t.Errorf("byteAt(%v, nearest %v) = %d, want %d", c.column, c.nearest, got, c.want)
		}
	}
}

func TestWrapLineBreaksAfterASpaceOrAtTheLimit(t *testing.T) {
	rows := wrapLine(nil, 0, "alpha beta gamma", 11)
	got := make([]string, 0, len(rows))
	for _, r := range rows {
		got = append(got, "alpha beta gamma"[r.from:r.to])
	}
	if want := []string{"alpha beta ", "gamma"}; !slices.Equal(got, want) {
		t.Fatalf("rows %q, want %q", got, want)
	}
	long := "<a-very-long-mailbox@example.invalid>"
	rows = wrapLine(nil, 3, long, 10)
	joined := ""
	for _, r := range rows {
		if r.line != 3 || cellsOf(long[r.from:r.to], 0) > 10 {
			t.Fatalf("row %+v of %q is wider than the limit or of another line", r, long)
		}
		joined += long[r.from:r.to]
	}
	if joined != long || len(rows) < 4 {
		t.Fatalf("the rows of a word wider than a line join to %q in %d rows", joined, len(rows))
	}
	// A wide character that does not fit moves to the next row whole.
	rows = wrapLine(nil, 0, "abc中", 4)
	if len(rows) != 2 || rows[0].to != 3 {
		t.Fatalf("rows %+v, want the wide character on a row of its own", rows)
	}
	if rows := wrapLine(nil, 0, "", 4); len(rows) != 1 || rows[0].from != 0 || rows[0].to != 0 {
		t.Fatalf("an empty line has rows %+v, want one empty row", rows)
	}
}
