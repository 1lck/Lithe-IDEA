package term

import "strconv"

// MouseEventKind identifies a terminal mouse event.
type MouseEventKind uint8

const (
	MousePress MouseEventKind = iota + 1
	MouseRelease
	MouseMotion
	MouseWheel
)

// MouseEventButton identifies a terminal mouse button or wheel direction.
type MouseEventButton uint8

const (
	MouseButtonNone MouseEventButton = iota
	MouseButtonLeft
	MouseButtonMiddle
	MouseButtonRight
	MouseWheelUp
	MouseWheelDown
	MouseWheelLeft
	MouseWheelRight
)

// MouseModifiers is the modifier state reported with a mouse event.
type MouseModifiers uint8

const (
	MouseModifierShift MouseModifiers = 1 << iota
	MouseModifierMeta
	MouseModifierControl
)

// MouseEvent is one mouse action at a zero-based terminal cell.
type MouseEvent struct {
	Kind      MouseEventKind
	Button    MouseEventButton
	Modifiers MouseModifiers
	Column    int
	Row       int
}

// AppendMouse appends an xterm mouse report for event under modes. It leaves
// dst unchanged and reports false when the active mode does not accept event.
func AppendMouse(dst []byte, modes Modes, event MouseEvent) ([]byte, bool) {
	button, release, ok := mouseCode(modes.Mouse, event)
	if !ok || event.Column < 0 || event.Row < 0 {
		return dst, false
	}
	modifier := 0
	if event.Modifiers&MouseModifierShift != 0 {
		modifier |= 4
	}
	if event.Modifiers&MouseModifierMeta != 0 {
		modifier |= 8
	}
	if event.Modifiers&MouseModifierControl != 0 {
		modifier |= 16
	}
	button |= modifier

	switch modes.MouseEncoding {
	case MouseEncodingX10:
		if release {
			button = 3 | modifier
		}
		column := mouseCoordinate(event.Column, 223)
		row := mouseCoordinate(event.Row, 223)
		dst = append(dst, '\x1b', '[', 'M', byte(button+32), byte(column+32), byte(row+32))
	case MouseEncodingUTF8:
		if release {
			button = 3 | modifier
		}
		column := mouseCoordinate(event.Column, 2015)
		row := mouseCoordinate(event.Row, 2015)
		dst = append(dst, '\x1b', '[', 'M')
		dst = utf8AppendRune(dst, rune(button+32))
		dst = utf8AppendRune(dst, rune(column+32))
		dst = utf8AppendRune(dst, rune(row+32))
	case MouseEncodingSGR:
		dst = append(dst, '\x1b', '[', '<')
		dst = strconv.AppendInt(dst, int64(button), 10)
		dst = appendMouseCoordinates(dst, event)
		if release {
			dst = append(dst, 'm')
		} else {
			dst = append(dst, 'M')
		}
	case MouseEncodingURXVT:
		if release {
			button = 3 | modifier
		}
		dst = append(dst, '\x1b', '[')
		dst = strconv.AppendInt(dst, int64(button+32), 10)
		dst = appendMouseCoordinates(dst, event)
		dst = append(dst, 'M')
	default:
		return dst, false
	}
	return dst, true
}

func mouseCode(mode MouseMode, event MouseEvent) (button int, release, ok bool) {
	if mode == MouseOff {
		return 0, false, false
	}
	switch event.Kind {
	case MousePress:
		button, ok = mouseButtonCode(event.Button)
		return button, false, ok
	case MouseRelease:
		if mode == MouseX10 {
			return 0, false, false
		}
		button, ok = mouseButtonCode(event.Button)
		return button, true, ok
	case MouseMotion:
		if mode < MouseDrag || mode == MouseDrag && event.Button == MouseButtonNone {
			return 0, false, false
		}
		if event.Button == MouseButtonNone {
			button = 3
		} else {
			button, ok = mouseButtonCode(event.Button)
			if !ok {
				return 0, false, false
			}
		}
		return button | 32, false, true
	case MouseWheel:
		if event.Button < MouseWheelUp || event.Button > MouseWheelRight {
			return 0, false, false
		}
		return 64 + int(event.Button-MouseWheelUp), false, true
	default:
		return 0, false, false
	}
}

func mouseButtonCode(button MouseEventButton) (int, bool) {
	switch button {
	case MouseButtonLeft:
		return 0, true
	case MouseButtonMiddle:
		return 1, true
	case MouseButtonRight:
		return 2, true
	default:
		return 0, false
	}
}

func mouseCoordinate(value, maximum int) int {
	if value >= maximum {
		return maximum
	}
	return value + 1
}

func appendMouseCoordinates(dst []byte, event MouseEvent) []byte {
	dst = append(dst, ';')
	dst = strconv.AppendInt(dst, mouseDecimalCoordinate(event.Column), 10)
	dst = append(dst, ';')
	return strconv.AppendInt(dst, mouseDecimalCoordinate(event.Row), 10)
}

func mouseDecimalCoordinate(value int) int64 {
	maximum := int(^uint(0) >> 1)
	if value == maximum {
		return int64(value)
	}
	return int64(value + 1)
}

func utf8AppendRune(dst []byte, value rune) []byte {
	switch {
	case value < 0x80:
		return append(dst, byte(value))
	case value < 0x800:
		return append(dst, 0xc0|byte(value>>6), 0x80|byte(value)&0x3f)
	default:
		return append(dst, 0xe0|byte(value>>12), 0x80|byte(value>>6)&0x3f, 0x80|byte(value)&0x3f)
	}
}
