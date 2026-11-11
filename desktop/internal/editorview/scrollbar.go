package editorview

import "github.com/vivaui/viva/gfx"

// The scrollbars are the view's own, not Viva's scroll area: the view scrolls by rows, keeps
// the minimap between the text and the vertical bar, and lets the window know which of its
// parts the pointer is over. A bar is a track along the edge whose thumb is as long, against
// the track, as the view is against the text. Pressing the thumb holds it, and the text
// follows while it is dragged; pressing the track beside it scrolls a page towards the press.

// barTrack is the thickness of a scrollbar's track, where it takes the pointer; the thumb is
// barWidth of it, in the middle.
const barTrack = float32(10)

// gripKind is which part a press holds while it is dragged.
type gripKind uint8

const (
	gripNone gripKind = iota
	gripVertical
	gripHorizontal
	gripMinimap
)

// grip is the part a press holds, and where on it the press was: how far from the thumb's or
// the slider's start, so the part keeps under the pointer as it moves.
type grip struct {
	kind gripKind
	at   float32
}

// barLayout is where the last paint put the scrollbars' tracks. A track is empty when its bar
// has nothing to scroll.
type barLayout struct {
	vertical, horizontal gfx.Rect
}

// layoutParts places the minimap and the scrollbars for the paint of v.area, whose line numbers
// take gutter: the vertical bar at the right edge, the minimap left of it when the window wants
// it and the text leaves it room, and the horizontal bar under the text. It sets textRight.
func (v *View) layoutParts(gutter float32) {
	area := v.area
	right := area.X + area.Width
	v.mm.rect = gfx.Rect{}
	v.textRight = right
	if v.minimap && area.Width-gutter-minimapWidth-barTrack >= minimapRoom*minimapWidth {
		v.mm.rect = gfx.Rect{X: right - barTrack - minimapWidth, Y: area.Y, Width: minimapWidth, Height: area.Height}
		v.textRight = v.mm.rect.X
	}
	v.bars.vertical = gfx.Rect{X: right - barTrack, Y: area.Y, Width: barTrack, Height: area.Height}
	// The horizontal bar runs under the text and stops short of the vertical one, so their
	// corners never overlap; with the minimap shown the vertical bar is past it already.
	end := v.textRight
	switch {
	case v.decor.noVerticalBar:
		v.bars.vertical = gfx.Rect{}
	case v.mm.rect.Width == 0:
		end -= barTrack
	}
	v.bars.horizontal = gfx.Rect{X: area.X + gutter, Y: area.Y + area.Height - barTrack, Width: max(end-area.X-gutter, 0), Height: barTrack}
}

// maxScroll is how far the text scrolls down: until its last row is at the bottom of the rows in
// view, and not at all while the text fits.
func (v *View) maxScroll() float32 {
	return max(float32(v.rowCount())*v.lineH-v.rowsHeight(), 0)
}

// rowsHeight is how high the rows in view are: the view's height, less the horizontal bar's
// track while it has something to scroll, so the bar's thumb never covers the last row.
func (v *View) rowsHeight() float32 {
	if v.maxScrollX() >= 0.5 {
		return max(v.area.Height-barTrack, 0)
	}
	return v.area.Height
}

// maxScrollX is how far the text scrolls sideways: until a few cells past its widest line show,
// and not at all while it wraps.
func (v *View) maxScrollX() float32 {
	if v.wrapping() {
		return 0
	}
	return max(float32(v.widest+4)*v.cellW-(v.textRight-v.textLeft), 0)
}

// verticalThumb is the thumb of the vertical bar, with the scroll its far end stands for. It is
// empty when there is nothing to scroll.
func (v *View) verticalThumb() (gfx.Rect, float32) {
	track, maxY := v.bars.vertical, v.maxScroll()
	if maxY < 0.5 || track.Height <= 0 {
		return gfx.Rect{}, 0
	}
	rows := v.rowsHeight()
	length := min(max(track.Height*rows/(maxY+rows), barMin), track.Height)
	y := track.Y + (track.Height-length)*min(max(v.scroll/maxY, 0), 1)
	return gfx.Rect{X: track.X + (track.Width-barWidth)/2, Y: y, Width: barWidth, Height: length}, maxY
}

// horizontalThumb is the thumb of the horizontal bar, as verticalThumb is of the vertical one.
func (v *View) horizontalThumb() (gfx.Rect, float32) {
	track, maxX := v.bars.horizontal, v.maxScrollX()
	width := v.textRight - v.textLeft
	if maxX < 0.5 || track.Width <= 0 || width <= 0 {
		return gfx.Rect{}, 0
	}
	length := min(max(track.Width*width/(maxX+width), barMin), track.Width)
	x := track.X + (track.Width-length)*min(max(v.scrollX/maxX, 0), 1)
	return gfx.Rect{X: x, Y: track.Y + (track.Height-barWidth)/2, Width: length, Height: barWidth}, maxX
}

// paintScrollbars draws the thumbs and declares the tracks' hits. A thumb brightens while the
// pointer is over its track and while it is dragged.
func (v *View) paintScrollbars(canvas *gfx.Canvas, look Look) {
	if thumb, _ := v.verticalThumb(); thumb.Height > 0 {
		v.paintThumb(canvas, v.cfg.VerticalBarID, v.bars.vertical, thumb, gripVertical, v.words.VerticalScrollbar, look)
	}
	if thumb, _ := v.horizontalThumb(); thumb.Width > 0 {
		v.paintThumb(canvas, v.cfg.HorizontalBarID, v.bars.horizontal, thumb, gripHorizontal, v.words.HorizontalScrollbar, look)
	}
}

// paintThumb draws one bar's thumb and declares its track, whose hit is id, when it has one.
func (v *View) paintThumb(canvas *gfx.Canvas, id gfx.ID, track, thumb gfx.Rect, kind gripKind, label string, look Look) {
	color := look.Scrollbar
	if !id.IsZero() {
		hot := float32(0)
		if v.grip.kind == kind || canvas.Hovered() == id || canvas.Pressed() == id {
			hot = 1
		}
		lit := canvas.Animate(id, 0, hot, gfx.DefaultMotion())
		color = color.WithAlpha(min(color.Alpha*(1+0.8*lit), 1))
		canvas.HitWithOptions(id, track, label, gfx.HitOptions{Role: gfx.RoleSeparator, SkipFocus: true})
	}
	canvas.Rounded(thumb, barWidth/2, color)
}

// chromePointer gives the scrollbars and the minimap the pointer: a press on a track or on the
// minimap, the drag of what it holds, and the pointer near the right edge, which shows the
// button that brings the minimap back. The second result is false for what is the text's.
func (v *View) chromePointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	if v.grip.kind != gripNone {
		switch event.Kind {
		case gfx.PointerMove, gfx.PointerUp:
			if v.painted {
				v.dragGrip(event.X, event.Y)
			}
			if event.Kind == gfx.PointerUp {
				v.grip = grip{}
			}
		case gfx.PointerExit:
			v.grip = grip{}
		}
		return handled, true
	}
	switch event.Kind {
	case gfx.PointerMove:
		if !v.dragging {
			return v.edgePointer(event)
		}
	case gfx.PointerExit:
		v.edgeHot = false
	case gfx.PointerDown:
		if !v.painted || event.Target.IsZero() || (event.Button != gfx.PointerButtonPrimary && event.Button != gfx.PointerButtonNone) {
			return gfx.EventResult{}, false
		}
		switch event.Target {
		case v.cfg.VerticalBarID:
			v.pressVertical(event.Y)
		case v.cfg.HorizontalBarID:
			v.pressHorizontal(event.X)
		case v.cfg.MinimapID:
			v.pressMinimap(event.Y)
		default:
			return gfx.EventResult{}, false
		}
		return handled, true
	}
	return gfx.EventResult{}, false
}

// pressVertical holds the vertical thumb pressed at y, or scrolls a page towards y when it is
// beside the thumb.
func (v *View) pressVertical(y float32) {
	thumb, _ := v.verticalThumb()
	if thumb.Height <= 0 {
		return
	}
	page := max(v.area.Height-v.lineH, v.lineH)
	switch {
	case y < thumb.Y:
		v.scroll -= page
	case y >= thumb.Y+thumb.Height:
		v.scroll += page
	default:
		v.grip = grip{kind: gripVertical, at: y - thumb.Y}
		return
	}
	v.clampScroll()
}

// pressHorizontal is pressVertical for the horizontal bar, pressed at x.
func (v *View) pressHorizontal(x float32) {
	thumb, _ := v.horizontalThumb()
	if thumb.Width <= 0 {
		return
	}
	page := max(v.textRight-v.textLeft-4*v.cellW, v.cellW)
	switch {
	case x < thumb.X:
		v.scrollX -= page
	case x >= thumb.X+thumb.Width:
		v.scrollX += page
	default:
		v.grip = grip{kind: gripHorizontal, at: x - thumb.X}
		return
	}
	v.clampScroll()
}

// dragGrip scrolls so the held thumb or slider is under the pointer at (x, y).
func (v *View) dragGrip(x, y float32) {
	switch v.grip.kind {
	case gripVertical:
		thumb, maxY := v.verticalThumb()
		if travel := v.bars.vertical.Height - thumb.Height; travel > 0 {
			v.scroll = (y - v.grip.at - v.bars.vertical.Y) / travel * maxY
		}
	case gripHorizontal:
		thumb, maxX := v.horizontalThumb()
		if travel := v.bars.horizontal.Width - thumb.Width; travel > 0 {
			v.scrollX = (x - v.grip.at - v.bars.horizontal.X) / travel * maxX
		}
	case gripMinimap:
		if v.mm.rect.Height > 0 {
			v.scroll = v.minimapLayout().scrollFor(y - v.grip.at - v.mm.rect.Y)
		}
	}
	v.clampScroll()
}

// edgePointer follows the pointer over the text near its right edge, where the button that hides
// the minimap, or the one that shows it again, appears: the pointer reaches the button from the
// text as well as from the minimap. It asks for a frame only when the pointer crosses into or
// out of that strip, and claims the move only when it is over this view's text, so the other
// views still see it. A view the pointer left without a move over it keeps edgeHot, but the
// button also needs the pointer over the text to show.
func (v *View) edgePointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	area := v.area
	over := event.Target == v.cfg.HitID
	hot := over && v.painted && !v.cfg.MinimapToggleID.IsZero() && (v.mm.rect.Width > 0 || !v.minimap) &&
		event.X >= v.textRight-edgeZone && event.X < v.textRight && event.Y >= area.Y && event.Y < area.Y+area.Height
	if hot == v.edgeHot {
		return gfx.EventResult{}, false
	}
	v.edgeHot = hot
	return gfx.EventResult{Repaint: true}, over
}
