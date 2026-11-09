package editorview

import (
	"math"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
)

// The minimap is the text drawn small down the right side of the view, left of the vertical
// scrollbar: each row is a strip minimapRowH high, and each run of characters of one color a
// bar of that color, so the shape of the code shows and the slider over it marks the rows in
// view. A text taller than the minimap scrolls in it, slower than the text does, so the slider
// still travels the whole height.
//
// Only the rows the minimap shows are laid out, as bars kept between paints: they are made again
// when the text, its colors, the columns or the theme change, and when the minimap scrolls only
// the rows that came into it are made.
//
// A small button with a chevron sits at the minimap's left edge while the pointer is over the
// minimap or near that edge over the text. It hides the minimap; once hidden, the same button
// shows at the right edge of the text while the pointer is near it, and shows the minimap again.
// The window owns the choice, for every view at once, and hands it to each view with SetMinimap.

const (
	// minimapWidth is how wide the minimap is, and minimapRoom how many times as wide the text
	// must stay for the view to show it.
	minimapWidth = float32(100)
	minimapRoom  = float32(3)
	// minimapRowH is how high a row is in the minimap, minimapInk how high its bars are, and
	// minimapCell how wide a column is. minimapPad is the room left of the bars. A bar takes
	// half its row, so the rows read as lines of text with room between them.
	minimapRowH = float32(2)
	minimapInk  = float32(1)
	minimapCell = float32(1)
	minimapPad  = float32(6)
	// minimapAlphaLight and minimapAlphaDark are how opaque the bars are against their syntax
	// colors on a light and on a dark ground. They give the minimap the tone of text drawn a
	// point wide: a character covers only part of its cell, so bars as opaque as the text would
	// read several times darker. Light grounds take the lighter bars, as dark text on them reads
	// heavier than light text on a dark one.
	minimapAlphaLight = float32(0.45)
	minimapAlphaDark  = float32(0.56)
	// toggleW and toggleH are the size of the button that hides and shows the minimap, and
	// toggleIcon the size of its chevron.
	toggleW    = float32(14)
	toggleH    = float32(28)
	toggleIcon = float32(12)
	// edgeZone is how near the text's right edge the pointer brings the button that shows the
	// minimap again.
	edgeZone = float32(48)
)

// minimapState is the minimap of the last paint: where it is, and its bars.
type minimapState struct {
	// rect is where the minimap is, and empty when it is not shown.
	rect  gfx.Rect
	marks []minimapMark
	// key is what marks were made from.
	key minimapKey
	// tokens and rows are scratch space for making marks.
	tokens []syntax.Token
	rows   []wrapRow
}

// minimapMark is a bar of the minimap: cells columns from column col of row, in color, its
// syntax color, opaque; the paint makes it translucent.
type minimapMark struct {
	row, col, cells int32
	color           gfx.Color
}

// minimapKey is what the minimap's bars depend on: the text, the highlighter's colors, the
// layout of the rows, the columns, the theme, and the rows from first to last that they cover.
type minimapKey struct {
	revision, wrapCols, cols int
	gen                      uint64
	theme                    *syntax.Theme
	valid                    bool
	first, last              int
}

// SetMinimap says whether the window wants the minimap shown. The view leaves it out while it is
// too narrow for it.
func (v *View) SetMinimap(on bool) { v.minimap = on }

// minimapLayout is how the minimap places the text and the slider for the scroll: offset is how
// far its rows are scrolled, sliderTop where the slider starts against the minimap's top and
// sliderH its height, travel how far the slider moves from top to bottom and maxScroll the
// scroll at its bottom.
type minimapLayout struct {
	offset, sliderTop, sliderH, travel, maxScroll float32
}

// minimapLayout is the layout for the minimap of the last paint at the view's scroll. The slider
// is as high as the rows in view take in the minimap. A text that fits leaves the minimap still
// and the slider moves over its rows; a taller one moves the slider over the whole height and
// scrolls the rows so the slider stays over the rows in view.
func (v *View) minimapLayout() minimapLayout {
	mapH := v.mm.rect.Height
	l := minimapLayout{maxScroll: v.maxScroll()}
	l.sliderH = min(v.rowsHeight()/max(v.lineH, 1)*minimapRowH, mapH)
	// extent is where the slider's top is in the minimap's rows at the bottom of the scroll.
	extent := l.maxScroll / max(v.lineH, 1) * minimapRowH
	ratio := float32(0)
	if l.maxScroll > 0 {
		ratio = min(max(v.scroll/l.maxScroll, 0), 1)
	}
	if extent+l.sliderH <= mapH {
		l.travel = extent
	} else {
		l.travel = mapH - l.sliderH
		l.offset = ratio * (extent + l.sliderH - mapH)
	}
	l.sliderTop = ratio * l.travel
	return l
}

// scrollFor is the scroll that puts the slider's top at top, against the minimap's top.
func (l minimapLayout) scrollFor(top float32) float32 {
	if l.travel <= 0 {
		return 0
	}
	return min(max(top/l.travel, 0), 1) * l.maxScroll
}

// minimapRange is the layout of the minimap and the first and last rows it shows. ok is false
// when the minimap is not shown.
func (v *View) minimapRange() (l minimapLayout, first, last int, ok bool) {
	if v.mm.rect.Width <= 0 || v.mm.rect.Height <= 0 {
		return minimapLayout{}, 0, 0, false
	}
	l = v.minimapLayout()
	rows := v.rowCount()
	first = min(int(l.offset/minimapRowH), rows-1)
	last = min(int((l.offset+v.mm.rect.Height)/minimapRowH), rows-1)
	return l, first, last, true
}

// pressMinimap scrolls for a press on the minimap at y and holds the slider. A press beside the
// slider first brings the row under it to the middle of the view; the slider then moves with
// the pointer from wherever it is.
func (v *View) pressMinimap(y float32) {
	if v.mm.rect.Height <= 0 {
		return
	}
	l := v.minimapLayout()
	top := v.mm.rect.Y + l.sliderTop
	if y < top || y >= top+l.sliderH {
		row := (y - v.mm.rect.Y + l.offset) / minimapRowH
		v.scroll = row*v.lineH - v.area.Height/2
		v.clampScroll()
		l = v.minimapLayout()
		top = v.mm.rect.Y + l.sliderTop
	}
	v.grip = grip{kind: gripMinimap, at: y - top}
}

// paintMinimap draws the minimap: the selected lines' band, the bars of the rows it shows and
// the slider, and declares its hit. selStart and selEnd are the selection.
func (v *View) paintMinimap(canvas *gfx.Canvas, look Look, selStart, selEnd int) {
	l, first, last, ok := v.minimapRange()
	if !ok {
		return
	}
	rect := v.mm.rect
	v.buildMinimap(first, last, max(int((rect.Width-minimapPad)/minimapCell), 1))
	// The rows move by whole points, so the bars do not shimmer as the minimap scrolls.
	origin := rect.Y - float32(math.Round(float64(l.offset)))
	bottom := rect.Y + rect.Height
	canvas.Clip(rect)
	if selStart != selEnd {
		from := origin + float32(v.lineRow(v.text.LineOf(selStart)))*minimapRowH
		to := origin + float32(v.lineRowEnd(v.text.LineOf(selEnd)))*minimapRowH
		from, to = max(from, rect.Y), min(to, bottom)
		if to > from {
			canvas.Fill(gfx.Rect{X: rect.X, Y: from, Width: rect.Width, Height: to - from}, look.Selection)
		}
	}
	left := rect.X + minimapPad
	alpha := minimapAlphaLight
	if look.Dark {
		alpha = minimapAlphaDark
	}
	for _, m := range v.mm.marks {
		y := origin + float32(m.row)*minimapRowH
		canvas.Fill(gfx.Rect{X: left + float32(m.col)*minimapCell, Y: y, Width: float32(m.cells) * minimapCell, Height: minimapInk}, m.color.WithAlpha(alpha))
	}
	id := v.cfg.MinimapID
	lit := float32(0)
	if !id.IsZero() {
		target := float32(0)
		switch {
		case v.grip.kind == gripMinimap || canvas.Pressed() == id:
			target = 1
		case canvas.Hovered() == id:
			target = 0.5
		}
		lit = canvas.Animate(id, 0, target, gfx.DefaultMotion())
	}
	slider := look.Subtle.WithAlpha(look.Subtle.Alpha * (0.14 + 0.2*lit))
	canvas.Fill(gfx.Rect{X: rect.X, Y: rect.Y + l.sliderTop, Width: rect.Width, Height: l.sliderH}, slider)
	canvas.Unclip()
	if !id.IsZero() {
		canvas.HitWithOptions(id, rect, v.words.Minimap, gfx.HitOptions{Role: gfx.RoleSeparator, SkipFocus: true})
	}
}

// lineRowEnd is the row after the last row of line.
func (v *View) lineRowEnd(line int) int {
	if !v.wrapping() {
		return line + 1
	}
	v.ensureRows()
	return int(v.rowStart[min(max(line, 0), len(v.wraps)-1)+1])
}

// buildMinimap makes the bars of rows first to last at cols columns, unless the ones kept are
// of them already. When only the rows changed, the bars of the rows still shown are kept and
// only the rows that came into the minimap are made.
func (v *View) buildMinimap(first, last, cols int) {
	key := minimapKey{
		revision: v.revision, wrapCols: v.wrapCols, cols: cols, gen: v.hlGen.Load(),
		theme: v.theme, valid: true, first: first, last: last,
	}
	old := v.mm.key
	if key == old {
		return
	}
	v.mm.key = key
	// same is the old key with the new rows: the bars kept are still right for their rows.
	same := old
	same.first, same.last = first, last
	if same != key {
		v.mm.marks = v.mm.marks[:0]
		v.markRows(first, last, cols)
		return
	}
	kept := v.mm.marks[:0]
	for _, m := range v.mm.marks {
		if int(m.row) >= first && int(m.row) <= last {
			kept = append(kept, m)
		}
	}
	v.mm.marks = kept
	if first < old.first {
		v.markRows(first, min(old.first-1, last), cols)
	}
	if last > old.last {
		v.markRows(max(old.last+1, first), last, cols)
	}
}

// markRows adds the bars of rows first to last, at cols columns.
func (v *View) markRows(first, last, cols int) {
	if first > last {
		return
	}
	line, sub := v.rowLine(first)
	row := first
	for row <= last && line < v.text.LineCount() {
		text := v.line(line)
		rows := v.minimapRows(line, text)
		v.mm.tokens = v.hl.Line(v.mm.tokens[:0], line)
		for k := sub; k < len(rows) && row <= last; k++ {
			end := len(text)
			if k+1 < len(rows) {
				end = rows[k+1].at
			}
			v.markRow(text, rows[k], end, int32(row), cols)
			row++
		}
		line, sub = line+1, 0
	}
}

// minimapRows is the rows of line, whose text is text, as the view lays them out. A line the
// view has not broken lately is broken into scratch space, so the minimap's many rows never
// push the visible lines out of the view's cache.
func (v *View) minimapRows(line int, text string) []wrapRow {
	if !v.wrapping() || len(text)*tabSize <= v.wrapCols {
		return oneRow
	}
	if rows, ok := v.rowCache[line]; ok {
		return rows
	}
	v.mm.rows = wrapLine(v.mm.rows[:0], text, v.wrapCols)
	return v.mm.rows
}

// markRow adds the bars of a row of a line, whose text is text: the bytes from row to end, row
// being row of the view. A run of characters of one color is one bar, and spaces, tabs and
// control characters leave gaps. A wrapped row starts at the minimap's left edge, as it does in
// the view; columns past cols are left out. The tokens of the line are in v.mm.tokens.
func (v *View) markRow(text string, row wrapRow, end int, at int32, cols int) {
	tokens := v.mm.tokens
	token := max(sort.Search(len(tokens), func(i int) bool { return int(tokens[i].Start) > row.at })-1, 0)
	colored := -1
	var color gfx.Color
	// mark is the bar being made longer, -1 after a gap.
	mark := -1
	cells := row.cells
	for i, r := range text[row.at:end] {
		i += row.at
		w := runeCells(r, cells)
		col := cells - row.cells
		cells += w
		if w == 0 {
			continue
		}
		if col >= cols {
			break
		}
		if r == ' ' || r == '\t' || r < 0x20 {
			mark = -1
			continue
		}
		for token+1 < len(tokens) && int(tokens[token+1].Start) <= i {
			token++
		}
		if token != colored {
			colored = token
			style := v.theme.Default()
			if token < len(tokens) {
				style = v.theme.Style(tokens[token].Name)
			}
			color = uiColor(style.Foreground)
		}
		w = min(w, cols-col)
		if mark >= 0 {
			if m := &v.mm.marks[mark]; m.color == color && int(m.col+m.cells) == col {
				m.cells += int32(w)
				continue
			}
		}
		v.mm.marks = append(v.mm.marks, minimapMark{row: at, col: int32(col), cells: int32(w), color: color})
		mark = len(v.mm.marks) - 1
	}
}

// paintToggle draws the button that hides the minimap, at the minimap's left edge while the
// pointer is over the minimap or near that edge, or the one that shows it again, at the text's
// right edge while the pointer is near it, and declares its hit while it shows. It fades in and out, and is
// painted last so it lies over the text and the minimap. A view too narrow for the minimap
// the window wants shows neither.
func (v *View) paintToggle(canvas *gfx.Canvas, look Look) {
	id := v.cfg.MinimapToggleID
	if id.IsZero() {
		return
	}
	hovered, pressed := canvas.Hovered(), canvas.Pressed()
	area := v.area
	center := area.Y + area.Height/2
	rect := gfx.Rect{Y: float32(math.Round(float64(center - toggleH/2))), Width: toggleW, Height: toggleH}
	var icon gfx.Icon
	var label string
	near := hovered == id || pressed == id || (v.edgeHot && hovered == v.cfg.HitID)
	switch {
	case v.mm.rect.Width > 0:
		rect.X = v.mm.rect.X - toggleW
		icon, label = icons.ChevronRight, v.words.HideMinimap
		near = near || hovered == v.cfg.MinimapID || v.grip.kind == gripMinimap
	case !v.minimap:
		rect.X = area.X + area.Width - barTrack - toggleW
		icon, label = icons.ChevronLeft, v.words.ShowMinimap
		near = near || hovered == v.cfg.VerticalBarID
	default:
		return
	}
	if rect.Height > area.Height || rect.X < v.textLeft {
		return
	}
	target := float32(0)
	if near {
		target = 1
	}
	fade := canvas.Animate(id, 0, target, gfx.DefaultMotion())
	if fade <= 0.01 {
		return
	}
	hot := hovered == id || pressed == id
	ground, tint := look.Button, look.Subtle
	if hot {
		ground, tint = look.ButtonHover, look.Foreground
	}
	canvas.RoundedBorder(rect, 4, 1, look.ButtonBorder.WithAlpha(look.ButtonBorder.Alpha*fade), ground.WithAlpha(ground.Alpha*fade))
	glyph := gfx.Rect{X: rect.X + (toggleW-toggleIcon)/2, Y: rect.Y + (toggleH-toggleIcon)/2, Width: toggleIcon, Height: toggleIcon}
	canvas.DrawIcon(icon, glyph, tint.WithAlpha(tint.Alpha*fade))
	canvas.HitWithOptions(id, rect, label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, SkipFocus: true})
}
