package termview

import "github.com/1lck/Lithe-IDEA/desktop/internal/term"

// CursorThickness is how thick the thin cursors draw: the bar's width and the underline's
// height. The block cursor fills its cell whatever it is. Ported from motty 8a7476b6.
type CursorThickness uint8

const (
	// CursorNormal is the thickness a terminal draws with when nothing is chosen.
	CursorNormal CursorThickness = iota
	CursorThin
	CursorThick
)

// bar is the width of the bar cursor in logical pixels.
func (k CursorThickness) bar() float32 {
	switch k {
	case CursorThin:
		return 2
	case CursorThick:
		return 5
	}
	return 3
}

// underline is the height of the underline cursor in logical pixels.
func (k CursorThickness) underline() float32 {
	switch k {
	case CursorThin:
		return 1
	case CursorThick:
		return 3
	}
	return 2
}

// Cursor is the cursor the user chose for the terminal: the shape it takes until a program
// asks for its own with DECSCUSR, and how thick a bar or an underline draws, whichever chose
// the shape. The zero Cursor is the block of normal thickness a terminal starts with. Ported
// from motty 3f7979e4.
type Cursor struct {
	Shape     term.CursorStyle
	Thickness CursorThickness
}

// SetCursor changes the cursor to c from the next Paint on. The workbench calls it every frame
// with the cursor its settings name, so a cursor equal to the one in use changes nothing. A
// shape a program has asked for stays until the program resets the terminal or asks for the
// default again; the thickness applies to whichever shape is drawn.
func (v *View) SetCursor(c Cursor) {
	v.cursorThickness = c.Thickness
	v.screen.SetDefaultCursor(c.Shape)
}
