package term

import (
	"strconv"
	"strings"

	"github.com/vivaui/viva/ui"
)

// EncodeKey turns a raw key event into the bytes a program reading a terminal
// expects, following xterm. Named keys encode by Key; a chord such as Control+C
// arrives with Key unknown and its character in text. It returns nil for keys
// that mean nothing to the program (a Command chord that is not one of the
// line edits below belongs to the application, which is why this path sends
// nothing for it; EncodeKeyEvent decides who owns the chord when the program
// reports kitty keys).
func EncodeKey(key ui.Key, modifiers ui.Modifiers, text string, appCursorKeys bool) []byte {
	if modifiers&ui.ModifierMeta != 0 {
		letter, ok := CommandLineEdit(key, modifiers)
		if !ok {
			return nil
		}
		return EncodeKey(ui.KeyUnknown, ui.ModifierControl, letter, appCursorKeys)
	}
	shift := modifiers&ui.ModifierShift != 0
	alt := modifiers&ui.ModifierAlt != 0
	control := modifiers&ui.ModifierControl != 0
	// The xterm modifier parameter: 1 plus shift 1, alt 2, control 4.
	parameter := 1
	if shift {
		parameter += 1
	}
	if alt {
		parameter += 2
	}
	if control {
		parameter += 4
	}

	prefix := func(b []byte) []byte { // Alt sends Escape first
		if alt {
			return append([]byte{0x1b}, b...)
		}
		return b
	}
	cursor := func(final byte) []byte {
		if parameter > 1 {
			return []byte("\x1b[1;" + strconv.Itoa(parameter) + string(final))
		}
		if appCursorKeys {
			return []byte{0x1b, 'O', final}
		}
		return []byte{0x1b, '[', final}
	}
	tilde := func(number int) []byte {
		if parameter > 1 {
			return []byte("\x1b[" + strconv.Itoa(number) + ";" + strconv.Itoa(parameter) + "~")
		}
		return []byte("\x1b[" + strconv.Itoa(number) + "~")
	}
	function := func(final byte) []byte { // F1-F4 are SS3 sequences
		if parameter > 1 {
			return []byte("\x1b[1;" + strconv.Itoa(parameter) + string(final))
		}
		return []byte{0x1b, 'O', final}
	}

	switch key {
	case ui.KeyEnter:
		if parameter > 1 && (!alt || shift || control) {
			return []byte("\x1b[13;" + strconv.Itoa(parameter) + "u")
		}
		return prefix([]byte{'\r'})
	case ui.KeyTab:
		if shift {
			return []byte("\x1b[Z")
		}
		return prefix([]byte{'\t'})
	case ui.KeyEscape:
		return prefix([]byte{0x1b})
	case ui.KeyBackspace:
		if control {
			return prefix([]byte{0x08})
		}
		return prefix([]byte{0x7f})
	case ui.KeySpace:
		if control {
			return prefix([]byte{0})
		}
		return prefix([]byte{' '})
	case ui.KeyUp:
		return cursor('A')
	case ui.KeyDown:
		return cursor('B')
	case ui.KeyRight:
		return cursor('C')
	case ui.KeyLeft:
		return cursor('D')
	case ui.KeyHome:
		return cursor('H')
	case ui.KeyEnd:
		return cursor('F')
	case ui.KeyInsert:
		return tilde(2)
	case ui.KeyDelete:
		return tilde(3)
	case ui.KeyPageUp:
		return tilde(5)
	case ui.KeyPageDown:
		return tilde(6)
	case ui.KeyF1, ui.KeyF2, ui.KeyF3, ui.KeyF4:
		return function(byte('P' + (key - ui.KeyF1)))
	case ui.KeyF5, ui.KeyF6, ui.KeyF7, ui.KeyF8, ui.KeyF9, ui.KeyF10, ui.KeyF11, ui.KeyF12:
		return tilde(functionNumbers[key-ui.KeyF5])
	}

	if key != ui.KeyUnknown || text == "" {
		return nil
	}
	// A chord: its character with the modifiers applied.
	runes := []rune(text)
	if len(runes) != 1 {
		return nil
	}
	character := runes[0]
	if control {
		code, ok := controlCode(character)
		if !ok {
			return nil
		}
		return prefix([]byte{code})
	}
	return prefix([]byte(string(character)))
}

// CommandLineEdit is the letter of the Control chord that Command+Left,
// Command+Right and Command+Backspace stand for: Ctrl+A and Ctrl+E move to the
// start and the end of the line, Ctrl+U deletes back to its start. Shells and
// full-screen programs understand them without any setup, unlike Home and End.
// Any other chord, one with a further modifier included, is not a line edit.
func CommandLineEdit(key ui.Key, modifiers ui.Modifiers) (string, bool) {
	if modifiers != ui.ModifierMeta {
		return "", false
	}
	switch key {
	case ui.KeyLeft:
		return "a", true
	case ui.KeyRight:
		return "e", true
	case ui.KeyBackspace:
		return "u", true
	}
	return "", false
}

// functionNumbers are the tilde-sequence numbers of F5-F12.
var functionNumbers = [...]int{15, 17, 18, 19, 20, 21, 23, 24}

// controlCode is the C0 control character Control produces with character.
func controlCode(character rune) (byte, bool) {
	switch {
	case character >= 'a' && character <= 'z':
		return byte(character-'a') + 1, true
	case character >= 'A' && character <= 'Z':
		return byte(character-'A') + 1, true
	}
	switch character {
	case '@', ' ', '2':
		return 0x00, true
	case '[', '3':
		return 0x1b, true
	case '\\', '4':
		return 0x1c, true
	case ']', '5':
		return 0x1d, true
	case '^', '6', '~':
		return 0x1e, true
	case '_', '/', '7':
		return 0x1f, true
	case '?', '8':
		return 0x7f, true
	}
	return 0, false
}

// EncodePaste prepares pasted text for the program: line breaks become the
// carriage return Enter sends, and with bracketed paste on the text is wrapped
// in the markers that tell the program it was pasted. A paste cannot smuggle in
// the end marker.
func EncodePaste(text string, bracketed bool) []byte {
	text = strings.ReplaceAll(text, "\r\n", "\r")
	text = strings.ReplaceAll(text, "\n", "\r")
	if !bracketed {
		return []byte(text)
	}
	text = strings.ReplaceAll(text, "\x1b[201~", "")
	out := make([]byte, 0, len(text)+12)
	out = append(out, "\x1b[200~"...)
	out = append(out, text...)
	return append(out, "\x1b[201~"...)
}
