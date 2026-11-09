package editorview

import (
	"sort"
	"unicode/utf8"
)

// A line longer than longLine, such as the one line of a minified file, is never read whole to
// paint it, to place the caret or to draw the selection: copying ten megabytes for every frame
// costs more than the frame. The view reads such a line a part at a time, and keeps stops along
// it, every stopBytes bytes from its start as far as it has been read: where a character starts
// and the cells before it. A column far into the line is found from the stop before it, reading
// at most stopBytes bytes, and a paint reads only the columns it shows.
//
// The stops are kept for the text's revision. An edit keeps the stops of the lines it did not
// change and the stops of the edited line before the edit; any other change of the text drops
// them all. Wrapping a long line still reads it whole, once for each revision and width, as
// wrapLine needs the text.

// longLine is the longest line the view reads whole: the longest one it keeps a copy of.
const longLine = joinedBytes

// stopBytes is how far apart the stops of a long line are, in bytes, and stopLines how many
// long lines the view keeps stops for.
const (
	stopBytes = 4 << 10
	stopLines = 64
)

// partLimit is how many parts of long lines the view keeps for a revision of the text.
const partLimit = 256

// lineRef is a line as the view reads it: its number, the byte of the text it starts at, its
// length without the line feed, and the whole line unless it is long, when text is empty.
type lineRef struct {
	line, start, size int
	text              string
	long              bool
}

// lineStop is a place in a long line: the byte column at, where a character starts, and the
// cells the line takes before it.
type lineStop struct{ at, cells int }

// lineStops is the stops of a long line in order, the first at its start; done says they reach
// its end, the last one being there.
type lineStops struct {
	stops []lineStop
	done  bool
}

// partKey is a part of a long line that a paint read: of the row starting at byte at, the
// cells from to to.
type partKey struct{ line, at, from, to int }

// part is a part of a long line: its text, which is the line's bytes from base, and the row it
// is, the place it starts.
type part struct {
	text string
	base int
	row  wrapRow
}

// ref returns line as the view reads it.
func (v *View) ref(line int) lineRef {
	start, end := v.text.LineStart(line), v.text.LineEnd(line)
	l := lineRef{line: line, start: start, size: end - start}
	if l.size > longLine {
		l.long = true
	} else {
		l.text = v.lineIn(line, start, end)
	}
	return l
}

// cellsAt is how many cells the bytes of l take up to byte column col, as cellsOf counts them.
func (v *View) cellsAt(l lineRef, col int) int {
	if !l.long {
		return cellsOf(l.text, col)
	}
	col = min(max(col, 0), l.size)
	stop := v.stopAt(l, col, maxCells)
	return rangeCells(v.text, l.start+stop.at, l.start+col, stop.cells)
}

// columnFrom is columnIn for l: the byte column, from byte from to byte to of l, where from is
// startCells columns in, whose cell holds cells, counted from the line's start.
func (v *View) columnFrom(l lineRef, from, to, startCells int, cells float32) int {
	if !l.long {
		return columnIn(l.text, from, to, startCells, cells)
	}
	at, sum := from, startCells
	// Every character before a stop at most cells columns in ends left of cells, so none of them
	// is the column; the stop is before to, so a carriage return that ends the line is read.
	if stop := v.stopAt(l, to-1, int(max(cells, 0))); stop.at > from {
		at, sum = stop.at, stop.cells
	}
	col := to
	v.text.Chunks(l.start+at, l.start+to, func(chunk string) bool {
		for i := 0; i < len(chunk); {
			r, size := rune(chunk[i]), 1
			if r >= utf8.RuneSelf {
				r, size = utf8.DecodeRuneInString(chunk[i:])
			}
			if r == '\r' && at == l.size-1 {
				col = at
				return false
			}
			w := runeCells(r, sum)
			if cells < float32(sum)+float32(w)/2 {
				col = at
				return false
			}
			sum += w
			at += size
			i += size
		}
		return true
	})
	return col
}

// lastRuneSize is the size of the character of l that ends at byte column end, reading no
// further back than byte from.
func (v *View) lastRuneSize(l lineRef, from, end int) int {
	if !l.long {
		_, size := utf8.DecodeLastRuneInString(l.text[from:end])
		return size
	}
	tail, _ := v.text.Substring(l.start+max(from, end-utf8.UTFMax), l.start+end)
	_, size := utf8.DecodeLastRuneInString(tail)
	return size
}

// part is what a paint of a row of l reads: the row starts at row and ends at byte end, and the
// paint shows its cells from from to to. A line that is not long is read whole. Of a long line
// it is the bytes from the first character the paint shows to the first one right of to, read
// from the stop before from, and the row it returns is where they start. A part is kept for the
// revision of the text, so painting the same columns again reads nothing.
func (v *View) part(l lineRef, row wrapRow, end, from, to int) part {
	if !l.long {
		return part{text: l.text, row: row}
	}
	if v.partsRevision != v.revision {
		clear(v.parts)
		v.partsRevision = v.revision
	}
	key := partKey{line: l.line, at: row.at, from: from, to: to}
	if p, ok := v.parts[key]; ok {
		return p
	}
	// The characters before a stop at most from columns in are all left of the columns shown.
	start := row
	if stop := v.stopAt(l, end-1, from); stop.at > row.at {
		start = wrapRow{at: stop.at, cells: stop.cells}
	}
	at, cells, first, last := start.at, start.cells, -1, end
	v.text.Chunks(l.start+start.at, l.start+end, func(chunk string) bool {
		for i := 0; i < len(chunk); {
			r, size := rune(chunk[i]), 1
			if r >= utf8.RuneSelf {
				r, size = utf8.DecodeRuneInString(chunk[i:])
			}
			w := runeCells(r, cells)
			if first < 0 && cells+w > from {
				first, start = at, wrapRow{at: at, cells: cells}
			}
			if cells >= to {
				last = at
				return false
			}
			cells += w
			at += size
			i += size
		}
		return true
	})
	if first < 0 {
		start, last = wrapRow{at: end, cells: cells}, end
	}
	text, _ := v.text.Substring(l.start+start.at, l.start+last)
	p := part{text: text, base: start.at, row: start}
	if v.parts == nil {
		v.parts = make(map[partKey]part)
	} else if len(v.parts) >= partLimit {
		clear(v.parts)
	}
	v.parts[key] = p
	return p
}

// maxCells is a column no line reaches, for a stop asked for by its byte column or by its cells
// alone.
const maxCells = int(^uint(0) >> 1)

// stopAt is the last stop of long line l at or before byte column col and at most cells
// columns in, after reading the line as far as either; stops of a revision of the text before
// the current one are dropped first.
func (v *View) stopAt(l lineRef, col, cells int) lineStop {
	if v.stopsRevision != v.revision {
		clear(v.stops)
		v.stopsRevision = v.revision
	}
	s := v.stops[l.line]
	if s == nil {
		if v.stops == nil {
			v.stops = make(map[int]*lineStops)
		} else if len(v.stops) >= stopLines {
			clear(v.stops)
		}
		s = &lineStops{stops: []lineStop{{}}}
		v.stops[l.line] = s
	}
	v.reach(l, s, col, cells)
	k := sort.Search(len(s.stops), func(i int) bool { return s.stops[i].at > col || s.stops[i].cells > cells })
	return s.stops[max(k-1, 0)]
}

// reach adds stops to s, the stops of l, until the last one is at or past byte column col or
// cells columns in, or at the end of the line.
func (v *View) reach(l lineRef, s *lineStops, col, cells int) {
	last := s.stops[len(s.stops)-1]
	if s.done || last.at >= col || last.cells >= cells {
		return
	}
	at, sum, next := last.at, last.cells, last.at+stopBytes
	reached := false
	v.text.Chunks(l.start+at, l.start+l.size, func(chunk string) bool {
		for i := 0; i < len(chunk); {
			if at >= next {
				s.stops = append(s.stops, lineStop{at: at, cells: sum})
				if at >= col || sum >= cells {
					reached = true
					return false
				}
				next = at + stopBytes
			}
			r, size := rune(chunk[i]), 1
			if r >= utf8.RuneSelf {
				r, size = utf8.DecodeRuneInString(chunk[i:])
			}
			sum += runeCells(r, sum)
			at += size
			i += size
		}
		return true
	})
	if reached {
		return
	}
	if end := s.stops[len(s.stops)-1]; end.at != at {
		s.stops = append(s.stops, lineStop{at: at, cells: sum})
	}
	s.done = true
}

// keepStops follows an edit at byte column col of line first that turned lines first to oldLast
// into lines first to newLast, the text's revision having just moved on: it keeps the stops of
// the lines before first, those of first before the edit, and those of the lines after the
// edit when they kept their numbers. A stop less than a character before col is dropped too,
// as the edit may join that character with the bytes after it.
func (v *View) keepStops(first, oldLast, newLast, col int) {
	clear(v.parts)
	v.partsRevision = v.revision
	if v.stopsRevision != v.revision-1 {
		return
	}
	v.stopsRevision = v.revision
	for line, s := range v.stops {
		switch {
		case line < first:
		case line == first:
			k := sort.Search(len(s.stops), func(i int) bool { return s.stops[i].at+utf8.UTFMax > col })
			s.stops, s.done = s.stops[:max(k, 1)], false
		case line > oldLast && oldLast == newLast:
		default:
			delete(v.stops, line)
		}
	}
}
