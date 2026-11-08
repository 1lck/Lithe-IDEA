// Package monogrid puts the characters of monospaced labels on the cell grid they were
// laid out on.
//
// Viva lays a Mono text out at Canvas.MonoCellSize a character: the font's own advance,
// rounded to whole device pixels (v0.4.0 took 0.6 of the size, further still from SF Mono's
// 0.618). A plain Mono label has no cell width, so the renderer draws it at the unrounded
// advance, and a line drifts off the cells it was laid out on: it runs past its box and loses
// its last character, or leaves a gap after it, and a column of numbers right-aligned by
// width does not line up. A line with runs (Canvas.LabelRuns) is drawn glyph by glyph on its
// cells, as a terminal row is. Snap turns the plain Mono labels of a frame into such lines
// once flex has painted them. It can go once Viva places a plain Mono label on the grid too.
package monogrid

import (
	"math"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// maxASCIIRun is the longest stretch of ASCII one run holds. The macOS renderer puts each
// character of a run on its own cell only up to 256 of them; a longer run is shaped as a
// line, at the font's advance.
const maxASCIIRun = 256

// The kinds of stretch Runs reads.
const (
	// noRun says no stretch of value has been read yet.
	noRun = iota
	// asciiRun is a stretch of printable ASCII, a character on each cell.
	asciiRun
	// otherRun is a stretch of any other characters, drawn at the font's own advances.
	otherRun
)

// Snap turns every plain Mono label painted on canvas since its text list held from texts
// into a line on the cell grid of its size, in place, so its layer, clip and paint order stay
// as they were. A label that already has runs is left as it is.
func Snap(canvas *ui.Canvas, from int) {
	end := len(canvas.Texts())
	var runs []ui.TextRun
	for i := max(from, 0); i < end; i++ {
		label := canvas.Texts()[i]
		if !label.Style.Mono || label.RunCount > 0 || label.Value == "" {
			continue
		}
		cell, _ := canvas.MonoCellSize(label.Style.Size, label.Style.MonoFace)
		runs, _ = Runs(canvas, runs[:0], label.Value, label.Style)
		// LabelRuns is the only way to store runs on the canvas. The line it adds has no
		// room, so it is never drawn; the label takes over its runs.
		canvas.LabelRuns(label.Value, ui.Rect{}, label.Style, cell, runs)
		texts := canvas.Texts()
		added := &texts[len(texts)-1]
		texts[i].CellWidth = cell
		texts[i].RunFirst, texts[i].RunCount = added.RunFirst, added.RunCount
		added.Value, added.RunCount = "", 0
	}
}

// Width is how wide a box for value in style has to be for Snap to draw all of it: the
// cells Runs puts it on. A Mono text whose value is not all printable ASCII is given this
// width; flex counts one cell a character, too few for a wide one.
func Width(canvas *ui.Canvas, value string, style ui.TextStyle) float32 {
	cell, _ := canvas.MonoCellSize(style.Size, style.MonoFace)
	_, cells := Runs(canvas, nil, value, style)
	return cell * float32(cells)
}

// overflow is how much of a cell a stretch of other characters that ends at end in value may
// run into the cell after it. Half of one before a space, which draws nothing, so the gap
// after the stretch stays about a cell wide; a sliver before any other character, about
// what a glyph keeps clear of its cell's edge; none at the end of value, where the label's
// box ends.
func overflow(value string, end int) float64 {
	switch {
	case end >= len(value):
		return 1e-3
	case value[end] == ' ':
		return 0.5
	default:
		return 0.15
	}
}

// Runs appends to dst the runs that put value on the cell grid of style's size, in its color,
// weight and slant, and says how many cells they take.
//
// A stretch of printable ASCII is one run with a character on each cell. A stretch of any
// other characters is one run that starts on a cell and is drawn at the font's own advances,
// as a label is; the renderer centers a stretch of one character on its cells. A stretch
// with a wide character, such as a CJK one, takes the cells its width as a label fills, not
// two a wide character as on a terminal: a CJK character is about one em wide and two cells
// are 1.2 em, so a line of Chinese would end in a gap of a fifth of an em for every one of
// its characters. The stretch may run a little into the cell after it (see overflow), so
// the ASCII that follows is not pushed a whole cell on by a width just past a cell's edge.
// A character that takes no cell, such as a combining mark, joins the character before it.
func Runs(canvas *ui.Canvas, dst []ui.TextRun, value string, style ui.TextStyle) ([]ui.TextRun, int) {
	cell, _ := canvas.MonoCellSize(style.Size, style.MonoFace)
	run := func(column, bytes, cells int) ui.TextRun {
		return ui.TextRun{
			Column: int32(column), Bytes: int32(bytes), Cells: int32(cells),
			Color: style.Color, Weight: style.Weight, Italic: style.Italic,
		}
	}
	column, kind := 0, noRun
	// start is where the stretch of other characters being read begins in value, and wide
	// says it holds a wide character.
	start, wide := 0, false
	// endStretch ends the stretch of other characters being read, at end in value.
	endStretch := func(end int) {
		last := &dst[len(dst)-1]
		if wide && cell > 0 {
			width := canvas.TextWidthStyle(value[start:end], style)
			last.Cells = int32(max(math.Ceil(float64(width/cell)-overflow(value, end)), 1))
		}
		column += int(last.Cells)
	}
	for at := 0; at < len(value); {
		r, size := utf8.DecodeRuneInString(value[at:])
		cells := text.CellWidth(r)
		last := len(dst) - 1
		switch {
		case r >= 0x20 && r < 0x7F:
			if kind == otherRun {
				endStretch(at)
			}
			if kind == asciiRun && dst[last].Bytes < maxASCIIRun {
				dst[last].Bytes++
				dst[last].Cells++
			} else {
				dst = append(dst, run(column, 1, 1))
			}
			column++
			kind = asciiRun
		case cells == 0 && kind == asciiRun:
			// The mark belongs to the last character of the stretch, which leaves it for a
			// stretch of other characters, with the mark.
			if dst[last].Bytes > 1 {
				dst[last].Bytes--
				dst[last].Cells--
				dst = append(dst, run(column-1, 1, 1))
				last++
			}
			column--
			dst[last].Bytes += int32(size)
			kind, start, wide = otherRun, at-1, false
		case kind == otherRun:
			dst[last].Bytes += int32(size)
			dst[last].Cells += int32(cells)
			wide = wide || cells > 1
		default:
			dst = append(dst, run(column, size, cells))
			kind, start, wide = otherRun, at, cells > 1
		}
		at += size
	}
	if kind == otherRun {
		endStretch(len(value))
	}
	return dst, column
}

// Lines appends to dst the lines value breaks into for Snap to draw each of them, in style,
// within width. A line breaks between words, and between two characters where one is wide,
// such as Chinese ones, as a line of text does on macOS, except before closing punctuation
// and after opening punctuation. A word longer than a line breaks inside it. Spaces between
// words are cut down to one, and value with no words has no lines. A Mono text that wraps
// is set by it: a flex Wrap breaks its text where the proportional font would fill the
// line, narrower than the cells the line is drawn on, so its lines run past the box and lose
// their ends.
func Lines(canvas *ui.Canvas, dst []string, value string, style ui.TextStyle, width float32) []string {
	fits := func(s string) bool { return Width(canvas, s, style) <= width }
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
