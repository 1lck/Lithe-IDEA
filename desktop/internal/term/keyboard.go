package term

import (
	"strconv"
	"unicode/utf8"

	"github.com/vivaui/viva/gfx"
)

// The kitty keyboard protocol's progressive enhancement flags. Every one of
// them is implemented; bits a future version adds are ignored.
const kittySupportedFlags = 0x1f

// kittyMaxStack bounds the push stack of one screen, so a program cannot grow
// it without limit.
const kittyMaxStack = 32

// KeyboardFlags returns the kitty keyboard enhancement flags of the active
// screen: the value the program would get from CSI ? u.
func (t *Terminal) KeyboardFlags() uint32 { return t.scr.kittyFlags }

// ResetKeyboard drops both screens' kitty keyboard modes and stacks. A screen
// keeps them across a reconnect, so a new shell must start from the terminal's
// defaults instead of inheriting a program's negotiation.
func (t *Terminal) ResetKeyboard() {
	for _, screen := range []*screen{&t.main, &t.alt} {
		screen.kittyFlags = 0
		screen.kittyStack = screen.kittyStack[:0]
	}
}

// answerKittyFlags answers CSI ? u with the active screen's flags.
func (t *Terminal) answerKittyFlags() {
	b := append(t.scratch[:0], "\x1b[?"...)
	b = strconv.AppendUint(b, uint64(t.scr.kittyFlags), 10)
	t.send(append(b, 'u'))
}

// kittySet applies CSI = flags ; mode u. Mode 1 replaces the flags, 2 adds
// them, 3 removes them; an omitted or unknown mode replaces them, as the
// protocol's default is 1.
func (t *Terminal) kittySet(flags uint32, mode int) {
	flags &= kittySupportedFlags
	switch mode {
	case 2:
		t.scr.kittyFlags |= flags
	case 3:
		t.scr.kittyFlags &^= flags
	default:
		t.scr.kittyFlags = flags
	}
}

// kittyPush applies CSI > flags u: save the current flags, then make flags
// current. A full stack evicts its oldest entry.
func (t *Terminal) kittyPush(flags uint32) {
	flags &= kittySupportedFlags
	screen := t.scr
	screen.kittyStack = append(screen.kittyStack, screen.kittyFlags)
	if len(screen.kittyStack) > kittyMaxStack {
		copy(screen.kittyStack, screen.kittyStack[1:])
		screen.kittyStack = screen.kittyStack[:kittyMaxStack]
	}
	screen.kittyFlags = flags
}

// kittyPop applies CSI < number u. Popping empties the stack, or asking for
// more entries than it holds, resets the flags.
func (t *Terminal) kittyPop(count int) {
	screen := t.scr
	for ; count > 0 && len(screen.kittyStack) > 0; count-- {
		screen.kittyFlags = screen.kittyStack[len(screen.kittyStack)-1]
		screen.kittyStack = screen.kittyStack[:len(screen.kittyStack)-1]
	}
	if len(screen.kittyStack) == 0 {
		screen.kittyFlags = 0
	}
}

// EncodeKeyEvent turns one key event into the bytes a program reading the
// terminal expects. flags is the active screen's kitty keyboard enhancement
// flags; with no flags it is exactly EncodeKey.
// Application shortcut ownership is decided by the caller, not the encoder.
func EncodeKeyEvent(event gfx.KeyEvent, flags uint32, appCursorKeys bool) []byte {
	flags &= kittySupportedFlags
	if flags == 0 {
		if event.Release {
			return nil
		}
		// Raw printable keys carry their shifted text in Typed; legacy text
		// events do not set it, so this only matters across a mode change.
		if event.Key == gfx.KeyUnknown && event.Typed != "" && event.Modifiers&(gfx.ModifierControl|gfx.ModifierAlt|gfx.ModifierMeta) == 0 {
			return []byte(event.Typed)
		}
		return EncodeKey(event.Key, event.Modifiers, event.Text, appCursorKeys)
	}
	if event.Key.IsModifier() && flags&8 == 0 {
		return nil
	}
	if event.Release && flags&2 == 0 {
		return nil
	}

	named, namedOK := kittyNamedKey(event.Key)
	textCode, textOK := kittyTextCode(event.Key, event.Text)
	if !namedOK && !textOK {
		return nil
	}
	code := textCode
	if namedOK {
		code = named.code
	}
	// Unmodified Enter, Tab and Backspace keep their legacy bytes unless the
	// program asked for all keys as escape codes, so a shell still understands
	// them after a program that changed the mode exits. With Shift, Alt or
	// Control they have no legacy form to preserve, and programs such as Codex
	// tell Shift+Enter (newline) from Enter (submit) only by its escape code.
	plain := event.Modifiers&(gfx.ModifierShift|gfx.ModifierAlt|gfx.ModifierControl|gfx.ModifierMeta) == 0
	exception := plain && (event.Key == gfx.KeyEnter || event.Key == gfx.KeyTab || event.Key == gfx.KeyBackspace)
	if namedOK && exception && flags&8 == 0 {
		if event.Release {
			return nil
		}
		return EncodeKey(event.Key, event.Modifiers, event.Text, appCursorKeys)
	}
	csiu := kittyUsesCSI(event, flags, namedOK, exception)
	eventType, includeEvent := 1, flags&2 != 0
	if includeEvent && event.Release {
		eventType = 3
	} else if includeEvent && event.Repeat {
		eventType = 2
	}
	mods := kittyModifiers(event.Modifiers)

	if !csiu {
		if event.Release {
			return nil
		}
		if namedOK {
			return EncodeKey(event.Key, event.Modifiers, event.Text, appCursorKeys)
		}
		text := event.Typed
		if text == "" {
			text = event.Text
		}
		if text == "" {
			return nil
		}
		if event.Modifiers&(gfx.ModifierControl|gfx.ModifierAlt) != 0 {
			return EncodeKey(event.Key, event.Modifiers, event.Text, appCursorKeys)
		}
		return []byte(text)
	}

	if namedOK && named.final != 0 {
		return appendKittyFunctional(nil, named.final, 0, false, mods, eventType, includeEvent)
	}
	if namedOK && named.tilde {
		return appendKittyFunctional(nil, 0, named.code, true, mods, eventType, includeEvent)
	}

	shifted, hasShifted := 0, false
	if flags&4 != 0 && !namedOK && event.Modifiers&gfx.ModifierShift != 0 && event.Typed != "" {
		if character, size := utf8.DecodeRuneInString(event.Typed); size == len(event.Typed) && character != utf8.RuneError && int(character) != code {
			shifted, hasShifted = int(character), true
		}
	}
	text := ""
	if flags&16 != 0 && flags&8 != 0 && !event.Release {
		text = kittyTextCodepoints(event.Typed)
	}
	return appendKittyCSI(nil, code, shifted, hasShifted, mods, eventType, includeEvent, text, text != "")
}

// kittyUsesCSI reports whether a key event must use the kitty escape form
// rather than legacy bytes.
func kittyUsesCSI(event gfx.KeyEvent, flags uint32, named, exception bool) bool {
	if flags&8 != 0 || event.Modifiers&gfx.ModifierMeta != 0 {
		return true
	}
	if named {
		// Unmodified Enter, Tab and Backspace are the protocol's legacy
		// exceptions.
		if exception {
			return false
		}
		return flags&(1|2) != 0
	}
	return flags&1 != 0 && event.Modifiers&(gfx.ModifierControl|gfx.ModifierAlt) != 0
}

// kittyNamedKey maps a non-text key to its kitty functional code or final.
type kittyKeySpec struct {
	code  int
	final byte
	tilde bool
}

func kittyNamedKey(key gfx.Key) (kittyKeySpec, bool) {
	switch key {
	case gfx.KeyEscape:
		return kittyKeySpec{code: 27}, true
	case gfx.KeyEnter:
		return kittyKeySpec{code: 13}, true
	case gfx.KeyTab:
		return kittyKeySpec{code: 9}, true
	case gfx.KeyBackspace:
		return kittyKeySpec{code: 127}, true
	case gfx.KeyUp:
		return kittyKeySpec{code: 1, final: 'A'}, true
	case gfx.KeyDown:
		return kittyKeySpec{code: 1, final: 'B'}, true
	case gfx.KeyRight:
		return kittyKeySpec{code: 1, final: 'C'}, true
	case gfx.KeyLeft:
		return kittyKeySpec{code: 1, final: 'D'}, true
	case gfx.KeyHome:
		return kittyKeySpec{code: 1, final: 'H'}, true
	case gfx.KeyEnd:
		return kittyKeySpec{code: 1, final: 'F'}, true
	case gfx.KeyInsert:
		return kittyKeySpec{code: 2, tilde: true}, true
	case gfx.KeyDelete:
		return kittyKeySpec{code: 3, tilde: true}, true
	case gfx.KeyPageUp:
		return kittyKeySpec{code: 5, tilde: true}, true
	case gfx.KeyPageDown:
		return kittyKeySpec{code: 6, tilde: true}, true
	case gfx.KeyF1:
		return kittyKeySpec{code: 1, final: 'P'}, true
	case gfx.KeyF2:
		return kittyKeySpec{code: 1, final: 'Q'}, true
	case gfx.KeyF3:
		return kittyKeySpec{code: 1, final: 'R'}, true
	case gfx.KeyF4:
		return kittyKeySpec{code: 1, final: 'S'}, true
	case gfx.KeyF5, gfx.KeyF6, gfx.KeyF7, gfx.KeyF8, gfx.KeyF9, gfx.KeyF10, gfx.KeyF11, gfx.KeyF12:
		return kittyKeySpec{code: functionNumbers[key-gfx.KeyF5], tilde: true}, true
	case gfx.KeyShiftLeft:
		return kittyKeySpec{code: 57441}, true
	case gfx.KeyShiftRight:
		return kittyKeySpec{code: 57447}, true
	case gfx.KeyControlLeft:
		return kittyKeySpec{code: 57442}, true
	case gfx.KeyControlRight:
		return kittyKeySpec{code: 57448}, true
	case gfx.KeyAltLeft:
		return kittyKeySpec{code: 57443}, true
	case gfx.KeyAltRight:
		return kittyKeySpec{code: 57449}, true
	case gfx.KeyMetaLeft:
		return kittyKeySpec{code: 57444}, true
	case gfx.KeyMetaRight:
		return kittyKeySpec{code: 57450}, true
	}
	return kittyKeySpec{}, false
}

// kittyTextCode is the unshifted Unicode code point of a key that types text.
func kittyTextCode(key gfx.Key, text string) (int, bool) {
	if key == gfx.KeySpace {
		return ' ', true
	}
	if key != gfx.KeyUnknown || text == "" {
		return 0, false
	}
	character, size := utf8.DecodeRuneInString(text)
	if size == 0 || character == utf8.RuneError && size == 1 {
		return 0, false
	}
	return int(character), true
}

// kittyModifiers encodes the six modifiers the protocol knows, plus the four
// it adds; Viva's Meta bit is the protocol's super on every platform.
func kittyModifiers(modifiers gfx.Modifiers) int {
	value := 1
	if modifiers&gfx.ModifierShift != 0 {
		value += 1
	}
	if modifiers&gfx.ModifierAlt != 0 {
		value += 2
	}
	if modifiers&gfx.ModifierControl != 0 {
		value += 4
	}
	if modifiers&gfx.ModifierMeta != 0 {
		value += 8
	}
	return value
}

// appendKittyCSI appends CSI code[:shifted][;mods[:event]][;text]u.
func appendKittyCSI(dst []byte, code, shifted int, hasShifted bool, mods, eventType int, includeEvent bool, text string, includeText bool) []byte {
	dst = append(dst, '\x1b', '[')
	dst = strconv.AppendInt(dst, int64(code), 10)
	if hasShifted {
		dst = append(dst, ':')
		dst = strconv.AppendInt(dst, int64(shifted), 10)
	}
	if mods != 1 || includeEvent || includeText {
		dst = append(dst, ';')
		dst = strconv.AppendInt(dst, int64(mods), 10)
		if includeEvent {
			dst = append(dst, ':')
			dst = strconv.AppendInt(dst, int64(eventType), 10)
		}
	}
	if includeText {
		dst = append(dst, ';')
		dst = append(dst, text...)
	}
	return append(dst, 'u')
}

// appendKittyFunctional appends CSI 1;mods[:event] final or
// CSI code;mods[:event] ~, omitting the default modifier.
func appendKittyFunctional(dst []byte, final byte, code int, tilde bool, mods, eventType int, includeEvent bool) []byte {
	dst = append(dst, '\x1b', '[')
	if !tilde {
		if mods == 1 && !includeEvent {
			return append(dst, final)
		}
		dst = append(dst, '1')
	} else {
		dst = strconv.AppendInt(dst, int64(code), 10)
	}
	if mods != 1 || includeEvent {
		dst = append(dst, ';')
		dst = strconv.AppendInt(dst, int64(mods), 10)
		if includeEvent {
			dst = append(dst, ':')
			dst = strconv.AppendInt(dst, int64(eventType), 10)
		}
	}
	if tilde {
		return append(dst, '~')
	}
	return append(dst, final)
}

// kittyTextCodepoints formats the text a key inserts as the protocol's
// colon-separated code points, omitting control characters.
func kittyTextCodepoints(text string) string {
	b := make([]byte, 0, len(text)+4)
	first := true
	for _, character := range text {
		if character < 0x20 || character == 0x7f {
			continue
		}
		if !first {
			b = append(b, ':')
		}
		b = strconv.AppendInt(b, int64(character), 10)
		first = false
	}
	return string(b)
}
