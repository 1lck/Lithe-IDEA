package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
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
	// dragGhostBorderWidth is the stroke used by the legacy title and status ghosts and by
	// the snapped stripe ghost.
	dragGhostBorderWidth = 1
	// dragSnappedGhostSize is the side of the stripe ghost, which fits the activity button
	// column without leaving its stripe.
	dragSnappedGhostSize = chromeToolButton
	// dragSnappedGhostIconInset centers the usual stripe icon inside its snapped button.
	dragSnappedGhostIconInset = (dragSnappedGhostSize - chromeIconSize) / 2
	// dragFloatingGhostSize, dragFloatingGhostRadius, and dragFloatingGhostBorderWidth size
	// the detached image to match the previous client's floating tool button.
	dragFloatingGhostSize        = 30
	dragFloatingGhostRadius      = 6
	dragFloatingGhostBorderWidth = 1
	// dragFloatingGhostIconInset centers the usual stripe icon inside the detached image.
	dragFloatingGhostIconInset = (dragFloatingGhostSize - chromeIconSize) / 2
	// dragFloatingGhostOpacity is applied to the detached image's surface and icon.
	dragFloatingGhostOpacity = 0.85
	// These are the rounded square's border and fill colors in the two workbench themes.
	dragFloatingGhostDarkRGB  uint32 = 0x40434A
	dragFloatingGhostLightRGB uint32 = 0xDDDFE4
	// These colors tint the pane under a detached drop preview in dark and light themes.
	dragPreviewDarkRGB  uint32 = 0x366ACF
	dragPreviewLightRGB uint32 = 0xA0BDF8
	// dragPreviewAlpha is the preview fill's 77/255 opacity.
	dragPreviewAlpha float32 = 77.0 / 255.0
	// The detached preview label uses a 12 point font, eight pixels of padding and six
	// pixel corners so it stays readable over the pane highlight.
	dragPreviewLabelFontSize = 12
	dragPreviewLabelPadding  = 8
	dragPreviewLabelRadius   = 6
)

// dragState is the gesture that moves a rearrangeable button. The zero value is no
// gesture.
type dragState struct {
	// active says a button of catalog item item is being dragged.
	active bool
	item   int
	// sourceZone stays fixed for the gesture so a detached drop keeps source-anchor
	// priority. snappedStripe can change when a detached drag returns to either stripe.
	sourceZone    zone
	snappedStripe stripeSide
	phase         dragPhase
	// x and y are where the pointer is now.
	x, y float32
	// grab is the press point inside the source button, retained by both stripe ghosts.
	grab gfx.Point
	// target is where the button would land if it were dropped now; hasTarget is false
	// while the pointer is somewhere a button of its surface cannot go.
	target    dragTarget
	hasTarget bool
	// viewport is the window's size at the last move, which keeps the ghost inside it.
	viewport gfx.Size
}

// dragTarget is a place a dragged button can be dropped.
type dragTarget struct {
	zone zone
	// before is the identifier of the button the dragged one would stand in front of;
	// empty means the end of the zone. It is what the kernel's move action takes.
	before string
	// mark is the insertion line, in window coordinates.
	mark gfx.Rect
	// preview is the dock pane rectangle highlighted while a tool button is detached.
	preview gfx.Rect
}

// dragDrop holds the page's drag and drop gestures: the tool buttons of the stripes, the
// title bar and the status bar, and the terminals' tabs. Each is declared by the elements
// that are its sources and by one target that covers the window; the places a drop can land
// are worked out from the geometry of the last paint by pure functions (dragLocate, dropAt),
// which the target's accept callback runs for the pointer's position.
type dragDrop struct {
	tool, tab ui.DragState
}

// toolAccept is the tool button target's accept callback: it follows the pointer of the drag
// of a button, works out where dropping it would put it and says whether that is a place.
// Viva asks it for every move of the drag and once more for the release.
func (a *App) toolAccept(source, _ gfx.ID) bool {
	item := -1
	for i, id := range a.chrome.ids {
		if id == source && !id.IsZero() {
			item = i
			break
		}
	}
	if item < 0 {
		return false
	}
	d := &a.drag
	point := a.dnd.tool.At()
	if !d.active || d.item != item {
		button := a.chrome.rects[item]
		z := a.chrome.zoneOf(item)
		side, _ := stripeForZone(z)
		*d = dragState{
			active: true, item: item, sourceZone: z, snappedStripe: side,
			grab: gfx.Point{X: point.X - button.X, Y: point.Y - button.Y},
		}
	}
	d.x, d.y, d.viewport = point.X, point.Y, a.viewport()
	if d.sourceZone.surface() == surfaceStripes {
		d.phase, d.snappedStripe = dragPhaseAt(d.phase, d.snappedStripe, point, dragStripeRects(gfx.Rect{
			Width: d.viewport.Width, Height: d.viewport.Height,
		}))
	}
	d.target, d.hasTarget = a.dragLocate(d.item, d.sourceZone, point, d.viewport, d.phase, d.snappedStripe)
	return d.hasTarget
}

// toolDrop moves the dragged button where toolAccept last found a place for it.
func (a *App) toolDrop(_, _ gfx.ID) {
	d := a.drag
	a.drag = dragState{}
	if d.active && d.hasTarget {
		a.reduceChrome(core.MoveChrome(a.chrome.catalog[d.item].id, zoneNames[d.target.zone], d.target.before))
	}
}

// viewport is the size of the window as the last paint knew it.
func (a *App) viewport() gfx.Size {
	return gfx.Size{Width: a.layout.windowW, Height: a.layout.windowH}
}

// endDrags forgets the bookkeeping of a gesture that is over: Viva owns the press, so a
// gesture it let go of (a release over no place, Escape, a lost release) is noticed here.
func (a *App) endDrags() {
	if !a.dnd.tool.Dragging() {
		a.drag = dragState{}
	}
	if !a.dnd.tab.Dragging() {
		a.term.drag = tabDrag{}
	}
}

// draggingToolButton reports that a button of the tool stripes is being dragged, which is
// when the stripes show every zone as a place to drop it (see stripe).
func (a *App) draggingToolButton() bool {
	return a.dnd.tool.Dragging() && a.drag.active && a.drag.sourceZone.surface() == surfaceStripes
}

// dragLocate finds where dropping item at point would put it. Tool buttons use their
// snapped stripe or detached dock geometry; title and status items keep their existing
// bar-only targets. A point outside the window never produces a target.
func (a *App) dragLocate(item int, source zone, point gfx.Point, viewport gfx.Size, phase dragPhase, snapped stripeSide) (dragTarget, bool) {
	var target dragTarget
	if point.X < 0 || point.Y < 0 || point.X >= viewport.Width || point.Y >= viewport.Height {
		return target, false
	}
	switch source.surface() {
	case surfaceTitle:
		if point.Y >= titleBarHeight {
			return target, false
		}
		target.zone = zoneTitle
	case surfaceStatus:
		if point.Y < viewport.Height-statusBarHeight {
			return target, false
		}
		target.zone = zoneStatus
	default:
		if phase == dragSnapped {
			zones := stripeZones(snapped)
			stripes := dragStripeRects(gfx.Rect{Width: viewport.Width, Height: viewport.Height})
			z, ok := dragStripeZoneAt(point, stripes[snapped], snapped,
				a.chrome.zoneRects[zones[0]], a.chrome.zoneRects[zones[1]], a.chrome.zoneRects[zones[2]])
			if !ok {
				return target, false
			}
			target.zone = z
		} else {
			return a.dragDetachedTarget(item, source, point, viewport)
		}
	}
	target.before, target.mark = a.dragInsertion(item, target.zone, point.X, point.Y)
	return target, true
}

// dragDetachedTarget finds a button or dock area under a floating tool drag and adds the
// insertion line in that zone's stripe.
func (a *App) dragDetachedTarget(item int, source zone, point gfx.Point, viewport gfx.Size) (dragTarget, bool) {
	z, preview, ok := dragDockTargetAt(
		point, item, source, a.dragDockButtons(item), a.dragDockAnchors(viewport),
	)
	if !ok {
		return dragTarget{}, false
	}
	before, mark := a.dragInsertion(item, z, point.X, point.Y)
	return dragTarget{zone: z, before: before, mark: mark, preview: preview}, true
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
func (a *App) dragInsertion(item int, z zone, x, y float32) (string, gfx.Rect) {
	vertical := z.vertical()
	zr := a.chrome.zoneRects[z]
	// position is where the line starts along the zone; before is the button it precedes.
	position, before := zr.X+dragMarkLead, ""
	if vertical {
		position = zr.Y + dragMarkLead
		if z == zoneBottomLeft || z == zoneBottomRight {
			// The empty bottom group sits at the stripe's end, so its mark belongs there.
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
			position, before = start-(chromeGap+dragMark)/2, a.chrome.catalog[other].id
			break
		}
		position = start + extent + (chromeGap-dragMark)/2
	}
	if vertical {
		position = min(max(position, zr.Y), zr.Y+zr.Height-dragMark)
		return before, gfx.Rect{X: zr.X + dragMarkInset, Y: position, Width: zr.Width - 2*dragMarkInset, Height: dragMark}
	}
	position = min(max(position, zr.X), zr.X+zr.Width-dragMark)
	return before, gfx.Rect{X: position, Y: zr.Y + dragMarkInset, Width: dragMark, Height: zr.Height - 2*dragMarkInset}
}

// paintDrag paints the gesture above the frame: stripe zones stay tinted, detached dock
// targets show their pane preview and localized title, and the insertion line marks the
// position in the target zone. A snapped stripe ghost stays in its button column, while a
// detached ghost follows the pointer with its original grab point. The source button stays
// where it is, dimmed (see chromeBox).
func (a *App) paintDrag(canvas *gfx.Canvas) {
	d := &a.drag
	if !d.active {
		return
	}
	canvas.PushLayer(dragLayer)
	defer canvas.PopLayer()
	surface := d.sourceZone.surface()
	for z := range a.chrome.zoneRects {
		if zone(z).surface() != surface {
			continue
		}
		tint := float32(dragZoneTint)
		if d.hasTarget && d.target.zone == zone(z) {
			tint = dragTargetTint
		}
		if r := a.chrome.zoneRects[z]; r.Width > 0 && r.Height > 0 {
			canvas.Rounded(r.Inset(gfx.All(-dragZoneOutset)), dragZoneRadius, a.colors.Accent.WithAlpha(tint))
		}
	}
	if surface == surfaceStripes && d.phase == dragDetached && d.hasTarget {
		a.paintDetachedDropPreview(canvas, d.target)
	}
	if d.hasTarget {
		canvas.Rounded(d.target.mark, dragMark/2, a.colors.Accent)
	}

	if surface == surfaceStripes {
		if d.phase == dragDetached {
			a.paintDetachedToolGhost(canvas, d)
		} else {
			a.paintSnappedToolGhost(canvas, d)
		}
		return
	}
	a.paintLegacyDragGhost(canvas, d)
}

// paintSnappedToolGhost keeps the button over its stripe and preserves the press point
// inside the icon as the pointer moves vertically.
func (a *App) paintSnappedToolGhost(canvas *gfx.Canvas, d *dragState) {
	column := a.dragStripeColumn(d.snappedStripe)
	ghost := snappedToolGhostRect(
		gfx.Point{X: d.x, Y: d.y}, d.grab, column,
		gfx.Rect{Width: d.viewport.Width, Height: d.viewport.Height},
	)
	canvas.RoundedBorder(ghost, dragGhostRadius, dragGhostBorderWidth, a.colors.Accent, a.colors.Editor)
	if icon := a.chrome.catalog[d.item].icon; icon != nil {
		canvas.DrawIcon(*icon, ghost.Inset(gfx.All(dragSnappedGhostIconInset)), a.colors.Text)
	}
}

// dragStripeColumn returns a laid out button column for side, falling back to the stripe
// bounds before the first drag frame has given empty zones a rectangle.
func (a *App) dragStripeColumn(side stripeSide) gfx.Rect {
	for _, z := range stripeZones(side) {
		if column := a.chrome.zoneRects[z]; column.Width > 0 {
			return column
		}
	}
	return dragStripeRects(gfx.Rect{Width: a.drag.viewport.Width, Height: a.drag.viewport.Height})[side]
}

// paintDetachedToolGhost draws the detached icon in the previous client's rounded square
// with the original pointer-to-button grab offset and theme-specific surface color.
func (a *App) paintDetachedToolGhost(canvas *gfx.Canvas, d *dragState) {
	ghost := detachedToolGhostRect(gfx.Point{X: d.x, Y: d.y}, d.grab)
	color := gfx.RGB24(dragFloatingGhostLightRGB)
	if a.colors.Dark {
		color = gfx.RGB24(dragFloatingGhostDarkRGB)
	}
	color = color.WithAlpha(dragFloatingGhostOpacity)
	canvas.RoundedBorder(ghost, dragFloatingGhostRadius, dragFloatingGhostBorderWidth, color, color)
	if icon := a.chrome.catalog[d.item].icon; icon != nil {
		canvas.DrawIcon(*icon, ghost.Inset(gfx.All(dragFloatingGhostIconInset)), a.colors.Text.WithAlpha(dragFloatingGhostOpacity))
	}
}

// paintDetachedDropPreview highlights the pane a floating tool button would open in and
// labels it with the destination name from the typed language catalog.
func (a *App) paintDetachedDropPreview(canvas *gfx.Canvas, target dragTarget) {
	previewColor := gfx.RGB24(dragPreviewLightRGB)
	if a.colors.Dark {
		previewColor = gfx.RGB24(dragPreviewDarkRGB)
	}
	canvas.Fill(target.preview, previewColor.WithAlpha(dragPreviewAlpha))

	title := dockMoveTitle(a.text, target.zone)
	if title == "" {
		return
	}
	labelWidth := min(
		canvas.TextWidthWeight(title, dragPreviewLabelFontSize, gfx.WeightRegular)+2*dragPreviewLabelPadding,
		target.preview.Width,
	)
	labelHeight := min(
		float32(dragPreviewLabelFontSize+2*dragPreviewLabelPadding),
		target.preview.Height,
	)
	label := gfx.Rect{
		X:     target.preview.X + (target.preview.Width-labelWidth)/2,
		Y:     target.preview.Y + (target.preview.Height-labelHeight)/2,
		Width: labelWidth, Height: labelHeight,
	}
	canvas.Rounded(label, dragPreviewLabelRadius, a.colors.Editor)
	canvas.LabelCenter(title, label, gfx.TextStyle{
		Size: dragPreviewLabelFontSize, Weight: gfx.WeightRegular, Color: a.colors.Text,
	})
}

// paintLegacyDragGhost keeps title and status drags on their original below-right ghost,
// because those bars do not detach into the workbench.
func (a *App) paintLegacyDragGhost(canvas *gfx.Canvas, d *dragState) {
	icon := a.chrome.catalog[d.item].icon
	text := a.dragGhostText(d.item)
	ghost := gfx.Rect{X: d.x + dragGhostOffset, Y: d.y + dragGhostOffset, Width: dragGhostSize, Height: dragGhostSize}
	if text != "" {
		ghost.Width = max(dragGhostSize, a.chrome.rects[d.item].Width)
		ghost.Height = max(chromeStatusItem, a.chrome.rects[d.item].Height)
	}
	if d.viewport.Width > 0 {
		ghost.X = max(min(ghost.X, d.viewport.Width-ghost.Width-dragGhostMargin), 0)
		ghost.Y = max(min(ghost.Y, d.viewport.Height-ghost.Height-dragGhostMargin), 0)
	}
	canvas.RoundedBorder(ghost, dragGhostRadius, dragGhostBorderWidth, a.colors.Accent, a.colors.Editor)

	style := gfx.TextStyle{Size: a.theme.Metrics.FontSizeS, Weight: gfx.WeightRegular, Color: a.colors.Text}
	switch {
	case icon != nil && text == "":
		canvas.DrawIcon(*icon, ghost.Inset(gfx.All((dragGhostSize-chromeIconSize)/2)), a.colors.Text)
	case icon != nil:
		// An icon with words, as the run configuration has: the icon first and the words
		// after it, as in the button.
		canvas.DrawIcon(*icon, gfx.Rect{
			X:      ghost.X + chromeEdge,
			Y:      ghost.Y + (ghost.Height-chromeIconSize)/2,
			Width:  chromeIconSize,
			Height: chromeIconSize,
		}, a.colors.Subtle)
		canvas.Label(text, gfx.Rect{
			X:      ghost.X + chromeEdge + chromeIconSize + chromeGap,
			Y:      ghost.Y,
			Width:  ghost.Width - 2*chromeEdge - chromeIconSize - chromeGap,
			Height: ghost.Height,
		}, style)
	case text != "":
		canvas.LabelCenter(text, ghost, style)
	}
}

// dockMoveTitle returns the translated title shown over a detached drop preview.
func dockMoveTitle(messages *i18n.Messages, z zone) string {
	switch z {
	case zoneLeftTop:
		return messages.Dock.MoveLeftTop
	case zoneLeftBottom:
		return messages.Dock.MoveLeftBottom
	case zoneBottomLeft:
		return messages.Dock.MoveBottomLeft
	case zoneRightTop:
		return messages.Dock.MoveRightTop
	case zoneRightBottom:
		return messages.Dock.MoveRightBottom
	case zoneBottomRight:
		return messages.Dock.MoveBottomRight
	}
	return ""
}

// dragGhostText is the words the ghost of catalog item item shows beside or instead of
// its icon: the reading of a status item, or the name of the run configuration. The
// other buttons are icons only.
func (a *App) dragGhostText(item int) string {
	if a.chrome.catalog[item].id == itemRunConfig {
		return a.text.Title.CurrentFile
	}
	return a.chromeStatusText(item)
}
