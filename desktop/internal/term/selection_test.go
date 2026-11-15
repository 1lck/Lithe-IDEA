package term

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSelectedTextUsesCellsAndPreservesHardLineEndings(t *testing.T) {
	tests := []struct {
		name       string
		cols, rows int
		input      string
		anchor     Position
		focus      Position
		want       string
	}{
		{"forward", 12, 3, "alpha beta\r\ngamma\r\n", Position{0, 2}, Position{1, 2}, "pha beta\ngam"},
		{"backward", 12, 3, "alpha beta\r\ngamma\r\n", Position{1, 2}, Position{0, 2}, "pha beta\ngam"},
		{"wide and combining", 12, 2, "A世éZ", Position{0, 1}, Position{0, 4}, "世éZ"},
		{"soft wrap", 4, 3, "abcdefgh", Position{0, 1}, Position{1, 2}, "bcdefg"},
		{"trailing blanks", 8, 2, "ab", Position{0, 0}, Position{0, 7}, "ab"},
		{"clamped", 8, 2, "top\r\nbottom", Position{-9, -4}, Position{20, 20}, "top\nbottom"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			for _, chunk := range []int{len(test.input), 1} {
				screen := New(test.cols, test.rows, 10)
				for input := []byte(test.input); len(input) > 0; {
					n := min(chunk, len(input))
					screen.Write(input[:n])
					input = input[n:]
				}
				if got := screen.SelectedText(test.anchor, test.focus); got != test.want {
					t.Fatalf("chunk %d selected %q, want %q", chunk, got, test.want)
				}
			}
		})
	}
}

func TestWordBoundsRespectWideCharactersAndWordClasses(t *testing.T) {
	screen := New(24, 2, 0)
	screen.Write([]byte("go_name 世界 !!"))
	for _, test := range []struct {
		at         Position
		start, end Position
		want       string
	}{
		{Position{0, 2}, Position{0, 0}, Position{0, 6}, "go_name"},
		{Position{0, 8}, Position{0, 8}, Position{0, 11}, "世界"},
		{Position{0, 9}, Position{0, 8}, Position{0, 11}, "世界"},
		{Position{0, 13}, Position{0, 13}, Position{0, 14}, "!!"},
	} {
		start, end := screen.WordBounds(test.at)
		if start != test.start || end != test.end || screen.SelectedText(start, end) != test.want {
			t.Errorf("at %+v bounds %+v..%+v text %q, want %+v..%+v %q", test.at, start, end, screen.SelectedText(start, end), test.start, test.end, test.want)
		}
	}
}

func TestCustomWordSeparatorsKeepPathsTogetherAndPreserveWideCells(t *testing.T) {
	screen := New(30, 2, 0)
	screen.Write([]byte("path/to-file 世界!next"))
	for _, test := range []struct {
		separators string
		column     int
		want       string
	}{
		{"", 1, "path"},
		{"-", 1, "path/to"},
		{"-", 8, "file"},
		{"-", 14, "世界!next"},
		{"-/", 1, "path"},
	} {
		screen.SetWordSeparators(test.separators)
		start, end := screen.WordBounds(Position{Column: test.column})
		if got := screen.SelectedText(start, end); got != test.want {
			t.Errorf("separators %q at %d: got %q, want %q", test.separators, test.column, got, test.want)
		}
	}
}

func FuzzSelectedText(f *testing.F) {
	f.Add([]byte("plain\r\n世界 e\xcc\x81"), uint8(0), uint8(0), uint8(2), uint8(7))
	f.Add([]byte("\x1b[31mred\x1b[0m\r\nnext"), uint8(3), uint8(12), uint8(1), uint8(0))
	f.Fuzz(func(t *testing.T, input []byte, rowA, colA, rowB, colB uint8) {
		screen := New(24, 6, 12)
		for _, value := range input {
			screen.Write([]byte{value})
		}
		selected := screen.SelectedText(
			Position{Row: int(rowA), Column: int(colA)},
			Position{Row: int(rowB), Column: int(colB)},
		)
		if !utf8.ValidString(selected) {
			t.Fatalf("selection is not UTF-8: %q", selected)
		}
	})
}

func BenchmarkSelectedText(b *testing.B) {
	screen := New(120, 40, DefaultScrollback)
	line := strings.Repeat("The quick brown fox 你好 ", 6) + "\r\n"
	screen.Write([]byte(strings.Repeat(line, 40)))
	b.ReportAllocs()
	var selected string
	for b.Loop() {
		selected = screen.SelectedText(Position{0, 0}, Position{39, 119})
	}
	_ = selected
}

func BenchmarkWordBounds(b *testing.B) {
	for _, test := range []struct{ name, separators string }{
		{"default", ""}, {"custom", "-/."},
	} {
		b.Run(test.name, func(b *testing.B) {
			screen := New(100, 2, 0)
			screen.Write([]byte(strings.Repeat("path/to-file_世界 ", 5)))
			screen.SetWordSeparators(test.separators)
			b.ReportAllocs()
			for b.Loop() {
				screen.WordBounds(Position{Column: 13})
			}
		})
	}
}

func TestSelectedRangeFollowsTextThroughScrollingAndHistoryTrim(t *testing.T) {
	screen := New(10, 4, 4)
	screen.Write([]byte("one\r\ntwo\r\nthree\r\n"))
	from, to := screen.PointAt(Position{Row: 0}), screen.PointAt(Position{Row: 1, Column: 9})
	if got := screen.SelectedRange(from, to); got != "one\ntwo" {
		t.Fatalf("before output %q", got)
	}
	screen.Write([]byte("four\r\nfive\r\n"))
	if got := screen.SelectedRange(from, to); got != "one\ntwo" {
		t.Fatalf("after the lines moved into history %q", got)
	}
	screen.Scroll(2)
	if got := screen.SelectedRange(from, to); got != "one\ntwo" {
		t.Fatalf("after scrolling back %q", got)
	}
	screen.Write([]byte("six\r\nseven\r\neight\r\n"))
	if got := screen.SelectedRange(from, to); got == "one\ntwo" || strings.Contains(got, "three") {
		t.Fatalf("dropped lines were not clamped away: %q", got)
	}
}
