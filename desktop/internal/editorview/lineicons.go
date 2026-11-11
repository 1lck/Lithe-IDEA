package editorview

import "github.com/vivaui/viva/gfx"

// Per-line icons in the gutter: a small icon on a line, such as a plugin's run or debug action. The
// icons sit in their own column after the line numbers, so the decoration bar and the numbers keep
// their places; the column exists only while some line has an icon. A press on an icon calls the
// host, which runs what the icon stands for.

const (
	// lineIconWidth is the column the icons take, and lineIconInset the space left of an icon in it.
	lineIconWidth = float32(16)
	lineIconInset = float32(2)
	// lineIconSize caps an icon's side, so a tall line still shows a small one.
	lineIconSize = float32(12)
)

// LineIcon is an icon drawn in the gutter of one zero-based line.
type LineIcon struct {
	Line int
	Icon gfx.Icon
}

// SetLineIcons replaces the icons of the gutter. The first icon of a line wins; the slice is copied.
func (v *View) SetLineIcons(icons []LineIcon) {
	g := &v.gutter
	g.icons = g.icons[:0]
	seen := map[int]bool{}
	for _, icon := range icons {
		if icon.Line < 0 || seen[icon.Line] || icon.Icon.ViewBox <= 0 {
			continue
		}
		seen[icon.Line] = true
		g.icons = append(g.icons, icon)
	}
}

// SetLineIconClick makes presses on the line icons call fn with the line.
func (v *View) SetLineIconClick(fn func(line int)) { v.gutter.onIcon = fn }

// lineIconColumn is the width the icon column takes now: zero without icons.
func (v *View) lineIconColumn() float32 {
	if len(v.gutter.icons) == 0 {
		return 0
	}
	return lineIconWidth
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
		canvas.DrawIcon(icon.Icon, gfx.Rect{X: v.iconX, Y: top + (v.lineH-side)/2, Width: side, Height: side}, color)
	}
}

// lineIconPointer takes a press on a line icon. It reports whether the press was consumed.
func (v *View) lineIconPointer(event gfx.PointerEvent) bool {
	g := &v.gutter
	if g.onIcon == nil || len(g.icons) == 0 || event.Button != gfx.PointerButtonPrimary {
		return false
	}
	if event.X < v.iconX || event.X >= v.iconX+lineIconWidth-lineIconInset {
		return false
	}
	row := int((event.Y - v.area.Y + v.scroll) / max(v.lineH, 1))
	row = min(max(row, 0), v.rowCount()-1)
	line, _ := v.rowLine(row)
	for _, icon := range g.icons {
		if icon.Line == line {
			g.onIcon(line)
			return true
		}
	}
	return false
}
