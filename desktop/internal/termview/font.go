package termview

import (
	"math"

	"github.com/vivaui/viva/gfx"
)

// defaultFontSize is the size, in points, of a font that names none.
const defaultFontSize = float32(13)

// Font is the fixed-pitch font a View draws the terminal's cells with.
type Font struct {
	// Face is the family (gfx.MonoSystem, or a face from gfx.MonoFamily).
	Face gfx.MonoFace
	// Size is the size in points; zero or less is 13.
	Size float32
	// LineSpacing is the height of a row as a multiple of the character cell's height; zero or
	// less is 1.
	LineSpacing float32
	// Ligatures draws the character sequences the font joins (->, !=) joined.
	Ligatures bool
}

// DefaultFont is the font a new View draws with: the system face, 13 points, spacing 1,
// ligatures on. It is what the view drew with before its font could be chosen.
func DefaultFont() Font {
	return Font{Face: gfx.MonoSystem, Size: defaultFontSize, LineSpacing: 1, Ligatures: true}
}

// normalized is the font with every field that names no usable value set to its default, so
// two fonts that draw the same compare equal. A size or spacing that is zero, negative, not a
// number or infinite names none.
func (f Font) normalized() Font {
	if !usable(f.Size) {
		f.Size = defaultFontSize
	}
	if !usable(f.LineSpacing) {
		f.LineSpacing = 1
	}
	return f
}

// usable reports whether value is a finite number greater than zero. A NaN fails the
// comparison, so it is not usable either.
func usable(value float32) bool {
	return value > 0 && !math.IsInf(float64(value), 0)
}

// rowHeight is the pitch of a row for a character cell glyphH tall: the cell's height times
// the line spacing, rounded to a whole pixel as the cell's own height is, so that rows tile
// without seams. At spacing 1 it is the cell's height itself. A row is never less than one
// pixel, however small the spacing, so the grid always has a finite number of rows; a cell
// with no height has no row. The font must be normalized.
func (f Font) rowHeight(glyphH float32) float32 {
	if glyphH <= 0 {
		return 0
	}
	return max(float32(math.Round(float64(glyphH*f.LineSpacing))), 1)
}

// SetFont changes the font the terminal is drawn with, from the next Paint on. The workbench
// calls it every frame with the font its settings name, so a font equal to the one in use
// (once its unset fields are defaulted) changes nothing and costs a comparison.
//
// A change needs no further work here. Paint measures the cell of the font in use on each
// frame and lays the grid out from it, so a new size, family or spacing reaches the screen
// and the shell through the same resize as a change of the area (see fit). The row cache is
// keyed on the ligature setting (see rowCache.row), so the one font property its rows hold
// is rebuilt on its own.
func (v *View) SetFont(f Font) {
	f = f.normalized()
	if f == v.font {
		return
	}
	v.font = f
}

// glyphInset is how far below the top of a row its glyph cell starts. The cell is centered in
// the row, so a row taller than the font's line spreads the extra height above and below the
// text. It is zero at spacing 1.
func (v *View) glyphInset() float32 { return (v.rowH - v.glyphH) / 2 }
