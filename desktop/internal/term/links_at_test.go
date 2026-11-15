package term

import (
	"fmt"
	"testing"
)

// linkAtPosition is the contract Links and LinksAt share: the link whose Start
// is at or before position and whose End is after it.
func linkAtPosition(t *testing.T, terminal *Terminal, position BufferPosition) (Link, bool) {
	t.Helper()
	links, _ := terminal.Links(nil, 1<<16)
	for _, link := range links {
		if !linkPositionLess(position, link.Start) && linkPositionLess(position, link.End) {
			return link, true
		}
	}
	return Link{}, false
}

// TestLinksAtMatchesLinksForEveryPosition proves the group scan returns the
// same answer as the full scrollback scan at every cell, including OSC 8 links,
// soft wraps, wide characters, marks and hidden cells.
func TestLinksAtMatchesLinksForEveryPosition(t *testing.T) {
	terminals := map[string]func() *Terminal{
		"plain": func() *Terminal {
			terminal := New(12, 3, 20)
			terminal.Write([]byte("one https://a.test/x two\r\nthree four five\r\nsix\r\n"))
			return terminal
		},
		"soft wrap": func() *Terminal {
			terminal := New(8, 2, 20)
			terminal.Write([]byte("prefix https://example.test/a/very/long/path tail"))
			return terminal
		},
		"osc8": func() *Terminal {
			terminal := New(10, 3, 20)
			terminal.Write([]byte("\x1b]8;;https://one.test/a\x07link text\x1b]8;;\x07 and plain\r\n"))
			terminal.Write([]byte("\x1b]8;;https://two.test/b\x07wrap\x1b]8;;\x07ped text that wraps\r\n"))
			return terminal
		},
		"wide and marks": func() *Terminal {
			terminal := New(7, 3, 20)
			terminal.Write([]byte("你e\u0301 https://wide.test/路径 界 ok\r\n"))
			return terminal
		},
		"punctuation": func() *Terminal {
			terminal := New(20, 2, 20)
			terminal.Write([]byte("(see https://paren.test/a), then https://dot.test/b.\r\n"))
			return terminal
		},
		"scrollback": func() *Terminal {
			terminal := New(16, 2, 40)
			for line := 0; line < 30; line++ {
				terminal.Write([]byte(fmt.Sprintf("line %02d https://scroll.test/%02d done\r\n", line, line)))
			}
			return terminal
		},
	}
	for name, build := range terminals {
		terminal := build()
		total := terminal.bufferLineCount()
		links, _ := terminal.Links(nil, 1<<16)
		for line := 0; line < total; line++ {
			width := retainedLineUsedCells(terminal.bufferLine(line))
			for column := 0; column <= width; column++ {
				position := BufferPosition{Line: line, Column: column}
				want, wantOK := linkAtPosition(t, terminal, position)
				got, gotOK := terminal.LinksAt(position)
				if wantOK != gotOK {
					t.Fatalf("%s at %v: LinksAt ok=%t, full scan ok=%t (links %+v)", name, position, gotOK, wantOK, links)
				}
				if wantOK && got.Target != want.Target {
					t.Fatalf("%s at %v: LinksAt target %q, full scan %q", name, position, got.Target, want.Target)
				}
			}
		}
		// Positions outside the buffer have no link.
		if _, ok := terminal.LinksAt(BufferPosition{Line: total, Column: 0}); ok {
			t.Fatalf("%s: a position past the buffer found a link", name)
		}
		if _, ok := terminal.LinksAt(BufferPosition{Line: -1, Column: 0}); ok {
			t.Fatalf("%s: a negative position found a link", name)
		}
	}
}

// BenchmarkLinksAtScrollback measures a hover over the last line of a full
// scrollback: the group scan should cost a screen line, not 5000 of them.
func BenchmarkLinksAtScrollback(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	for line := 0; line < DefaultScrollback+40; line++ {
		terminal.Write([]byte(fmt.Sprintf("%06d status from host-%04d completed without a link\r\n", line, line%1000)))
	}
	position := BufferPosition{Line: terminal.bufferLineCount() - 1, Column: 10}
	b.ReportAllocs()
	for b.Loop() {
		terminal.LinksAt(position)
	}
}
