package editorview

import "github.com/vivaui/viva/gfx"

// Per-line icons in the gutter: small icons on a line, such as a plugin's run, debug, test status or
// navigation actions. Each icon takes a slot, a column of the icon area after the line numbers, so a
// line can show one icon per lane side by side. The area exists only while some line has an icon,
// and it is as wide as the slots in use; the fold arrows come after it. A press on an icon calls
// the host with its line and slot, which decides what the icon stands for.

const (
	// lineIconWidth is the width of one slot, and lineIconInset the space left of an icon in it.
	lineIconWidth = float32(16)
	lineIconInset = float32(2)
	// lineIconSize caps an icon's side, so a tall line still shows a small one.
	lineIconSize = float32(12)
)

// LineIcon is an icon drawn in the gutter of one zero-based line, in the zero-based slot (column)
// of the icon area. A slot should be used densely: slots 0 to n-1 with no gap.
type LineIcon struct {
	Line int
	Slot int
	Icon gfx.Icon
}

// SetLineIcons replaces the icons of the gutter. The first icon of a line and slot wins; the slice is
// copied. The icon area is as wide as the highest slot in use.
func (v *View) SetLineIcons(icons []LineIcon) {
	g := &v.gutter
	g.icons = g.icons[:0]
	g.slots = 0
	type cell struct{ line, slot int }
	seen := map[cell]bool{}
	for _, icon := range icons {
		key := cell{icon.Line, icon.Slot}
		if icon.Line < 0 || icon.Slot < 0 || seen[key] || icon.Icon.ViewBox <= 0 {
			continue
		}
		seen[key] = true
		g.icons = append(g.icons, icon)
		g.slots = max(g.slots, icon.Slot+1)
	}
}

// SetLineIconClick makes presses on the line icons call fn with the line and slot of the icon.
func (v *View) SetLineIconClick(fn func(line, slot int)) { v.gutter.onIcon = fn }

// lineIconColumn is the width the icon area takes now: zero without icons.
func (v *View) lineIconColumn() float32 {
	return float32(v.gutter.slots) * lineIconWidth
}

// paintLineIcons draws the icons of the lines firstLine to lastLine, centered in their rows.
func (v *View) paintLineIcons(canvas *gfx.Canvas, area gfx.Rect, look Look, firstLine, lastLine int) {
	color := look.Subtle
	side := min(v.lineH-2, lineIconSize)
	for _, icon := range v.gutter.icons {
		if icon.Line < firstLine || icon.Line > lastLine || icon.Line >= v.text.LineCount() {
			continue
		}
		top := area.Y + float32(v.lineRow(icon.Line))*v.lineH - v.scroll
		x := v.iconX + float32(icon.Slot)*lineIconWidth
		canvas.DrawIcon(icon.Icon, gfx.Rect{X: x, Y: top + (v.lineH-side)/2, Width: side, Height: side}, color)
	}
}

// lineIconPointer takes a press on a line icon. It reports whether the press was consumed.
func (v *View) lineIconPointer(event gfx.PointerEvent) bool {
	g := &v.gutter
	if g.onIcon == nil || len(g.icons) == 0 || event.Button != gfx.PointerButtonPrimary {
		return false
	}
	if event.X < v.iconX {
		return false
	}
	offset := event.X - v.iconX
	slot := int(offset / lineIconWidth)
	if slot >= g.slots || offset-float32(slot)*lineIconWidth >= lineIconWidth-lineIconInset {
		return false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	row = min(max(row, 0), v.rowCount()-1)
	line, _ := v.rowLine(row)
	for _, icon := range g.icons {
		if icon.Line == line && icon.Slot == slot {
			g.onIcon(line, slot)
			return true
		}
	}
	return false
}
