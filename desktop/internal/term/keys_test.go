package term

import (
	"testing"

	"github.com/vivaui/viva/ui"
)

func TestEncodeKey(t *testing.T) {
	shift, alt, control, meta := ui.ModifierShift, ui.ModifierAlt, ui.ModifierControl, ui.ModifierMeta
	for _, test := range []struct {
		name      string
		key       ui.Key
		modifiers ui.Modifiers
		text      string
		appCursor bool
		want      string
	}{
		{"enter", ui.KeyEnter, 0, "", false, "\r"},
		{"shift+enter", ui.KeyEnter, shift, "", false, "\x1b[13;2u"},
		{"ctrl+enter", ui.KeyEnter, control, "", false, "\x1b[13;5u"},
		{"alt+enter", ui.KeyEnter, alt, "", false, "\x1b\r"},
		{"shift+alt+enter", ui.KeyEnter, shift | alt, "", false, "\x1b[13;4u"},
		{"ctrl+alt+enter", ui.KeyEnter, control | alt, "", false, "\x1b[13;7u"},
		{"tab", ui.KeyTab, 0, "", false, "\t"},
		{"shift+tab", ui.KeyTab, shift, "", false, "\x1b[Z"},
		{"escape", ui.KeyEscape, 0, "", false, "\x1b"},
		{"backspace", ui.KeyBackspace, 0, "", false, "\x7f"},
		{"ctrl+backspace", ui.KeyBackspace, control, "", false, "\x08"},
		{"alt+backspace deletes a word", ui.KeyBackspace, alt, "", false, "\x1b\x7f"},
		{"ctrl+space", ui.KeySpace, control, "", false, "\x00"},
		{"up", ui.KeyUp, 0, "", false, "\x1b[A"},
		{"up in application mode", ui.KeyUp, 0, "", true, "\x1bOA"},
		{"down", ui.KeyDown, 0, "", false, "\x1b[B"},
		{"right", ui.KeyRight, 0, "", false, "\x1b[C"},
		{"left", ui.KeyLeft, 0, "", false, "\x1b[D"},
		{"home", ui.KeyHome, 0, "", false, "\x1b[H"},
		{"end in application mode", ui.KeyEnd, 0, "", true, "\x1bOF"},
		{"ctrl+left", ui.KeyLeft, control, "", false, "\x1b[1;5D"},
		{"alt+right", ui.KeyRight, alt, "", false, "\x1b[1;3C"},
		{"shift+up", ui.KeyUp, shift, "", true, "\x1b[1;2A"},
		{"ctrl+shift+alt+home", ui.KeyHome, control | shift | alt, "", false, "\x1b[1;8H"},
		{"insert", ui.KeyInsert, 0, "", false, "\x1b[2~"},
		{"delete", ui.KeyDelete, 0, "", false, "\x1b[3~"},
		{"page up", ui.KeyPageUp, 0, "", false, "\x1b[5~"},
		{"page down", ui.KeyPageDown, 0, "", false, "\x1b[6~"},
		{"ctrl+delete", ui.KeyDelete, control, "", false, "\x1b[3;5~"},
		{"f1", ui.KeyF1, 0, "", false, "\x1bOP"},
		{"f4", ui.KeyF4, 0, "", false, "\x1bOS"},
		{"shift+f2", ui.KeyF2, shift, "", false, "\x1b[1;2Q"},
		{"f5", ui.KeyF5, 0, "", false, "\x1b[15~"},
		{"f10", ui.KeyF10, 0, "", false, "\x1b[21~"},
		{"f12", ui.KeyF12, 0, "", false, "\x1b[24~"},
		{"ctrl+f6", ui.KeyF6, control, "", false, "\x1b[17;5~"},
		{"ctrl+c", ui.KeyUnknown, control, "c", false, "\x03"},
		{"ctrl+C as the Shift-less base letter", ui.KeyUnknown, control, "C", false, "\x03"},
		{"ctrl+d", ui.KeyUnknown, control, "d", false, "\x04"},
		{"ctrl+z", ui.KeyUnknown, control, "z", false, "\x1a"},
		{"ctrl+[", ui.KeyUnknown, control, "[", false, "\x1b"},
		{"ctrl+\\", ui.KeyUnknown, control, "\\", false, "\x1c"},
		{"ctrl+/", ui.KeyUnknown, control, "/", false, "\x1f"},
		{"ctrl+2", ui.KeyUnknown, control, "2", false, "\x00"},
		{"ctrl+8", ui.KeyUnknown, control, "8", false, "\x7f"},
		{"ctrl+alt+c", ui.KeyUnknown, control | alt, "c", false, "\x1b\x03"},
		{"alt+x", ui.KeyUnknown, alt, "x", false, "\x1bx"},
		{"ctrl+1 has no control code", ui.KeyUnknown, control, "1", false, ""},
		{"command chords belong to the application", ui.KeyUnknown, meta, "c", false, ""},
		{"command+left goes to the start of the line", ui.KeyLeft, meta, "", false, "\x01"},
		{"command+right goes to the end of the line", ui.KeyRight, meta, "", false, "\x05"},
		{"command+backspace deletes to the start of the line", ui.KeyBackspace, meta, "", false, "\x15"},
		{"command+left ignores application cursor keys", ui.KeyLeft, meta, "", true, "\x01"},
		{"command+shift+left is not a line edit", ui.KeyLeft, meta | shift, "", false, ""},
		{"command+alt+backspace is not a line edit", ui.KeyBackspace, meta | alt, "", false, ""},
		{"command+control+right is not a line edit", ui.KeyRight, meta | control, "", false, ""},
		{"command+up stays local", ui.KeyUp, meta, "", false, ""},
		{"command+forward delete stays local", ui.KeyDelete, meta, "", false, ""},
		{"nothing at all", ui.KeyUnknown, 0, "", false, ""},
		{"a multi-character chord", ui.KeyUnknown, control, "ab", false, ""},
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
