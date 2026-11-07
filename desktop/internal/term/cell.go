// Package term is a VT/xterm terminal emulator: it consumes the bytes a shell
// writes and maintains the character grid, cursor and scrollback they describe.
//
// A Terminal is not safe for concurrent use. The owner feeds it from one
// goroutine (in motty, the window thread, after the network reader has handed
// the bytes over), which keeps the emulator free of locks and its behavior a
// pure function of the byte stream.
package term

// ColorKind says how a Color is specified.
type ColorKind uint8

const (
	// DefaultColor is the terminal's own foreground or background.
	DefaultColor ColorKind = iota
	// PaletteColor is an index into the 256-color palette.
	PaletteColor
	// TrueColor is a 24-bit RGB value.
	TrueColor
)

// Color is a cell color: the default, a palette index, or true color. The zero
// value is the default color, so a cleared cell needs no initialization.
type Color uint32

// Indexed returns palette color index (0-15 are the ANSI colors).
func Indexed(index uint8) Color { return Color(PaletteColor)<<24 | Color(index) }

// RGB returns a 24-bit color.
func RGB(red, green, blue uint8) Color {
	return Color(TrueColor)<<24 | Color(red)<<16 | Color(green)<<8 | Color(blue)
}

// Kind reports how the color is specified.
func (color Color) Kind() ColorKind { return ColorKind(color >> 24) }

// Index is the palette index of a PaletteColor.
func (color Color) Index() uint8 { return uint8(color) }

// Components are the red, green and blue of a TrueColor.
func (color Color) Components() (red, green, blue uint8) {
	return uint8(color >> 16), uint8(color >> 8), uint8(color)
}

// Attr is a set of text attributes.
type Attr uint16

const (
	Bold Attr = 1 << iota
	Dim
	Italic
	Underline
	Blink
	Inverse
	Hidden
	Strike
	// WideHead marks the first cell of a double-width character; the cell
	// after it is its WideTail and holds no character of its own.
	WideHead
	WideTail
)

// Cell is one grid position. R is 0 for an empty cell.
type Cell struct {
	R    rune
	FG   Color
	BG   Color
	Attr Attr
}

// Mark is a combining character attached to the cell at Col.
type Mark struct {
	Col uint16
	R   rune
}

// line is one row of the grid or of the scrollback.
type line struct {
	cells      []Cell
	marks      []Mark
	hyperlinks *[]uint32 // nil until this line receives OSC 8 text
	id         uint64
	at         int64 // unix seconds of the first write; 0 when unrecorded
	version    uint32
	used       int // one past the last column written since the line was recycled
	wrapped    bool
}

// Row is a read-only view of one visible row. Its slices are valid until the
// next Write or Resize. Cells may be shorter than the terminal is wide for
// lines that came from the scrollback; the missing cells are empty. (ID,
// Version) changes whenever the row's content does, so a renderer can cache
// what it built from it.
type Row struct {
	Cells   []Cell
	Marks   []Mark
	ID      uint64
	Version uint32
	Wrapped bool
	// Written is when the line was first written, in unix seconds, or 0 when
	// stamping is off (see SetClock) or nothing was written to it.
	Written int64
}
