package term

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestEncodeKey(t *testing.T) {
	shift, alt, control, meta := gfx.ModifierShift, gfx.ModifierAlt, gfx.ModifierControl, gfx.ModifierMeta
	for _, test := range []struct {
		name      string
		key       gfx.Key
		modifiers gfx.Modifiers
		text      string
		appCursor bool
		want      string
	}{
		{"enter", gfx.KeyEnter, 0, "", false, "\r"},
		{"shift+enter", gfx.KeyEnter, shift, "", false, "\x1b[13;2u"},
		{"ctrl+enter", gfx.KeyEnter, control, "", false, "\x1b[13;5u"},
		{"alt+enter", gfx.KeyEnter, alt, "", false, "\x1b\r"},
		{"shift+alt+enter", gfx.KeyEnter, shift | alt, "", false, "\x1b[13;4u"},
		{"ctrl+alt+enter", gfx.KeyEnter, control | alt, "", false, "\x1b[13;7u"},
		{"tab", gfx.KeyTab, 0, "", false, "\t"},
		{"shift+tab", gfx.KeyTab, shift, "", false, "\x1b[Z"},
		{"escape", gfx.KeyEscape, 0, "", false, "\x1b"},
		{"backspace", gfx.KeyBackspace, 0, "", false, "\x7f"},
		{"ctrl+backspace", gfx.KeyBackspace, control, "", false, "\x08"},
		{"alt+backspace deletes a word", gfx.KeyBackspace, alt, "", false, "\x1b\x7f"},
		{"ctrl+space", gfx.KeySpace, control, "", false, "\x00"},
		{"up", gfx.KeyUp, 0, "", false, "\x1b[A"},
		{"up in application mode", gfx.KeyUp, 0, "", true, "\x1bOA"},
		{"down", gfx.KeyDown, 0, "", false, "\x1b[B"},
		{"right", gfx.KeyRight, 0, "", false, "\x1b[C"},
		{"left", gfx.KeyLeft, 0, "", false, "\x1b[D"},
		{"home", gfx.KeyHome, 0, "", false, "\x1b[H"},
		{"end in application mode", gfx.KeyEnd, 0, "", true, "\x1bOF"},
		{"ctrl+left", gfx.KeyLeft, control, "", false, "\x1b[1;5D"},
		{"alt+right", gfx.KeyRight, alt, "", false, "\x1b[1;3C"},
		{"shift+up", gfx.KeyUp, shift, "", true, "\x1b[1;2A"},
		{"ctrl+shift+alt+home", gfx.KeyHome, control | shift | alt, "", false, "\x1b[1;8H"},
		{"insert", gfx.KeyInsert, 0, "", false, "\x1b[2~"},
		{"delete", gfx.KeyDelete, 0, "", false, "\x1b[3~"},
		{"page up", gfx.KeyPageUp, 0, "", false, "\x1b[5~"},
		{"page down", gfx.KeyPageDown, 0, "", false, "\x1b[6~"},
		{"ctrl+delete", gfx.KeyDelete, control, "", false, "\x1b[3;5~"},
		{"f1", gfx.KeyF1, 0, "", false, "\x1bOP"},
		{"f4", gfx.KeyF4, 0, "", false, "\x1bOS"},
		{"shift+f2", gfx.KeyF2, shift, "", false, "\x1b[1;2Q"},
		{"f5", gfx.KeyF5, 0, "", false, "\x1b[15~"},
		{"f10", gfx.KeyF10, 0, "", false, "\x1b[21~"},
		{"f12", gfx.KeyF12, 0, "", false, "\x1b[24~"},
		{"ctrl+f6", gfx.KeyF6, control, "", false, "\x1b[17;5~"},
		{"ctrl+c", gfx.KeyUnknown, control, "c", false, "\x03"},
		{"ctrl+C as the Shift-less base letter", gfx.KeyUnknown, control, "C", false, "\x03"},
		{"ctrl+d", gfx.KeyUnknown, control, "d", false, "\x04"},
		{"ctrl+z", gfx.KeyUnknown, control, "z", false, "\x1a"},
		{"ctrl+[", gfx.KeyUnknown, control, "[", false, "\x1b"},
		{"ctrl+\\", gfx.KeyUnknown, control, "\\", false, "\x1c"},
		{"ctrl+/", gfx.KeyUnknown, control, "/", false, "\x1f"},
		{"ctrl+2", gfx.KeyUnknown, control, "2", false, "\x00"},
		{"ctrl+8", gfx.KeyUnknown, control, "8", false, "\x7f"},
		{"ctrl+alt+c", gfx.KeyUnknown, control | alt, "c", false, "\x1b\x03"},
		{"alt+x", gfx.KeyUnknown, alt, "x", false, "\x1bx"},
		{"ctrl+1 has no control code", gfx.KeyUnknown, control, "1", false, ""},
		{"command chords belong to the application", gfx.KeyUnknown, meta, "c", false, ""},
		{"command+left goes to the start of the line", gfx.KeyLeft, meta, "", false, "\x01"},
		{"command+right goes to the end of the line", gfx.KeyRight, meta, "", false, "\x05"},
		{"command+backspace deletes to the start of the line", gfx.KeyBackspace, meta, "", false, "\x15"},
		{"command+left ignores application cursor keys", gfx.KeyLeft, meta, "", true, "\x01"},
		{"command+shift+left is not a line edit", gfx.KeyLeft, meta | shift, "", false, ""},
		{"command+alt+backspace is not a line edit", gfx.KeyBackspace, meta | alt, "", false, ""},
		{"command+control+right is not a line edit", gfx.KeyRight, meta | control, "", false, ""},
		{"command+up stays local", gfx.KeyUp, meta, "", false, ""},
		{"command+forward delete stays local", gfx.KeyDelete, meta, "", false, ""},
		{"nothing at all", gfx.KeyUnknown, 0, "", false, ""},
		{"a multi-character chord", gfx.KeyUnknown, control, "ab", false, ""},
	} {
		got := string(EncodeKey(test.key, test.modifiers, test.text, test.appCursor))
		if got != test.want {
			t.Errorf("%s: %q, want %q", test.name, got, test.want)
		}
	}
}

func TestEncodePaste(t *testing.T) {
	for _, test := range []struct {
		name      string
		text      string
		bracketed bool
		want      string
	}{
		{"plain text", "ls -la", false, "ls -la"},
		{"line breaks become returns", "a\nb\r\nc", false, "a\rb\rc"},
		{"bracketed", "echo hi\n", true, "\x1b[200~echo hi\r\x1b[201~"},
		{"the end marker cannot be smuggled in", "x\x1b[201~rm -rf ~", true, "\x1b[200~xrm -rf ~\x1b[201~"},
		{"empty", "", true, "\x1b[200~\x1b[201~"},
		{"CJK is untouched", "你好", false, "你好"},
	} {
		if got := string(EncodePaste(test.text, test.bracketed)); got != test.want {
			t.Errorf("%s: %q, want %q", test.name, got, test.want)
		}
	}
}
