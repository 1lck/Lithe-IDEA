package term

import (
	"strconv"
	"strings"

	"github.com/vivaui/viva/gfx"
)

// EncodeKey turns a raw key event into the bytes a program reading a terminal
// expects, following xterm. Named keys encode by Key; a chord such as Control+C
// arrives with Key unknown and its character in text. It returns nil for keys
// that mean nothing to the program (a Command chord that is not one of the
// line edits below belongs to the application, which is why this path sends
// nothing for it; EncodeKeyEvent decides who owns the chord when the program
// reports kitty keys).
func EncodeKey(key gfx.Key, modifiers gfx.Modifiers, text string, appCursorKeys bool) []byte {
	if modifiers&gfx.ModifierMeta != 0 {
		letter, ok := CommandLineEdit(key, modifiers)
		if !ok {
			return nil
		}
		return EncodeKey(gfx.KeyUnknown, gfx.ModifierControl, letter, appCursorKeys)
	}
	shift := modifiers&gfx.ModifierShift != 0
	alt := modifiers&gfx.ModifierAlt != 0
	control := modifiers&gfx.ModifierControl != 0
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
	case gfx.KeyEnter:
		if parameter > 1 && (!alt || shift || control) {
			return []byte("\x1b[13;" + strconv.Itoa(parameter) + "u")
		}
		return prefix([]byte{'\r'})
	case gfx.KeyTab:
		if shift {
			return []byte("\x1b[Z")
		}
		return prefix([]byte{'\t'})
	case gfx.KeyEscape:
		return prefix([]byte{0x1b})
	case gfx.KeyBackspace:
		if control {
			return prefix([]byte{0x08})
		}
		return prefix([]byte{0x7f})
	case gfx.KeySpace:
		if control {
			return prefix([]byte{0})
		}
		return prefix([]byte{' '})
	case gfx.KeyUp:
		return cursor('A')
	case gfx.KeyDown:
		return cursor('B')
	case gfx.KeyRight:
		return cursor('C')
	case gfx.KeyLeft:
		return cursor('D')
	case gfx.KeyHome:
		return cursor('H')
	case gfx.KeyEnd:
		return cursor('F')
	case gfx.KeyInsert:
		return tilde(2)
	case gfx.KeyDelete:
		return tilde(3)
	case gfx.KeyPageUp:
		return tilde(5)
	case gfx.KeyPageDown:
		return tilde(6)
	case gfx.KeyF1, gfx.KeyF2, gfx.KeyF3, gfx.KeyF4:
		return function(byte('P' + (key - gfx.KeyF1)))
	case gfx.KeyF5, gfx.KeyF6, gfx.KeyF7, gfx.KeyF8, gfx.KeyF9, gfx.KeyF10, gfx.KeyF11, gfx.KeyF12:
		return tilde(functionNumbers[key-gfx.KeyF5])
	}

	if key != gfx.KeyUnknown || text == "" {
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
func CommandLineEdit(key gfx.Key, modifiers gfx.Modifiers) (string, bool) {
	if modifiers != gfx.ModifierMeta {
		return "", false
	}
	switch key {
	case gfx.KeyLeft:
		return "a", true
	case gfx.KeyRight:
		return "e", true
	case gfx.KeyBackspace:
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
