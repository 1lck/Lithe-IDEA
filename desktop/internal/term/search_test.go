package term

import (
	"fmt"
	"testing"
)

func TestSearchRetainedTerminalText(t *testing.T) {
	tests := []struct {
		name       string
		cols, rows int
		text       string
		query      string
		want       []SearchMatch
	}{
		{
			name: "case insensitive overlap", cols: 8, rows: 2,
			text: "aAaA", query: "aa",
			want: []SearchMatch{
				{Start: BufferPosition{Line: 0, Column: 0}, End: BufferPosition{Line: 0, Column: 2}},
				{Start: BufferPosition{Line: 0, Column: 1}, End: BufferPosition{Line: 0, Column: 3}},
				{Start: BufferPosition{Line: 0, Column: 2}, End: BufferPosition{Line: 0, Column: 4}},
			},
		},
		{
			name: "wide and combining", cols: 10, rows: 2,
			text: "你e\u0301好", query: "E\u0301好",
			want: []SearchMatch{{Start: BufferPosition{Line: 0, Column: 2}, End: BufferPosition{Line: 0, Column: 5}}},
		},
		{
			name: "soft wrap", cols: 4, rows: 2,
			text: "abcde", query: "CDE",
			want: []SearchMatch{{Start: BufferPosition{Line: 0, Column: 2}, End: BufferPosition{Line: 1, Column: 1}}},
		},
		{
			name: "hard line boundary", cols: 4, rows: 2,
			text: "abc\r\nde", query: "cde",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			terminal := New(test.cols, test.rows, 8)
			terminal.Write([]byte(test.text))
			got, truncated := terminal.Search(nil, test.query, 32)
			if truncated || fmt.Sprint(got) != fmt.Sprint(test.want) {
				t.Fatalf("Search(%q) = %+v truncated=%t, want %+v", test.query, got, truncated, test.want)
			}
		})
	}
}

func TestSearchIncludesScrollbackAndRevealCentersTheMatch(t *testing.T) {
	terminal := New(8, 3, 8)
	terminal.Write([]byte("zero\r\none\r\ntwo\r\nthree\r\nfour"))
	matches, truncated := terminal.Search(nil, "one", 8)
	if truncated || len(matches) != 1 || matches[0].Start.Line != 1 {
		t.Fatalf("matches = %+v truncated=%t", matches, truncated)
	}
	if !terminal.RevealLine(matches[0].Start.Line) || terminal.ViewLine(1) != matches[0].Start.Line {
		t.Fatalf("view offset=%d center line=%d", terminal.ViewOffset(), terminal.ViewLine(1))
	}
	if terminal.RevealLine(-1) || terminal.RevealLine(terminal.bufferLineCount()) {
		t.Fatal("an invalid buffer line changed the view")
	}
}

func TestSearchLimitReportsTruncationAndReusesDestination(t *testing.T) {
	terminal := New(8, 2, 0)
	terminal.Write([]byte("aaaa"))
	destination := make([]SearchMatch, 0, 2)
	matches, truncated := terminal.Search(destination, "a", 2)
	if len(matches) != 2 || !truncated || cap(matches) != cap(destination) {
		t.Fatalf("matches=%+v truncated=%t cap=%d", matches, truncated, cap(matches))
	}
	if empty, truncated := terminal.Search(matches, "", 2); len(empty) != 0 || truncated {
		t.Fatalf("empty search = %+v truncated=%t", empty, truncated)
	}
}

func TestSearchIsIndependentOfUTF8WriteSplits(t *testing.T) {
	data := []byte("before 你e\u0301好 after")
	for split := 0; split <= len(data); split++ {
		terminal := New(32, 2, 0)
		terminal.Write(data[:split])
		terminal.Write(data[split:])
		matches, truncated := terminal.Search(nil, "你E\u0301好", 4)
		if truncated || len(matches) != 1 || matches[0].Start.Column != 7 || matches[0].End.Column != 12 {
			t.Fatalf("split %d: matches=%+v truncated=%t", split, matches, truncated)
		}
	}
}

func FuzzSearch(f *testing.F) {
	f.Add([]byte("alpha 你e\u0301 beta\r\nalpha"), "alpha")
	f.Add([]byte("aaaa"), "aa")
	f.Fuzz(func(t *testing.T, data []byte, query string) {
		terminal := New(24, 4, 16)
		terminal.Write(data)
		matches, _ := terminal.Search(nil, query, 64)
		if len(matches) > 64 {
			t.Fatalf("matches = %d", len(matches))
		}
		previous := BufferPosition{Line: -1}
		for _, match := range matches {
			if match.Start.Line < 0 || match.Start.Line >= terminal.bufferLineCount() || match.End.Line < match.Start.Line || match.End.Line >= terminal.bufferLineCount() || match.Start.Column < 0 || match.Start.Column >= 24 || match.End.Column < 1 || match.End.Column > 24 {
				t.Fatalf("invalid match %+v", match)
			}
			if match.Start.Line < previous.Line || match.Start.Line == previous.Line && match.Start.Column < previous.Column {
				t.Fatalf("out of order: previous=%+v match=%+v", previous, match)
			}
			previous = match.Start
		}
	})
}

func BenchmarkSearchScrollback(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	for line := 0; line < DefaultScrollback+40; line++ {
		terminal.Write([]byte(fmt.Sprintf("%06d the quick brown fox jumps over the lazy dog 你好 world\r\n", line)))
	}
	matches := make([]SearchMatch, 0, 16)
	b.ReportAllocs()
	for b.Loop() {
		matches, _ = terminal.Search(matches[:0], "not present", 16)
	}
}
