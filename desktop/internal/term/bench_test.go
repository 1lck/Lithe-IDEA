package term

import (
	"strings"
	"testing"
)

func benchWrite(b *testing.B, stream []byte) {
	term := New(120, 40, DefaultScrollback)
	b.ReportAllocs()
	cpu := startCPU()
	for b.Loop() {
		term.Write(stream)
	}
	cpu.report(b, len(stream))
}

// Plain text flooding the screen, as `cat` of a log file does.
func BenchmarkWritePlainText(b *testing.B) {
	line := strings.Repeat("The quick brown fox jumps over the lazy dog. ", 3)[:100] + "\r\n"
	benchWrite(b, []byte(strings.Repeat(line, 1000)))
}

// Colored output, as `ls --color` or a build log: an SGR pair every few bytes.
func BenchmarkWriteColoredText(b *testing.B) {
	line := "\x1b[01;34mdirectory\x1b[0m  \x1b[01;32mexecutable\x1b[0m  plain.txt  \x1b[38;5;208marchive.tar.gz\x1b[0m  \x1b[48;2;10;20;30mhighlight\x1b[0m\r\n"
	benchWrite(b, []byte(strings.Repeat(line, 1000)))
}

func BenchmarkWriteCJKText(b *testing.B) {
	line := strings.Repeat("中文输出和 mixed English 文字，", 5) + "\r\n"
	benchWrite(b, []byte(strings.Repeat(line, 1000)))
}

// Lines scrolling the whole way through the scrollback, as `seq` or a build log
// does: every row is trimmed, pushed and recycled, not just drawn.
func BenchmarkWriteScrollback(b *testing.B) {
	var sb strings.Builder
	for i := range 20000 {
		sb.WriteString(itoa(i) + "\r\n")
	}
	benchWrite(b, []byte(sb.String()))
}

// Full-width lines through the scrollback: trimming and recycling touch the
// whole row, so this is the worst case for both.
func BenchmarkWriteScrollbackWide(b *testing.B) {
	benchWrite(b, []byte(strings.Repeat(strings.Repeat("x", 119)+"\r\n", 20000)))
}

// Cursor-addressed redraws, as vim or htop do: every cell positioned and styled.
func BenchmarkWriteFullScreenRedraw(b *testing.B) {
	var sb strings.Builder
	sb.WriteString("\x1b[H")
	for row := 1; row <= 40; row++ {
		sb.WriteString("\x1b[" + itoa(row) + ";1H\x1b[7m status \x1b[0m\x1b[K some text on this row \x1b[32mgreen\x1b[0m")
	}
	benchWrite(b, []byte(sb.String()))
}

func itoa(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}

// Reading a row costs nothing: it is a view into the grid.
func BenchmarkRow(b *testing.B) {
	term := New(120, 40, 100)
	term.Write([]byte(strings.Repeat("x", 120*40)))
	b.ReportAllocs()
	var sink Row
	for b.Loop() {
		for y := 0; y < 40; y++ {
			sink = term.Row(y)
		}
	}
	_ = sink
}
