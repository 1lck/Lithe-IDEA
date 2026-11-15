package term

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestOSC8LinksRetainTargetAndOverrideDetection(t *testing.T) {
	terminal := New(80, 2, 4)
	terminal.Write([]byte("before \x1b]8;id=release;https://target.test/a;b\x1b\\https://visible.test\x1b]8;;\x07 after"))

	links, truncated := terminal.Links(nil, 8)
	want := []Link{{
		Start:  BufferPosition{Line: 0, Column: 7},
		End:    BufferPosition{Line: 0, Column: 27},
		Target: "https://target.test/a;b",
	}}
	if truncated || !reflect.DeepEqual(links, want) {
		t.Fatalf("Links() = %+v truncated=%t, want %+v", links, truncated, want)
	}
}

func TestOSC8LinksTrackWideCombiningSoftWrapAndHistory(t *testing.T) {
	terminal := New(6, 2, 8)
	terminal.Write([]byte("x\x1b]8;;https://target.test/path\x07你e\u0301界ab\x1b]8;;\x07"))
	links, truncated := terminal.Links(nil, 4)
	want := []Link{{
		Start:  BufferPosition{Line: 0, Column: 1},
		End:    BufferPosition{Line: 1, Column: 2},
		Target: "https://target.test/path",
	}}
	if truncated || !reflect.DeepEqual(links, want) {
		t.Fatalf("soft-wrapped Links() = %+v truncated=%t, want %+v", links, truncated, want)
	}

	terminal.Write([]byte("\r\nnext\r\nlast"))
	links, truncated = terminal.Links(links[:0], 4)
	if truncated || len(links) != 1 || links[0].Target != want[0].Target || links[0].Start.Line >= terminal.Scrollback() {
		t.Fatalf("history Links() = %+v truncated=%t history=%d", links, truncated, terminal.Scrollback())
	}
}

func TestOSC8LinksAreIndependentOfInputSplits(t *testing.T) {
	for _, target := range []string{"mailto:user@example.test", "https://example.test/✳АМНП😀中文"} {
		for _, end := range []string{"\x07", "\x1b\\"} {
			data := []byte("a\x1b]8;id=x;" + target + end + "你e\u0301mail\x1b]8;;" + end + "z")
			want := []Link{{
				Start: BufferPosition{Line: 0, Column: 1}, End: BufferPosition{Line: 0, Column: 8},
				Target: target,
			}}
			for split := 0; split <= len(data); split++ {
				terminal := New(40, 2, 0)
				terminal.Write(data[:split])
				terminal.Write(data[split:])
				links, truncated := terminal.Links(nil, 4)
				if truncated || !reflect.DeepEqual(links, want) {
					t.Fatalf("target %q end %x split %d: Links() = %+v truncated=%t, want %+v", target, end, split, links, truncated, want)
				}
				expectText(t, terminal, "a你e\u0301mailz")
				expectCursor(t, terminal, 9, 0)
			}
		}
	}
}

func TestOSC8LimitsMalformedAndHostileTargets(t *testing.T) {
	terminal := New(20, 2, 4)
	terminal.Write([]byte("\x1b]8;;" + strings.Repeat("x", maxHyperlinkTarget+1) + "\x07ignored\x1b]8;;\x07"))
	terminal.Write([]byte("\x1b]8;;https://bad.test/\x7fcontrol\x07ignored\x1b]8;;\x07"))
	terminal.Write([]byte("\x1b]8;missing-uri-separator\x07ignored"))
	if links, truncated := terminal.Links(nil, 8); len(links) != 0 || truncated {
		t.Fatalf("malformed links = %+v truncated=%t", links, truncated)
	}
	if len(terminal.hyperlinks) != 0 {
		t.Fatalf("malformed targets retained %d slots", len(terminal.hyperlinks))
	}

	for index := 0; index < maxHyperlinks+64; index++ {
		terminal.Write([]byte(fmt.Sprintf("\x1b]8;;https://example.test/%d\x07x\x1b]8;;\x07\r", index)))
	}
	if len(terminal.hyperlinks) > maxHyperlinks {
		t.Fatalf("retained %d hyperlink slots, max %d", len(terminal.hyperlinks), maxHyperlinks)
	}
	links, truncated := terminal.Links(nil, 8)
	if truncated || len(links) != 1 || links[0].Target != fmt.Sprintf("https://example.test/%d", maxHyperlinks+63) {
		t.Fatalf("newest bounded link = %+v truncated=%t", links, truncated)
	}
}

func TestOSC8LinksFollowCellEditingAndErase(t *testing.T) {
	terminal := New(10, 2, 0)
	terminal.Write([]byte("\x1b]8;;https://target.test\x07abcd\x1b]8;;\x07"))
	terminal.Write([]byte("\x1b[1;2H\x1b[@"))
	links, truncated := terminal.Links(nil, 8)
	want := []Link{
		{Start: BufferPosition{Line: 0, Column: 0}, End: BufferPosition{Line: 0, Column: 1}, Target: "https://target.test"},
		{Start: BufferPosition{Line: 0, Column: 2}, End: BufferPosition{Line: 0, Column: 5}, Target: "https://target.test"},
	}
	if truncated || !reflect.DeepEqual(links, want) {
		t.Fatalf("after insert Links() = %+v truncated=%t, want %+v", links, truncated, want)
	}

	terminal.Write([]byte("\x1b[1;1H\x1b[2K"))
	if links, truncated := terminal.Links(links[:0], 8); len(links) != 0 || truncated {
		t.Fatalf("erased links = %+v truncated=%t", links, truncated)
	}
}

func TestLinksRetainedTerminalText(t *testing.T) {
	tests := []struct {
		name       string
		cols, rows int
		text       string
		want       []Link
	}{
		{
			name: "punctuation boundaries", cols: 96, rows: 2,
			text: "(https://example.com/a(b)), http://example.org/x?y=1.",
			want: []Link{
				{Start: BufferPosition{Line: 0, Column: 1}, End: BufferPosition{Line: 0, Column: 25}, Target: "https://example.com/a(b)"},
				{Start: BufferPosition{Line: 0, Column: 28}, End: BufferPosition{Line: 0, Column: 52}, Target: "http://example.org/x?y=1"},
			},
		},
		{
			name: "wide and combining", cols: 64, rows: 2,
			text: "看：https://例子.test/e\u0301/你，后",
			want: []Link{{Start: BufferPosition{Line: 0, Column: 4}, End: BufferPosition{Line: 0, Column: 26}, Target: "https://例子.test/e\u0301/你"}},
		},
		{
			name: "soft wrap", cols: 12, rows: 3,
			text: "()https://example.com/path",
			want: []Link{{Start: BufferPosition{Line: 0, Column: 2}, End: BufferPosition{Line: 2, Column: 2}, Target: "https://example.com/path"}},
		},
		{
			name: "hard line boundary", cols: 32, rows: 2,
			text: "https://one.test/a\r\nhttps://two.test/b",
			want: []Link{
				{Start: BufferPosition{Line: 0, Column: 0}, End: BufferPosition{Line: 0, Column: 18}, Target: "https://one.test/a"},
				{Start: BufferPosition{Line: 1, Column: 0}, End: BufferPosition{Line: 1, Column: 18}, Target: "https://two.test/b"},
			},
		},
		{
			name: "invalid schemes", cols: 96, rows: 2,
			text: "ftp://bad http:/bad https//bad xhttps://bad HTTP://good.test",
			want: []Link{{Start: BufferPosition{Line: 0, Column: 44}, End: BufferPosition{Line: 0, Column: 60}, Target: "HTTP://good.test"}},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			terminal := New(test.cols, test.rows, 8)
			terminal.Write([]byte(test.text))
			got, truncated := terminal.Links(nil, 32)
			if truncated || !reflect.DeepEqual(got, test.want) {
				t.Fatalf("Links() = %+v truncated=%t, want %+v", got, truncated, test.want)
			}
		})
	}
}

func TestLinksIncludeScrollback(t *testing.T) {
	terminal := New(32, 2, 4)
	terminal.Write([]byte("zero\r\nhttps://history.test/a\r\none\r\ntwo"))
	links, truncated := terminal.Links(nil, 8)
	want := []Link{{Start: BufferPosition{Line: 1, Column: 0}, End: BufferPosition{Line: 1, Column: 22}, Target: "https://history.test/a"}}
	if truncated || !reflect.DeepEqual(links, want) {
		t.Fatalf("Links() = %+v truncated=%t, want %+v", links, truncated, want)
	}
}

func TestLinksLimitReportsTruncationAndReusesDestination(t *testing.T) {
	terminal := New(96, 2, 0)
	terminal.Write([]byte("https://one.test https://two.test https://three.test"))
	destination := make([]Link, 0, 2)
	links, truncated := terminal.Links(destination, 2)
	if len(links) != 2 || !truncated || cap(links) != cap(destination) {
		t.Fatalf("links=%+v truncated=%t cap=%d", links, truncated, cap(links))
	}
	if empty, truncated := terminal.Links(links, 0); len(empty) != 0 || truncated {
		t.Fatalf("zero-limit links=%+v truncated=%t", empty, truncated)
	}
}

func TestLinksAreIndependentOfUTF8WriteSplits(t *testing.T) {
	data := []byte("看：https://例子.test/e\u0301/你，后")
	want := []Link{{Start: BufferPosition{Line: 0, Column: 4}, End: BufferPosition{Line: 0, Column: 26}, Target: "https://例子.test/e\u0301/你"}}
	for split := 0; split <= len(data); split++ {
		terminal := New(64, 2, 0)
		terminal.Write(data[:split])
		terminal.Write(data[split:])
		links, truncated := terminal.Links(nil, 4)
		if truncated || !reflect.DeepEqual(links, want) {
			t.Fatalf("split %d: Links() = %+v truncated=%t, want %+v", split, links, truncated, want)
		}
	}
}

func BenchmarkLinksScrollback(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	for line := 0; line < DefaultScrollback+40; line++ {
		terminal.Write([]byte(fmt.Sprintf("%06d status from host-%04d completed without a link\r\n", line, line%1000)))
	}
	links := make([]Link, 0, 16)
	b.ReportAllocs()
	for b.Loop() {
		links, _ = terminal.Links(links[:0], 16)
	}
}

func BenchmarkLinksScrollbackOneMatch(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	for line := 0; line < DefaultScrollback+40; line++ {
		terminal.Write([]byte(fmt.Sprintf("%06d status from host-%04d completed without a link\r\n", line, line%1000)))
	}
	terminal.Write([]byte("see https://example.test/final for details"))
	links := make([]Link, 0, 16)
	b.ReportAllocs()
	for b.Loop() {
		links, _ = terminal.Links(links[:0], 16)
	}
}

func BenchmarkLinksResultLimit(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	for line := 0; line < DefaultScrollback+40; line++ {
		terminal.Write([]byte(fmt.Sprintf("%06d see https://example.test/run/%d for details\r\n", line, line)))
	}
	links := make([]Link, 0, 16)
	b.ReportAllocs()
	for b.Loop() {
		links, _ = terminal.Links(links[:0], 16)
	}
}

func BenchmarkLinksOSC8Scrollback(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	for line := 0; line < DefaultScrollback+40; line++ {
		terminal.Write([]byte(fmt.Sprintf("%06d \x1b]8;;https://example.test/run/%d\x07build result\x1b]8;;\x07\r\n", line, line)))
	}
	links := make([]Link, 0, 16)
	b.ReportAllocs()
	for b.Loop() {
		links, _ = terminal.Links(links[:0], 16)
	}
}
