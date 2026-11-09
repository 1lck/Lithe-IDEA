package term

import (
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// A reconnect keeps the screen but not the old program: the flags a program
// pushed for its shell must not be inherited by the next one.
func TestResetKeyboardDropsTheModesAndStacksOfBothScreens(t *testing.T) {
	term := newTerm(20, 3)
	feed(term, "\x1b[=1u\x1b[>2u\x1b[>4u")
	if term.KeyboardFlags() != 4 || len(term.scr.kittyStack) != 2 {
		t.Fatalf("flags=%d stack=%d before the reset", term.KeyboardFlags(), len(term.scr.kittyStack))
	}
	feed(term, "\x1b[?1049h\x1b[=8u")
	term.ResetKeyboard()
	for _, screen := range []*screen{&term.main, &term.alt} {
		if screen.kittyFlags != 0 || len(screen.kittyStack) != 0 {
			t.Fatalf("screen kept flags=%d stack=%d", screen.kittyFlags, len(screen.kittyStack))
		}
	}
}

func TestKittyKeyboardFlagsPerScreenAndStack(t *testing.T) {
	term := newTerm(20, 3)
	var replies []string
	term.SetReply(func(b []byte) { replies = append(replies, string(b)) })

	feed(term, "\x1b[=1u\x1b[?u")
	if term.KeyboardFlags() != 1 || len(replies) != 1 || replies[0] != "\x1b[?1u" {
		t.Fatalf("flags=%d replies=%q", term.KeyboardFlags(), replies)
	}
	feed(term, "\x1b[>2u\x1b[?u")
	if term.KeyboardFlags() != 2 || replies[1] != "\x1b[?2u" {
		t.Fatalf("pushed flags=%d replies=%q", term.KeyboardFlags(), replies)
	}
	feed(term, "\x1b[<u\x1b[?u")
	if term.KeyboardFlags() != 0 || replies[2] != "\x1b[?0u" {
		t.Fatalf("popped flags=%d replies=%q", term.KeyboardFlags(), replies)
	}
	feed(term, "\x1b[=1u\x1b[=2;2u")
	if term.KeyboardFlags() != 3 {
		t.Fatalf("set mode 2 left flags %d", term.KeyboardFlags())
	}
	feed(term, "\x1b[=2;3u")
	if term.KeyboardFlags() != 1 {
		t.Fatalf("set mode 3 left flags %d", term.KeyboardFlags())
	}

	feed(term, "\x1b[?1049h")
	if term.KeyboardFlags() != 0 {
		t.Fatalf("the alternate screen inherited flags %d", term.KeyboardFlags())
	}
	feed(term, "\x1b[=8u\x1b[?1049l")
	if term.KeyboardFlags() != 1 {
		t.Fatalf("the main screen lost its flags: %d", term.KeyboardFlags())
	}
	feed(term, "\x1bc")
	if term.KeyboardFlags() != 0 {
		t.Fatalf("full reset kept flags %d", term.KeyboardFlags())
	}
}

func TestEncodeKeyEventFollowsKittyProtocol(t *testing.T) {
	tests := []struct {
		name  string
		event gfx.KeyEvent
		flags uint32
		want  string
	}{
		{"legacy escape", gfx.KeyEvent{Key: gfx.KeyEscape}, 0, "\x1b"},
		{"legacy raw shifted text", gfx.KeyEvent{Modifiers: gfx.ModifierShift, Text: "x", Typed: "X"}, 0, "X"},
		{"legacy raw release", gfx.KeyEvent{Text: "x", Typed: "x", Release: true}, 0, ""},
		{"kitty escape", gfx.KeyEvent{Key: gfx.KeyEscape}, 1, "\x1b[27u"},
		{"kitty escape release", gfx.KeyEvent{Key: gfx.KeyEscape, Release: true}, 1 | 2, "\x1b[27;1:3u"},
		{"alt x", gfx.KeyEvent{Modifiers: gfx.ModifierAlt, Text: "x"}, 1, "\x1b[120;3u"},
		{"control c", gfx.KeyEvent{Modifiers: gfx.ModifierControl, Text: "c"}, 1, "\x1b[99;5u"},
		{"control shift c", gfx.KeyEvent{Modifiers: gfx.ModifierControl | gfx.ModifierShift, Text: "c", Typed: "C"}, 1, "\x1b[99;6u"},
		{"shift alt x", gfx.KeyEvent{Modifiers: gfx.ModifierShift | gfx.ModifierAlt, Text: "x", Typed: "X"}, 1, "\x1b[120;4u"},
		{"shift x stays text", gfx.KeyEvent{Modifiers: gfx.ModifierShift, Text: "x", Typed: "X"}, 1, "X"},
		{"plain x stays text", gfx.KeyEvent{Text: "x", Typed: "x"}, 1, "x"},
		{"all keys x", gfx.KeyEvent{Text: "x", Typed: "x"}, 8, "\x1b[120u"},
		{"all keys shifted x", gfx.KeyEvent{Modifiers: gfx.ModifierShift, Text: "x", Typed: "X"}, 8 | 4, "\x1b[120:88;2u"},
		{"all keys control c press", gfx.KeyEvent{Modifiers: gfx.ModifierControl, Text: "c"}, 8 | 2, "\x1b[99;5:1u"},
		{"all keys control c release", gfx.KeyEvent{Modifiers: gfx.ModifierControl, Text: "c", Release: true}, 8 | 2, "\x1b[99;5:3u"},
		{"text release without all keys", gfx.KeyEvent{Text: "x", Typed: "x", Release: true}, 1 | 2, ""},
		{"enter stays carriage return", gfx.KeyEvent{Key: gfx.KeyEnter}, 1, "\r"},
		{"shift enter is an escape code", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierShift}, 1, "\x1b[13;2u"},
		{"shift enter with event types", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierShift}, 1 | 2 | 4, "\x1b[13;2:1u"},
		{"alt enter is an escape code", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierAlt}, 1, "\x1b[13;3u"},
		{"shift enter without flags sends escape code", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierShift}, 0, "\x1b[13;2u"},
		{"shift alt enter without flags sends escape code", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierShift | gfx.ModifierAlt}, 0, "\x1b[13;4u"},
		{"control alt enter without flags sends escape code", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierControl | gfx.ModifierAlt}, 0, "\x1b[13;7u"},
		{"all keys enter", gfx.KeyEvent{Key: gfx.KeyEnter}, 8, "\x1b[13u"},
		{"all keys enter release", gfx.KeyEvent{Key: gfx.KeyEnter, Release: true}, 8 | 2, "\x1b[13;1:3u"},
		{"arrow", gfx.KeyEvent{Key: gfx.KeyUp}, 1, "\x1b[A"},
		{"control arrow", gfx.KeyEvent{Key: gfx.KeyUp, Modifiers: gfx.ModifierControl}, 1, "\x1b[1;5A"},
		{"control arrow press", gfx.KeyEvent{Key: gfx.KeyUp, Modifiers: gfx.ModifierControl}, 1 | 2, "\x1b[1;5:1A"},
		{"control arrow release", gfx.KeyEvent{Key: gfx.KeyUp, Modifiers: gfx.ModifierControl, Release: true}, 1 | 2, "\x1b[1;5:3A"},
		{"F5 press", gfx.KeyEvent{Key: gfx.KeyF5}, 1 | 2, "\x1b[15;1:1~"},
		{"insert all keys", gfx.KeyEvent{Key: gfx.KeyInsert}, 8, "\x1b[2~"},
		{"space stays text", gfx.KeyEvent{Key: gfx.KeySpace, Text: " "}, 1, " "},
		{"control space", gfx.KeyEvent{Key: gfx.KeySpace, Modifiers: gfx.ModifierControl, Text: " "}, 1, "\x1b[32;5u"},
		{"associated text", gfx.KeyEvent{Text: "x", Typed: "x"}, 8 | 16, "\x1b[120;1;120u"},
		{"shift modifier key", gfx.KeyEvent{Key: gfx.KeyShiftLeft, Modifiers: gfx.ModifierShift}, 8, "\x1b[57441;2u"},
		{"meta modifier key", gfx.KeyEvent{Key: gfx.KeyMetaLeft, Modifiers: gfx.ModifierMeta}, 8, "\x1b[57444;9u"},
		{"command chord", gfx.KeyEvent{Modifiers: gfx.ModifierMeta, Text: "x"}, 8, "\x1b[120;9u"},
		{"command chord disambiguation", gfx.KeyEvent{Modifiers: gfx.ModifierMeta, Text: "x"}, 1, "\x1b[120;9u"},
		{"command press with event types", gfx.KeyEvent{Modifiers: gfx.ModifierMeta, Text: "j"}, 1 | 2, "\x1b[106;9:1u"},
		{"command release with event types", gfx.KeyEvent{Modifiers: gfx.ModifierMeta, Text: "j", Release: true}, 1 | 2, "\x1b[106;9:3u"},
		{"command enter", gfx.KeyEvent{Key: gfx.KeyEnter, Modifiers: gfx.ModifierMeta}, 1, "\x1b[13;9u"},
		{"legacy command chord", gfx.KeyEvent{Modifiers: gfx.ModifierMeta, Text: "x"}, 0, ""},
		{"legacy command left", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta}, 0, "\x01"},
		{"legacy command left release", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta, Release: true}, 0, ""},
		{"kitty command left", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta}, 1, "\x1b[1;9D"},
		{"kitty command right", gfx.KeyEvent{Key: gfx.KeyRight, Modifiers: gfx.ModifierMeta}, 1 | 4, "\x1b[1;9C"},
		{"kitty command backspace repeat", gfx.KeyEvent{Key: gfx.KeyBackspace, Modifiers: gfx.ModifierMeta, Repeat: true}, 1 | 2, "\x1b[127;9:2u"},
		{"kitty command left release", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta, Release: true}, 1 | 2, "\x1b[1;9:3D"},
		{"kitty command shift left", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta | gfx.ModifierShift}, 1, "\x1b[1;10D"},
		{"all keys command left", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta}, 8, "\x1b[1;9D"},
		{"all keys command backspace", gfx.KeyEvent{Key: gfx.KeyBackspace, Modifiers: gfx.ModifierMeta}, 8, "\x1b[127;9u"},
		{"all keys command left press", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta}, 8 | 2, "\x1b[1;9:1D"},
		{"all keys command left release", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta, Release: true}, 8 | 2, "\x1b[1;9:3D"},
		{"all keys command shift left", gfx.KeyEvent{Key: gfx.KeyLeft, Modifiers: gfx.ModifierMeta | gfx.ModifierShift}, 8, "\x1b[1;10D"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := string(EncodeKeyEvent(test.event, test.flags, false)); got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestKittyQueryRoundTripsWithoutBreakingLegacyKeys(t *testing.T) {
	term := newTerm(20, 3)
	var replies []string
	term.SetReply(func(b []byte) { replies = append(replies, string(b)) })
	feed(term, "\x1b[>1u")
	feed(term, "\x1b[?u")
	if strings.Join(replies, "|") != "\x1b[?1u" {
		t.Fatalf("replies = %q", replies)
	}
	if got := string(EncodeKeyEvent(gfx.KeyEvent{Key: gfx.KeyEscape}, term.KeyboardFlags(), false)); got != "\x1b[27u" {
		t.Fatalf("escape with flags = %q", got)
	}
}

func TestKittySequencesMayBeSplitAcrossWrites(t *testing.T) {
	term := newTerm(20, 3)
	var replies []string
	term.SetReply(func(b []byte) { replies = append(replies, string(b)) })
	for _, part := range []string{"\x1b[=1", "u\x1b[=2;", "2u\x1b[?", "u"} {
		feed(term, part)
	}
	if term.KeyboardFlags() != 3 || strings.Join(replies, "|") != "\x1b[?3u" {
		t.Fatalf("flags=%d replies=%q", term.KeyboardFlags(), replies)
	}
}

func BenchmarkEncodeKittyKey(b *testing.B) {
	event := gfx.KeyEvent{Modifiers: gfx.ModifierControl | gfx.ModifierShift, Text: "c", Typed: "C"}
	b.ReportAllocs()
	for b.Loop() {
		_ = EncodeKeyEvent(event, 1|2|8|16, false)
	}
}
