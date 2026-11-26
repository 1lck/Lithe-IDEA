package editorview

import (
	"math"
	"slices"
	"sort"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/gfx"
)

// ColorDecoration is a provider's foreground override for a half-open LSP range.
// The range is in zero-based lines and UTF-16 columns; colors are #RRGGBB strings.
type ColorDecoration struct {
	StartLine, StartCharacter int
	EndLine, EndCharacter     int
	SourceID                  string
	Light, Dark               string
}

// colorDecorationSpan is one provider color over the bytes [start, end) of the text. The offsets
// are absolute, so an edit moves every span after it by one addition and no line has to be found
// again, and the colors are an index into the palette, so the 10,000 brackets of a rainbow cycling
// through a few colors keep a few pairs of colors and 12 bytes per bracket.
type colorDecorationSpan struct {
	start, end uint32
	color      uint32
}

// colorPair is a provider color as the light and as the dark theme draw it.
type colorPair struct{ light, dark gfx.Color }

// PreparedColorDecorations is a bounded foreground overlay tied to the immutable text it names.
type PreparedColorDecorations struct {
	text    rope.Rope
	spans   []colorDecorationSpan
	palette []colorPair
}

// RainbowColor identifies an ordered UTF-8 byte range and its selector in the theme palette.
type RainbowColor struct {
	Start uint32
	End   uint32
	Color uint32
}

// WithRainbowColors combines the built-in colors with sorted provider colors on the worker.
// Provider ranges retain precedence wherever they cover the same byte.
func (p PreparedColorDecorations) WithRainbowColors(colors []RainbowColor, light, dark []string) PreparedColorDecorations {
	if len(colors) == 0 || len(light) == 0 || len(dark) == 0 || p.text.Len() > math.MaxUint32 {
		return p
	}
	palette := make([]colorPair, 0, len(p.palette)+len(light)*len(dark))
	palette = append(palette, p.palette...)
	base := uint32(len(palette))
	for _, lightColor := range light {
		l, lightOK := syntax.ParseColor(lightColor)
		for _, darkColor := range dark {
			d, darkOK := syntax.ParseColor(darkColor)
			if !lightOK || !darkOK {
				return p
			}
			palette = append(palette, colorPair{light: uiColor(l), dark: uiColor(d)})
		}
	}
	spans := make([]colorDecorationSpan, 0, len(p.spans)+len(colors))
	nLight, nDark := uint32(len(light)), uint32(len(dark))
	provider := 0
	for _, builtin := range colors {
		if builtin.End <= builtin.Start || int64(builtin.End) > int64(p.text.Len()) ||
			(len(spans) > 0 && spans[len(spans)-1].end > builtin.Start) {
			continue
		}
		for provider < len(p.spans) && p.spans[provider].end <= builtin.Start {
			spans = append(spans, p.spans[provider])
			provider++
		}
		if provider < len(p.spans) && p.spans[provider].start < builtin.End {
			continue
		}
		color := base + (builtin.Color%nLight)*nDark + builtin.Color%nDark
		spans = append(spans, colorDecorationSpan{start: builtin.Start, end: builtin.End, color: color})
	}
	p.spans = append(spans, p.spans[provider:]...)
	p.palette = palette
	return p
}

// PrepareColorDecorations converts UTF-16 ranges to byte offsets and parses each distinct pair of
// colors once, away from the window thread. Core sorts the ranges and makes them disjoint; ranges
// that break that order, malformed colors and stale coordinates are ignored defensively, so the
// spans the view paints from are always sorted and disjoint.
func PrepareColorDecorations(text rope.Rope, decorations []ColorDecoration) PreparedColorDecorations {
	prepared := PreparedColorDecorations{text: text}
	if len(decorations) == 0 || text.Len() > math.MaxUint32 {
		return prepared
	}
	type colorKey struct{ light, dark string }
	const invalid = math.MaxUint32
	palette := make(map[colorKey]uint32)
	prepared.spans = make([]colorDecorationSpan, 0, len(decorations))
	line, lineStart := -1, 0
	lineText := ""
	byteColumn, utf16Column := 0, 0
	for _, decoration := range decorations {
		if decoration.StartLine != decoration.EndLine || decoration.StartLine < max(line, 0) || decoration.StartLine >= text.LineCount() {
			continue
		}
		if line != decoration.StartLine {
			line = decoration.StartLine
			lineStart = text.LineStart(line)
			end := text.LineEnd(line)
			if end > lineStart && text.ByteAt(end-1) == '\r' {
				end--
			}
			lineText, _ = text.Substring(lineStart, end)
			byteColumn, utf16Column = 0, 0
		}
		start, startOK := colorDecorationByteColumn(lineText, decoration.StartCharacter, &byteColumn, &utf16Column)
		end, endOK := colorDecorationByteColumn(lineText, decoration.EndCharacter, &byteColumn, &utf16Column)
		if !startOK || !endOK || end <= start {
			continue
		}
		key := colorKey{decoration.Light, decoration.Dark}
		color, seen := palette[key]
		if !seen {
			light, lightOK := syntax.ParseColor(decoration.Light)
			dark, darkOK := syntax.ParseColor(decoration.Dark)
			color = invalid
			if lightOK && darkOK {
				color = uint32(len(prepared.palette))
				prepared.palette = append(prepared.palette, colorPair{light: uiColor(light), dark: uiColor(dark)})
			}
			palette[key] = color
		}
		if color == invalid {
			continue
		}
		prepared.spans = append(prepared.spans, colorDecorationSpan{
			start: uint32(lineStart + start), end: uint32(lineStart + end), color: color,
		})
	}
	return prepared
}

// colorDecorationByteColumn advances across one line once for Core's ordered disjoint ranges.
func colorDecorationByteColumn(text string, target int, byteColumn, utf16Column *int) (int, bool) {
	if target < *utf16Column {
		return 0, false
	}
	for *utf16Column < target && *byteColumn < len(text) {
		r, size := utf8.DecodeRuneInString(text[*byteColumn:])
		units := 1
		if r > 0xffff {
			units = 2
		}
		if *utf16Column+units > target {
			return 0, false
		}
		*byteColumn += size
		*utf16Column += units
	}
	return *byteColumn, *utf16Column == target
}

// SetPreparedColorDecorations applies ranges only when they were prepared for the live text, and
// the view owns them from then on. Painting reads the sorted byte spans of the visible lines and
// performs no color conversion.
func (v *View) SetPreparedColorDecorations(prepared PreparedColorDecorations) bool {
	if !v.text.Same(prepared.text) {
		return false
	}
	v.decor.colors, v.decor.colorPalette = prepared.spans, prepared.palette
	v.decor.colorLine = nil
	if v.cfg.Notify != nil {
		v.cfg.Notify()
	}
	return true
}

// ClearColorDecorations removes foreground overrides when their provider is withdrawn.
func (v *View) ClearColorDecorations() {
	if len(v.decor.colors) == 0 {
		return
	}
	v.clearColors()
	if v.cfg.Notify != nil {
		v.cfg.Notify()
	}
}

// clearColors forgets the provider colors, as a replacement of the whole text does.
func (v *View) clearColors() {
	v.decor.colors, v.decor.colorPalette, v.decor.colorLine = nil, nil, nil
}

// shiftColors keeps the provider colors on the characters they colored when the bytes
// [start, oldEnd) are replaced by newEnd-start bytes, until the provider answers for the new
// text: a span before the edit stays, a span after it moves by the edit's length, and a span the
// edit cuts or replaces goes, because what it colored changed. Typing in front of a bracket thus
// carries the bracket's color along instead of showing every bracket uncolored until the answer.
// It costs the spans after the edit. Each input color source is bounded before preparation.
func (v *View) shiftColors(start, oldEnd, newEnd int) {
	colors := v.decor.colors
	if len(colors) == 0 {
		return
	}
	v.decor.colorLine = nil
	if v.text.Len() > math.MaxUint32 {
		v.clearColors()
		return
	}
	// The spans are sorted and disjoint, so their ends are sorted too: first is the first span
	// that reaches past start and last the first that starts at or after the replaced bytes. An
	// insertion strictly inside a span cuts it, and one at a span's start moves it.
	first := sort.Search(len(colors), func(i int) bool { return int(colors[i].end) > start })
	last := first + sort.Search(len(colors)-first, func(i int) bool { return int(colors[first+i].start) >= oldEnd })
	colors = slices.Delete(colors, first, last)
	if delta := newEnd - oldEnd; delta != 0 {
		for i := first; i < len(colors); i++ {
			colors[i].start = uint32(int(colors[i].start) + delta)
			colors[i].end = uint32(int(colors[i].end) + delta)
		}
	}
	if len(colors) == 0 {
		v.clearColors()
		return
	}
	v.decor.colors = colors
}

// lineColors is the provider colors of the line whose bytes are [start, end), found by binary
// search so that a frame's cost does not grow with the colors of lines it does not show.
func (v *View) lineColors(start, end int) []colorDecorationSpan {
	colors := v.decor.colors
	first := sort.Search(len(colors), func(i int) bool { return int(colors[i].start) >= start })
	last := first + sort.Search(len(colors)-first, func(i int) bool { return int(colors[first+i].start) >= end })
	return colors[first:last]
}
