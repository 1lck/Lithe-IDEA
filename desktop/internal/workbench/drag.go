package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

const (
	// dragThreshold is how far in pixels the pointer must move with a button held before
	// the press counts as a drag. Below it the press stays an ordinary click, so a click
	// that wobbles by a pixel still activates the button.
	dragThreshold = 4
	// dragLayer paints the ghost and the drop marks above Draw's content (layer 0) and
	// above the menus (layer 1).
	dragLayer uint16 = 2
	// dragMark is the thickness of the insertion line, dragMarkInset how far it stays
	// from the zone's sides and dragMarkLead where it sits in a zone with no other button.
	dragMark      = 2
	dragMarkInset = 1
	dragMarkLead  = 2
	// dragZoneTint is the opacity of the accent color over every zone the button may go
	// to, and dragTargetTint over the one it would land in.
	dragZoneTint   = 0.06
	dragTargetTint = 0.10
	// dragZoneOutset widens a zone's tint past its buttons, and dragZoneRadius rounds it.
	dragZoneOutset = 2
	dragZoneRadius = 4
	// The copy of the button that follows the pointer: its size, its distance below and to
	// the right of the pointer, the room it keeps from the window's edge, and its corners.
	dragGhostSize   = 36
	dragGhostOffset = 12
	dragGhostMargin = 4
	dragGhostRadius = 7
)

// dragState is the gesture that moves a rearrangeable button. The zero value is no
// gesture.
type dragState struct {
	// pressed says the primary button went down on the button of catalog item item; active
	// says the pointer then moved far enough for the press to be a drag.
	pressed, active bool
	item            int
	// startX and startY are where the press began and x and y where the pointer is now.
	startX, startY float32
	x, y           float32
	// target is where the button would land if it were dropped now; hasTarget is false
	// while the pointer is somewhere a button of its surface cannot go.
	target    dragTarget
	hasTarget bool
	// viewport is the window's size at the last move, which keeps the ghost inside it.
	viewport ui.Size
}

// dragTarget is a place a dragged button can be dropped.
type dragTarget struct {
	zone zone
	// before is the identifier of the button the dragged one would stand in front of;
	// empty means the end of the zone. It is what the kernel's move action takes.
	before string
	// mark is the insertion line, in window coordinates.
	mark ui.Rect
}

// dragPointer follows a press on a rearrangeable button. It leaves the press alone until
// the pointer has moved by dragThreshold, so the button still gets its ordinary click;
// from then on it takes every event of the gesture. Taking an event is what keeps the
// release from becoming a click, because the runtime clicks only when neither the
// press nor the release was handled.
func (a *App) dragPointer(event ui.PointerEvent) (ui.EventResult, bool) {
	d := &a.drag
	switch event.Kind {
	case ui.PointerDown:
		*d = dragState{}
		if event.Button != ui.PointerButtonPrimary {
			return ui.EventResult{}, false
		}
		if i, ok := event.Target.In(chromeButtons); ok && i < len(catalog) {
			*d = dragState{pressed: true, item: i, startX: event.X, startY: event.Y}
		}
		// The button under the pointer still gets its press.
		return ui.EventResult{}, false

	case ui.PointerMove:
		if !d.pressed {
			return ui.EventResult{}, false
		}
		if !d.active {
			dx, dy := event.X-d.startX, event.Y-d.startY
			if dx*dx+dy*dy < dragThreshold*dragThreshold {
				return ui.EventResult{}, false
			}
			d.active = true
		}
		d.x, d.y, d.viewport = event.X, event.Y, event.Viewport
		d.target, d.hasTarget = a.dragLocate(d.item, event.X, event.Y, event.Viewport)
		return ui.EventResult{Handled: true, Repaint: true}, true

	case ui.PointerUp:
		if !d.active {
			*d = dragState{}
			return ui.EventResult{}, false
		}
		// The place is worked out again at the release: the last move may be older than
		// the release by a frame in which the layout changed.
		item := d.item
		target, ok := a.dragLocate(item, event.X, event.Y, event.Viewport)
		*d = dragState{}
		if ok {
			a.reduceChrome(core.MoveChrome(catalog[item].id, zoneNames[target.zone], target.before))
		}
		return ui.EventResult{Handled: true, Repaint: true}, true

	case ui.PointerExit:
		// The runtime reports an exit during a held press only once the button is released,
		// so this ends a gesture whose release was lost.
		active := d.active
		*d = dragState{}
		return ui.EventResult{Repaint: active}, active
	}
	return ui.EventResult{}, false
}

// cancelDrag drops the gesture without moving anything and reports whether a drag was
// under way, so that the key that cancelled it is not also given to something else.
func (a *App) cancelDrag() bool {
	active := a.drag.active
	a.drag = dragState{}
	return active
}

// draggingToolButton reports that a button of the tool stripes is being dragged, which is
// when the stripes show every zone as a place to drop it (see drawStripe).
func (a *App) draggingToolButton() bool {
	return a.drag.active && a.chrome.zoneOf(a.drag.item).surface() == surfaceStripes
}

// dragLocate finds where dropping catalog item item at (x, y) would put it. A button
// never leaves its surface: a stripe button lands in one of the six stripe zones, a
// title bar button in the title bar and a status bar button in the status bar, so
// anywhere else there is no place and the drop is cancelled. viewport is the window's
// size, which is where the right stripe and the status bar are.
func (a *App) dragLocate(item int, x, y float32, viewport ui.Size) (dragTarget, bool) {
	var target dragTarget
	if x < 0 || y < 0 || x >= viewport.Width || y >= viewport.Height {
		return target, false
	}
	switch a.chrome.zoneOf(item).surface() {
	case surfaceTitle:
		if y >= titleBarHeight {
			return target, false
		}
		target.zone = zoneTitle
	case surfaceStatus:
		if y < viewport.Height-statusBarHeight {
			return target, false
		}
		target.zone = zoneStatus
	default:
		z, ok := a.dragStripeZone(x, y, viewport)
		if !ok {
			return target, false
		}
		target.zone = z
	}
	target.before, target.mark = a.dragInsertion(item, target.zone, x, y)
	return target, true
}

// dragStripeZone is the zone of a stripe at (x, y): the stripe is the one the pointer is
// over, and the zone one of the three it has, from the top down: the top zone, the split
// zone under it and the bottom zone.
//
// The zones are told apart by where the last frame laid them out. The top and the split
// zone are as high as their buttons, one button at least while a button is dragged (see
// drawStripe), and the bottom zone takes the rest of the stripe. So the pointer is in the
// top zone until the top zone ends, and in the split zone until it ends too, with half a
// button of room past it because the buttons of the bottom zone are packed at the far end
// and the empty room between would otherwise belong to no zone a person aims for.
// Anywhere below that is the bottom zone. Before the stripe has been laid out, the
// stripe is split in half between the top and the bottom zone.
func (a *App) dragStripeZone(x, y float32, viewport ui.Size) (zone, bool) {
	if y < titleBarHeight || y >= viewport.Height-statusBarHeight {
		return 0, false
	}
	top, split, end := zoneLeftTop, zoneLeftBottom, zoneBottomLeft
	switch {
	case x < stripeWidth:
	case x >= viewport.Width-stripeWidth:
		top, split, end = zoneRightTop, zoneRightBottom, zoneBottomRight
	default:
		return 0, false
	}
	topRect, splitRect, endRect := a.chrome.zoneRects[top], a.chrome.zoneRects[split], a.chrome.zoneRects[end]
	if topRect.Height <= 0 && splitRect.Height <= 0 && endRect.Height <= 0 {
		if y < titleBarHeight+(viewport.Height-titleBarHeight-statusBarHeight)/2 {
			return top, true
		}
		return end, true
	}
	switch {
	case y < topRect.Y+topRect.Height:
		return top, true
	case y < splitRect.Y+splitRect.Height+chromeToolButton/2:
		return split, true
	}
	return end, true
}

// dragInsertion finds where in zone z the dragged button would stand for a pointer at
// (x, y): in front of the first other button whose middle is past the pointer along
// the zone, or at the end. It returns the identifier of that button, empty for the end,
// and the insertion line. The dragged button is not counted among the others, so moving
// it by less than its own size does not jump.
//
// As in motty, the line crosses the whole zone (a vertical line in a bar, a horizontal
// one in a stripe), so it reads as the place between two buttons rather than as part of
// either.
func (a *App) dragInsertion(item int, z zone, x, y float32) (string, ui.Rect) {
	vertical := z.vertical()
	zr := a.chrome.zoneRects[z]
	// position is where the line starts along the zone; before is the button it precedes.
	position, before := zr.X+dragMarkLead, ""
	if vertical {
		position = zr.Y + dragMarkLead
		if z == zoneBottomLeft || z == zoneBottomRight {
			// The bottom zone of a stripe packs its buttons at its bottom.
			position = zr.Y + zr.Height - dragMarkLead - dragMark
		}
	}
	for _, other := range a.chrome.items[z] {
		r := a.chrome.rects[other]
		if other == item || r.Width <= 0 || r.Height <= 0 {
			continue
		}
		start, extent, pointer := r.X, r.Width, x
		if vertical {
			start, extent, pointer = r.Y, r.Height, y
		}
		if pointer < start+extent/2 {
			// The line sits in the middle of the gap in front of the button.
			position, before = start-(chromeGap+dragMark)/2, catalog[other].id
			break
		}
		position = start + extent + (chromeGap-dragMark)/2
	}
	if vertical {
		position = min(max(position, zr.Y), zr.Y+zr.Height-dragMark)
		return before, ui.Rect{X: zr.X + dragMarkInset, Y: position, Width: zr.Width - 2*dragMarkInset, Height: dragMark}
	}
	position = min(max(position, zr.X), zr.X+zr.Width-dragMark)
	return before, ui.Rect{X: position, Y: zr.Y + dragMarkInset, Width: dragMark, Height: zr.Height - 2*dragMarkInset}
}

// paintDrag paints the gesture on top of the frame, as motty does: every zone the
// button may go to is lightly tinted, the zone it would land in more strongly, the
// insertion line is drawn in the accent color, and a small copy of the button follows
// the pointer below and to the right of it, so it never hides the line. The source
// button stays where it is, dimmed (see chromeBox).
func (a *App) paintDrag(canvas *ui.Canvas) {
	d := &a.drag
	if !d.active {
		return
	}
	canvas.PushLayer(dragLayer)
	defer canvas.PopLayer()
	surface := a.chrome.zoneOf(d.item).surface()
	for z := range a.chrome.zoneRects {
		if zone(z).surface() != surface {
			continue
		}
		tint := float32(dragZoneTint)
		if d.hasTarget && d.target.zone == zone(z) {
			tint = dragTargetTint
		}
		if r := a.chrome.zoneRects[z]; r.Width > 0 && r.Height > 0 {
			canvas.Rounded(r.Inset(ui.All(-dragZoneOutset)), dragZoneRadius, a.colors.Accent.WithAlpha(tint))
		}
	}
	if d.hasTarget {
		canvas.Rounded(d.target.mark, dragMark/2, a.colors.Accent)
	}

	// The copy is an icon in a small square, or the button's own width when it shows
	// words, kept inside the window.
	icon := catalog[d.item].icon
	text := a.dragGhostText(d.item)
	ghost := ui.Rect{X: d.x + dragGhostOffset, Y: d.y + dragGhostOffset, Width: dragGhostSize, Height: dragGhostSize}
	if text != "" {
		ghost.Width = max(dragGhostSize, a.chrome.rects[d.item].Width)
		ghost.Height = max(chromeStatusItem, a.chrome.rects[d.item].Height)
	}
	if d.viewport.Width > 0 {
		ghost.X = max(min(ghost.X, d.viewport.Width-ghost.Width-dragGhostMargin), 0)
		ghost.Y = max(min(ghost.Y, d.viewport.Height-ghost.Height-dragGhostMargin), 0)
	}
	canvas.RoundedBorder(ghost, dragGhostRadius, 1, a.colors.Accent, a.colors.Editor)

	style := ui.TextStyle{Size: a.theme.Metrics.FontSizeS, Weight: ui.WeightRegular, Color: a.colors.Text}
	switch {
	case icon != nil && text == "":
		canvas.DrawIcon(*icon, ghost.Inset(ui.All((dragGhostSize-chromeIconSize)/2)), a.colors.Text)
	case icon != nil:
		// An icon with words, as the run configuration has: the icon first and the words
		// after it, as in the button.
		canvas.DrawIcon(*icon, ui.Rect{
			X:      ghost.X + chromeEdge,
			Y:      ghost.Y + (ghost.Height-chromeIconSize)/2,
			Width:  chromeIconSize,
			Height: chromeIconSize,
		}, a.colors.Subtle)
		canvas.Label(text, ui.Rect{
			X:      ghost.X + chromeEdge + chromeIconSize + chromeGap,
			Y:      ghost.Y,
			Width:  ghost.Width - 2*chromeEdge - chromeIconSize - chromeGap,
			Height: ghost.Height,
		}, style)
	case text != "":
		canvas.LabelCenter(text, ghost, style)
	}
}

// dragGhostText is the words the ghost of catalog item item shows beside or instead of
// its icon: the reading of a status item, or the name of the run configuration. The
// other buttons are icons only.
func (a *App) dragGhostText(item int) string {
	if catalog[item].id == itemRunConfig {
		return a.text.Title.CurrentFile
	}
	return a.chromeStatusText(item)
}
