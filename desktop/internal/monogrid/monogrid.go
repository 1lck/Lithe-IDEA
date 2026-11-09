// Package monogrid breaks monospaced text into lines that fit the cells they are drawn on.
//
// Viva sets a Mono label on the cell grid of its face (gfx.Canvas.MonoCellSize), a wide
// character such as a Chinese one on two cells, and gfx.Canvas.TextWidthStyle measures it
// so. A ui Wrap, though, breaks every text where the proportional font fills the line,
// narrower than the cells a Mono line is drawn on, so its lines run past the box and lose
// their ends. Lines breaks a Mono text by its cells instead. It can go once a ui Wrap
// measures a Mono text on its grid.
package monogrid

import (
	"strings"
	"unicode"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/text"
)

// Lines appends to dst the lines value breaks into for each of them to fit width, drawn as a
// Mono label in style. A line breaks between words, and between two characters where one is
// wide, such as Chinese ones, as a line of text does on macOS, except before closing
// punctuation and after opening punctuation. A word longer than a line breaks inside it.
// Spaces between words are cut down to one, and value with no words has no lines.
func Lines(canvas *gfx.Canvas, dst []string, value string, style gfx.TextStyle, width float32) []string {
	style.Mono = true
	fits := func(s string) bool { return canvas.TextWidthStyle(s, style) <= width }
	line := ""
	for _, piece := range pieces(value) {
		word := piece.text
		if line != "" {
			joined := line + word
			if piece.space {
				joined = line + " " + word
			}
			if fits(joined) {
				line = joined
				continue
			}
			dst = append(dst, line)
		}
		// The part of the piece that fills no whole line starts the next one, for the pieces
		// after it to join.
		for word != "" && !fits(word) {
			cut := longestFit(word, fits)
			dst = append(dst, word[:cut])
			word = word[cut:]
		}
		line = word
	}
	if line != "" {
		dst = append(dst, line)
	}
	return dst
}

// piece is a part of a text that Lines puts on a line whole, unless it is longer than a line.
type piece struct {
	text string
	// space says whitespace came before the piece.
	space bool
}

// pieces cuts value where Lines may break a line: at whitespace, which it drops, and between
// two characters where breaks allows a break.
func pieces(value string) []piece {
	var out []piece
	start, space := -1, false
	var before rune
	for at, r := range value {
		switch {
		case unicode.IsSpace(r):
			if start >= 0 {
				out = append(out, piece{value[start:at], space})
				start = -1
			}
			space = true
		case start < 0:
			start = at
		case breaks(before, r):
			out = append(out, piece{value[start:at], space})
			start, space = at, false
		}
		before = r
	}
	if start >= 0 {
		out = append(out, piece{value[start:], space})
	}
	return out
}

// breaks says a line may break between before and after, two characters with no whitespace
// between them: where one of them is wide, unless after closes something, before opens
// something or after is a mark of before.
func breaks(before, after rune) bool {
	if text.CellWidth(after) == 0 || strings.ContainsRune(closing, after) || strings.ContainsRune(opening, before) {
		return false
	}
	return text.CellWidth(before) == 2 || text.CellWidth(after) == 2
}

// The punctuation a line does not start with, and the punctuation it does not end with.
const (
	closing = ")]}>,.;:!?%」』】〉》〕）］｝，。、；：！？％…"
	opening = "([{<「『【〈《〔（［｛"
)

// longestFit is the byte offset of the longest start of word that fits, by fits, and is cut
// before a character that takes a cell, so a combining mark stays with its character. It is
// the first character, with its marks, when not even that fits.
func longestFit(word string, fits func(string) bool) int {
	cut := 0
	for at, r := range word {
		if at == 0 || text.CellWidth(r) == 0 {
			continue
		}
		if !fits(word[:at]) {
			break
		}
		cut = at
	}
	if cut == 0 {
		// Not even the first character fits: it takes a line of its own, with its marks.
		cut = len(word)
		for at, r := range word {
			if at > 0 && text.CellWidth(r) != 0 {
				cut = at
				break
			}
		}
	}
	return cut
}
