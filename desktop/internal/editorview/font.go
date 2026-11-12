package editorview

import "github.com/vivaui/viva/gfx"

const (
	// defaultFontSize is the size, in points, of the editor's fixed-pitch font until the window
	// chooses another, the terminal's.
	defaultFontSize = float32(13)
	// defaultLineSpacing is how much taller a line is than the font's cell until the window
	// chooses another.
	defaultLineSpacing = float32(1.4)
)

// Font is the fixed-pitch font a View draws its text, line numbers, annotations and IME
// composition with.
type Font struct {
	// Face is the family (gfx.MonoSystem, or a face from gfx.MonoFamily).
	Face gfx.MonoFace
	// Size is the size in points; zero or less is 13.
	Size float32
	// LineSpacing is the height of a line as a multiple of the character cell's height; zero or
	// less is 1.4.
	LineSpacing float32
	// Ligatures draws the character sequences the font joins (->, !=) joined.
	Ligatures bool
}

// DefaultFont is the font a new View draws with: the system face, 13 points, spacing 1.4, no
// ligatures.
func DefaultFont() Font {
	return Font{Face: gfx.MonoSystem, Size: defaultFontSize, LineSpacing: defaultLineSpacing}
}

// normalized is f with the defaults in place of a size or a spacing that is zero, negative or
// not a number, so two fonts that draw alike compare equal.
func (f Font) normalized() Font {
	if !(f.Size > 0) {
		f.Size = defaultFontSize
	}
	if !(f.LineSpacing > 0) {
		f.LineSpacing = defaultLineSpacing
	}
	return f
}

// Font is the font the view draws with, as SetFont normalized it.
func (v *View) Font() Font { return v.font }

// SetFont changes the font the view draws with from the next Paint on. The window may call it
// every frame: a font equal to the current one, once its defaults are filled in, changes nothing
// and allocates nothing.
//
// A change of the cell's size moves no more than the scroll, which Paint converts when it has
// measured the new cell: the first row in view stays at the top of the view, and the first column
// stays at its left edge. The rows a wrapped view breaks the text into follow from the width of
// the new cell the way they follow from a change of the view's width (see setWrapCols). Everything
// else the view keeps, such as the minimap's bars, depends on the text's columns and rows, not on
// the size of the cell.
func (v *View) SetFont(f Font) {
	f = f.normalized()
	if f == v.font {
		return
	}
	v.font = f
}
