// Package treelist holds the measures and the text color of the desktop's tree rows: the
// Project tool window's tree and the lists of files in the Git tool windows share them, so
// a name looks the same wherever it is listed. The rows themselves are Viva's Tree and List.
package treelist

import "github.com/vivaui/viva/gfx"

// The sizes of a row, the same in every tree list.
const (
	// RowHeight is the height of one row.
	RowHeight = 24
	// Indent is how far each level is moved in from its parent.
	Indent = 19
	// Disclosure is the width of the arrow before a branch, and of the room it takes before a
	// leaf, so a branch's leaves line up with its sub-branches.
	Disclosure = 17
	// Icon is the size of the arrow, and of the icon a row's content starts with.
	Icon = 16
	// Gap is the room between the arrow and the content, and between the content's parts.
	Gap = 2
	// Gutter is the room on either side of the rows.
	Gutter = 12
	// Trailing is the room after a row's content.
	Trailing = 8
	// PadY is the room above the first row and below the last.
	PadY = 4
)

// Text is the color of a row's name in the native tree.
func Text(dark bool) gfx.Color {
	if dark {
		return gfx.RGB24(0xD1D3D9)
	}
	return gfx.RGB24(0x000000)
}

// Width is how wide a row at depth is whose content, after the arrow, is content wide: what
// a list that scrolls sideways measures to make its column as wide as its widest row.
func Width(depth int, content float32) float32 {
	return 2*Gutter + float32(depth*Indent) + Disclosure + Gap + content + Trailing
}
