package textview

import (
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
)

// tabSize is how many columns a tab stop is apart, as in the console the old client drew.
const tabSize = 4

// runeCells is how many columns of the fixed-pitch grid r takes when it starts at
// column at: a tab reaches the next stop, a carriage return takes none, a wide character
// two and a combining mark none, as the editor counts them (editorview's runeCells).
func runeCells(r rune, at int) int {
	switch {
	case r == '\t':
		return tabSize - at%tabSize
	case r == '\r':
		return 0
	case r < 0x80:
		return 1
	}
	return term.Width(r)
}

// cellsOf is how many columns text takes, starting at column at.
func cellsOf(text string, at int) int {
	cells := at
	for _, r := range text {
		cells += runeCells(r, cells)
	}
	return cells - at
}

// byteAt is the byte offset of text that a point column columns from its start names.
// nearest picks the boundary closest to the point, as a caret is placed; otherwise it
// is the start of the character the point is on, as a word is picked.
func byteAt(text string, column float32, nearest bool) int {
	cells := 0
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		width := runeCells(r, cells)
		end := float32(cells + width)
		if column < end {
			if nearest && width > 0 && column >= float32(cells)+float32(width)/2 {
				return i + size
			}
			return i
		}
		cells += width
		i += size
	}
	return len(text)
}
