package term

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestOSC52ClipboardWriteAndInputSplits(t *testing.T) {
	sequence := []byte("\x1b]52;c;5L2g5aW977yM5LiW55WM\x1b\\")
	for split := 0; split <= len(sequence); split++ {
		terminal := New(20, 2, 0)
		var writes []ClipboardWrite
		terminal.SetClipboardWrite(func(write ClipboardWrite) { writes = append(writes, write) })
		terminal.Write(sequence[:split])
		terminal.Write(sequence[split:])
		if len(writes) != 1 || writes[0].Selection != "c" || writes[0].Text != "你好，世界" {
			t.Fatalf("split %d: writes = %+v", split, writes)
		}
	}
}

func TestOSC52ClipboardWriteAcceptsDefaultSelectionRawBase64AndClear(t *testing.T) {
	terminal := New(20, 2, 0)
	var writes []ClipboardWrite
	terminal.SetClipboardWrite(func(write ClipboardWrite) { writes = append(writes, write) })
	terminal.Write([]byte("\x1b]52;;SGVsbG8\x07\x1b]52;pc;\x07"))
	if len(writes) != 2 || writes[0] != (ClipboardWrite{Selection: "c", Text: "Hello"}) || writes[1] != (ClipboardWrite{Selection: "pc", Text: ""}) {
		t.Fatalf("writes = %+v", writes)
	}
}

func TestOSC52NeverReadsOrLeaksClipboard(t *testing.T) {
	terminal := New(20, 2, 0)
	writes := 0
	replies := 0
	terminal.SetClipboardWrite(func(ClipboardWrite) { writes++ })
	terminal.SetReply(func([]byte) { replies++ })
	terminal.Write([]byte("\x1b]52;c;?\x07\x1b]52;p;U2VjcmV0\x07\x1b]52;x;U2VjcmV0\x07"))
	if writes != 0 || replies != 0 {
		t.Fatalf("OSC 52 queries produced writes=%d replies=%d", writes, replies)
	}
}

func TestOSC52RejectsMalformedAndOversizedPayloads(t *testing.T) {
	terminal := New(20, 2, 0)
	writes := 0
	terminal.SetClipboardWrite(func(ClipboardWrite) { writes++ })
	invalidUTF8 := base64.StdEncoding.EncodeToString([]byte{0xff, 0xfe})
	withNUL := base64.StdEncoding.EncodeToString([]byte("a\x00b"))
	for _, sequence := range []string{
		"\x1b]52;c;%%%\x07",
		"\x1b]52;c;" + invalidUTF8 + "\x07",
		"\x1b]52;c;" + withNUL + "\x07",
		"\x1b]52;ccccccccccccccccc;QQ==\x07",
		"\x1b]52;c;" + base64.StdEncoding.EncodeToString([]byte(strings.Repeat("a", maxClipboardText+1))) + "\x07",
	} {
		terminal.Write([]byte(sequence))
	}
	if writes != 0 {
		t.Fatalf("malformed OSC 52 produced %d writes", writes)
	}
}

// TestOSC52CarriesASelectionLongerThanAnyOtherOSC checks that a copy of more
// than a screen, or of a table drawn with box characters (three bytes each),
// reaches the clipboard whole, whether it arrives in one Write or a byte at a
// time, and that an ordinary OSC string keeps the short limit after it.
func TestOSC52CarriesASelectionLongerThanAnyOtherOSC(t *testing.T) {
	var table strings.Builder
	table.WriteString("┌──────────┬──────────┐\n")
	for row := range 400 {
		table.WriteString("│ 第 " + strings.Repeat("行", row%5) + " │ value    │\n")
	}
	table.WriteString("└──────────┴──────────┘")
	text := table.String()
	sequence := "\x1b]52;c;" + base64.StdEncoding.EncodeToString([]byte(text)) + "\x1b\\"
	if len(sequence) <= 4*maxOSC {
		t.Fatalf("the test selection is only %d bytes encoded", len(sequence))
	}
	for _, chunk := range []int{len(sequence), 1, 7, 4093} {
		terminal := New(20, 2, 0)
		var writes []ClipboardWrite
		terminal.SetClipboardWrite(func(write ClipboardWrite) { writes = append(writes, write) })
		for start := 0; start < len(sequence); start += chunk {
			terminal.Write([]byte(sequence[start:min(start+chunk, len(sequence))]))
		}
		if len(writes) != 1 || writes[0].Text != text {
			t.Fatalf("chunk %d: %d writes, first %d bytes of %d", chunk, len(writes), len(firstText(writes)), len(text))
		}
		terminal.Write([]byte("\x1b]0;" + strings.Repeat("t", maxOSC+1) + "\x07\x1b]0;ok\x07"))
		if terminal.Title() != "ok" {
			t.Fatalf("chunk %d: title after an overlong one = %q", chunk, terminal.Title())
		}
	}
}

func firstText(writes []ClipboardWrite) string {
	if len(writes) == 0 {
		return ""
	}
	return writes[0].Text
}

func FuzzOSC52(f *testing.F) {
	f.Add("c", []byte("hello"), true)
	f.Add("", []byte("你好"), false)
	f.Add("p", []byte("ignored"), true)
	f.Fuzz(func(t *testing.T, selection string, value []byte, padded bool) {
		if len(selection) > 32 || len(value) > maxClipboardText*2 {
			t.Skip()
		}
		encoding := base64.RawStdEncoding
		if padded {
			encoding = base64.StdEncoding
		}
		sequence := "\x1b]52;" + selection + ";" + encoding.EncodeToString(value) + "\x07"
		terminal := New(20, 2, 0)
		terminal.SetClipboardWrite(func(write ClipboardWrite) {
			if len(write.Text) > maxClipboardText || !strings.Contains(write.Selection, "c") {
				t.Fatalf("unbounded or non-clipboard write: %+v", write)
			}
		})
		terminal.Write([]byte(sequence))
	})
}

func BenchmarkOSC52ClipboardWrite(b *testing.B) {
	terminal := New(80, 24, DefaultScrollback)
	terminal.SetClipboardWrite(func(ClipboardWrite) {})
	sequence := []byte("\x1b]52;c;cmVtb3RlIHRleHQ=\x07")
	b.ReportAllocs()
	for b.Loop() {
		terminal.Write(sequence)
	}
}
