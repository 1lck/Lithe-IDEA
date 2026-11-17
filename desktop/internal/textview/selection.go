// Package textview is read-only text the user can select and copy: the console of a run,
// a build or a test, and the details of a commit. The text is drawn on the fixed-pitch
// grid, every line of it or only the rows in view, and takes the selection a text field
// takes in IntelliJ IDEA: a drag, across lines too, a double click for a word, a triple
// click for a line, Shift with a click to extend it, Primary+C to copy it and Primary+A to
// select everything. It never edits what it shows.
package textview

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// Point is a place in the text: the number of a line, as the Source numbers it, and a
// byte offset into the line.
type Point struct {
	Line, Byte int
}

// Less reports whether p comes before q.
func (p Point) Less(q Point) bool {
	return p.Line < q.Line || p.Line == q.Line && p.Byte < q.Byte
}

// Source is the lines a view shows. The lines are numbered from First on, and a line
// number stays the line's while the source holds it: a console that drops its oldest
// lines raises First, so a selection made before still names the same text.
type Source interface {
	First() int
	Count() int
	Line(n int) string
}

// Strings is a Source of lines held in a slice, numbered from 0.
type Strings []string

func (s Strings) First() int        { return 0 }
func (s Strings) Count() int        { return len(s) }
func (s Strings) Line(n int) string { return s[n] }

// unit is what a press selects and a drag extends by: characters after one click, words
// after two and lines after three.
type unit uint8

const (
	unitChar unit = iota
	unitWord
	unitLine
)

// Selection is the selected range of a view's text. The press that began it fixes the
// anchor, the character, word or line under it, and a drag or a Shift click moves the
// focus; the range runs between them, in whole words or lines for a press of two or
// three clicks.
type Selection struct {
	anchorFrom, anchorTo Point
	focusFrom, focusTo   Point
	unit                 unit
	set                  bool
}

// Begin starts a selection at a press: an empty one at the nearest character boundary
// after one click, the word under the pointer after two and the line after three. line
// is the text of at.Line.
func (s *Selection) Begin(at Point, line string, clicks int) {
	s.unit = unitChar
	switch {
	case clicks >= 3:
		s.unit = unitLine
	case clicks == 2:
		s.unit = unitWord
	}
	s.anchorFrom, s.anchorTo = s.span(at, line)
	s.focusFrom, s.focusTo = s.anchorFrom, s.anchorTo
	s.set = true
}

// Extend moves the focus to at, by the unit of the press that began the selection. It
// begins a selection of characters when there is none.
func (s *Selection) Extend(at Point, line string) {
	if !s.set {
		s.Begin(at, line, 1)
		return
	}
	s.focusFrom, s.focusTo = s.span(at, line)
}

// span is the unit around at: at itself for characters, the word under it or the whole
// line, ending at the start of the next line.
func (s *Selection) span(at Point, line string) (Point, Point) {
	at.Byte = boundary(line, at.Byte)
	switch s.unit {
	case unitWord:
		from, to := wordAt(line, at.Byte)
		return Point{at.Line, from}, Point{at.Line, to}
	case unitLine:
		return Point{at.Line, 0}, Point{at.Line + 1, 0}
	}
	return at, at
}

// SelectAll selects every line src holds.
func (s *Selection) SelectAll(src Source) {
	if src.Count() == 0 {
		s.Clear()
		return
	}
	last := src.First() + src.Count() - 1
	s.unit = unitChar
	s.anchorFrom, s.anchorTo = Point{src.First(), 0}, Point{src.First(), 0}
	s.focusFrom, s.focusTo = Point{last, len(src.Line(last))}, Point{last, len(src.Line(last))}
	s.set = true
}

// Clear drops the selection.
func (s *Selection) Clear() { *s = Selection{} }

// Lines is the first and the last line the selection's anchor and focus are on, and false
// when there is no selection. A line selected by a triple click ends at the start of the line
// after it, which then is the last.
func (s *Selection) Lines() (int, int, bool) {
	if !s.set {
		return 0, 0, false
	}
	return min(s.anchorFrom.Line, s.focusFrom.Line), max(s.anchorTo.Line, s.focusTo.Line), true
}

// Move renumbers the selection's lines by delta, for a source whose lines moved: the same
// text, now delta lines further on.
func (s *Selection) Move(delta int) {
	for _, p := range []*Point{&s.anchorFrom, &s.anchorTo, &s.focusFrom, &s.focusTo} {
		p.Line += delta
	}
}

// Range is the selection in src, from its start to its end, clamped to the lines src
// still holds and to character boundaries. ok is false when nothing is selected.
func (s *Selection) Range(src Source) (from, to Point, ok bool) {
	if !s.set || src.Count() == 0 {
		return Point{}, Point{}, false
	}
	from, to = s.anchorFrom, s.anchorTo
	if s.focusFrom.Less(s.anchorFrom) {
		from = s.focusFrom
	}
	if to.Less(s.focusTo) {
		to = s.focusTo
	}
	from, to = clamp(src, from), clamp(src, to)
	if !from.Less(to) {
		return Point{}, Point{}, false
	}
	return from, to, true
}

// Has reports whether anything is selected in src.
func (s *Selection) Has(src Source) bool {
	_, _, ok := s.Range(src)
	return ok
}

// Text is the selected text of src, its lines joined with newlines.
func (s *Selection) Text(src Source) string {
	from, to, ok := s.Range(src)
	if !ok {
		return ""
	}
	return Text(src, from, to)
}

// Text is the text of src from one point to another, its lines joined with newlines.
func Text(src Source, from, to Point) string {
	if from.Line == to.Line {
		return src.Line(from.Line)[from.Byte:to.Byte]
	}
	var b strings.Builder
	b.WriteString(src.Line(from.Line)[from.Byte:])
	for n := from.Line + 1; n < to.Line; n++ {
		b.WriteByte('\n')
		b.WriteString(src.Line(n))
	}
	b.WriteByte('\n')
	b.WriteString(src.Line(to.Line)[:to.Byte])
	return b.String()
}

// clamp moves p into the lines src holds: before them to the start of the first, after
// them to the end of the last, and inside a character to its start.
func clamp(src Source, p Point) Point {
	first, last := src.First(), src.First()+src.Count()-1
	switch {
	case p.Line < first:
		return Point{first, 0}
	case p.Line > last:
		return Point{last, len(src.Line(last))}
	}
	return Point{p.Line, boundary(src.Line(p.Line), p.Byte)}
}

// boundary moves at into text and back to the start of the character it is inside.
func boundary(text string, at int) int {
	at = min(max(at, 0), len(text))
	for at > 0 && at < len(text) && !utf8.RuneStart(text[at]) {
		at--
	}
	return at
}

// wordAt is the word, the run of spaces or the run of punctuation under the character
// at at, as a double click in IntelliJ IDEA's editor selects it. At the end of the text
// it is the one before.
func wordAt(text string, at int) (int, int) {
	if text == "" {
		return 0, 0
	}
	if at >= len(text) {
		_, size := utf8.DecodeLastRuneInString(text)
		at = len(text) - size
	}
	r, _ := utf8.DecodeRuneInString(text[at:])
	class := charClass(r)
	from := at
	for from > 0 {
		r, size := utf8.DecodeLastRuneInString(text[:from])
		if charClass(r) != class {
			break
		}
		from -= size
	}
	to := at
	for to < len(text) {
		r, size := utf8.DecodeRuneInString(text[to:])
		if charClass(r) != class {
			break
		}
		to += size
	}
	return from, to
}

// charClass sorts characters for wordAt: spaces, the characters of identifiers and
// numbers, and everything else.
func charClass(r rune) int {
	switch {
	case unicode.IsSpace(r):
		return 1
	case r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r):
		return 2
	}
	return 3
}
