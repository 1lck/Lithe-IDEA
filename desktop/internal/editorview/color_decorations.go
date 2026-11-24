package editorview

import (
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

type colorDecorationSpan struct {
	line, start, end int
	light, dark      gfx.Color
}

// PreparedColorDecorations is a bounded foreground overlay tied to the immutable text it names.
type PreparedColorDecorations struct {
	text  rope.Rope
	spans []colorDecorationSpan
}

// PrepareColorDecorations converts UTF-16 ranges to byte offsets away from the window thread.
// Core normally validates these ranges; malformed or stale coordinates are ignored defensively.
func PrepareColorDecorations(text rope.Rope, decorations []ColorDecoration) PreparedColorDecorations {
	prepared := PreparedColorDecorations{text: text}
	if len(decorations) == 0 {
		return prepared
	}
	prepared.spans = make([]colorDecorationSpan, 0, len(decorations))
	line := -1
	lineText := ""
	byteColumn, utf16Column := 0, 0
	for _, decoration := range decorations {
		if decoration.StartLine != decoration.EndLine || decoration.StartLine < 0 || decoration.StartLine >= text.LineCount() {
			continue
		}
		light, lightOK := syntax.ParseColor(decoration.Light)
		dark, darkOK := syntax.ParseColor(decoration.Dark)
		if !lightOK || !darkOK {
			continue
		}
		if line != decoration.StartLine {
			line = decoration.StartLine
			start, end := text.LineStart(line), text.LineEnd(line)
			if end > start && text.ByteAt(end-1) == '\r' {
				end--
			}
			lineText, _ = text.Substring(start, end)
			byteColumn, utf16Column = 0, 0
		}
		start, startOK := colorDecorationByteColumn(lineText, decoration.StartCharacter, &byteColumn, &utf16Column)
		end, endOK := colorDecorationByteColumn(lineText, decoration.EndCharacter, &byteColumn, &utf16Column)
		if !startOK || !endOK || end <= start {
			continue
		}
		prepared.spans = append(prepared.spans, colorDecorationSpan{
			line: line, start: start, end: end, light: uiColor(light), dark: uiColor(dark),
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

// SetPreparedColorDecorations applies ranges only when they were prepared for the live text.
// Painting reads the sorted byte spans from the visible rows and performs no color conversion.
func (v *View) SetPreparedColorDecorations(prepared PreparedColorDecorations) bool {
	if !v.text.Same(prepared.text) {
		return false
	}
	v.decor.colors = prepared.spans
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
	v.decor.colors = nil
	v.decor.colorLine = nil
	if v.cfg.Notify != nil {
		v.cfg.Notify()
	}
}
