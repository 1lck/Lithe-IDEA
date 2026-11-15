package editorview

import (
	"context"
	"slices"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// ProjectedMarkers is immutable display-cell geometry for one text revision.
// Its internals cannot be changed by callers after worker preparation.
type ProjectedMarkers struct{ lines map[int][]Marker }

// ProjectMarkers runs off the UI thread over a persistent rope. Each affected
// line is traversed once, only as far as its last diagnostic, with cancellation
// checked for every rope chunk. It never materializes a long line.
func ProjectMarkers(ctx context.Context, text rope.Rope, markers []Marker) (ProjectedMarkers, error) {
	if err := ctx.Err(); err != nil {
		return ProjectedMarkers{}, err
	}
	result := ProjectedMarkers{lines: make(map[int][]Marker)}
	for _, marker := range markers {
		if marker.Line < 0 || marker.Line >= text.LineCount() || marker.Start < 0 || marker.End <= marker.Start {
			continue
		}
		result.lines[marker.Line] = append(result.lines[marker.Line], marker)
	}
	for line, items := range result.lines {
		if err := ctx.Err(); err != nil {
			return ProjectedMarkers{}, err
		}
		positions := make([]int, 0, len(items)*2)
		for _, item := range items {
			positions = append(positions, item.Start, item.End)
		}
		slices.Sort(positions)
		positions = slices.Compact(positions)
		cellsAt := make(map[int]int, len(positions))
		index, units, cells := 0, 0, 0
		text.Chunks(text.LineStart(line), text.LineEnd(line), func(chunk string) bool {
			if ctx.Err() != nil {
				return false
			}
			for len(chunk) > 0 && index < len(positions) {
				r, size := utf8.DecodeRuneInString(chunk)
				width := 1
				if r > 0xffff {
					width = 2
				}
				// A malformed UTF-16 endpoint inside a surrogate pair rounds down,
				// matching ByteOffset. Out-of-line endpoints clamp to the line end.
				for index < len(positions) && positions[index] < units+width {
					cellsAt[positions[index]] = cells
					index++
				}
				if index == len(positions) {
					return false
				}
				units += width
				cells += runeCells(r, cells)
				chunk = chunk[size:]
			}
			return index < len(positions)
		})
		if err := ctx.Err(); err != nil {
			return ProjectedMarkers{}, err
		}
		for ; index < len(positions); index++ {
			cellsAt[positions[index]] = cells
		}
		projected := items[:0]
		for _, item := range items {
			item.Start, item.End = cellsAt[item.Start], cellsAt[item.End]
			if item.End > item.Start {
				projected = append(projected, item)
			}
		}
		if len(projected) == 0 {
			delete(result.lines, line)
		} else {
			result.lines[line] = projected
		}
	}
	if len(result.lines) == 0 {
		result.lines = nil
	}
	return result, nil
}

// SetProjectedMarkers publishes worker geometry only for the captured revision.
func (v *View) SetProjectedMarkers(markers ProjectedMarkers, revision int) bool {
	if v.revision != revision {
		return false
	}
	v.markers = markers.lines
	return true
}
