package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	// pressed says the primary button went down on the button of catalog item item; active
	// says the pointer then moved far enough for the press to be a drag.
	pressed, active bool
	item            int
	// sourceZone stays fixed for the gesture so a detached drop keeps source-anchor
	// priority. snappedStripe can change when a detached drag returns to either stripe.
	sourceZone    zone
	snappedStripe stripeSide
	phase         dragPhase
	// startX and startY are where the press began and x and y where the pointer is now.
	startX, startY float32
	x, y           float32
	// grab is the press point inside the source button, retained by both stripe ghosts.
	grab ui.Point
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
	// preview is the dock pane rectangle highlighted while a tool button is detached.
	preview ui.Rect
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
			button := a.chrome.rects[i]
			source := a.chrome.zoneOf(i)
			side, _ := stripeForZone(source)
			*d = dragState{
				pressed: true, item: i, sourceZone: source, snappedStripe: side,
				startX: event.X, startY: event.Y,
				grab: ui.Point{X: event.X - button.X, Y: event.Y - button.Y},
			}
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
		point := ui.Point{X: event.X, Y: event.Y}
		if d.sourceZone.surface() == surfaceStripes {
			d.phase, d.snappedStripe = dragPhaseAt(d.phase, d.snappedStripe, point, dragStripeRects(ui.Rect{
				Width: event.Viewport.Width, Height: event.Viewport.Height,
			}))
		}
		d.target, d.hasTarget = a.dragLocate(d.item, d.sourceZone, point, event.Viewport, d.phase, d.snappedStripe)
		return ui.EventResult{Handled: true, Repaint: true}, true

	case ui.PointerUp:
		if !d.active {
			*d = dragState{}
			return ui.EventResult{}, false
		}
		// The place is worked out again at the release: the last move may be older than
		// the release by a frame in which the layout changed.
		item, source := d.item, d.sourceZone
		phase, snappedStripe := d.phase, d.snappedStripe
		point := ui.Point{X: event.X, Y: event.Y}
		if source.surface() == surfaceStripes {
			phase, snappedStripe = dragPhaseAt(phase, snappedStripe, point, dragStripeRects(ui.Rect{
				Width: event.Viewport.Width, Height: event.Viewport.Height,
			}))
		}
		target, ok := a.dragLocate(item, source, point, event.Viewport, phase, snappedStripe)
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
	return a.drag.active && a.drag.sourceZone.surface() == surfaceStripes
}

// dragLocate finds where dropping item at point would put it. Tool buttons use their
// snapped stripe or detached dock geometry; title and status items keep their existing
// bar-only targets. A point outside the window never produces a target.
func (a *App) dragLocate(item int, source zone, point ui.Point, viewport ui.Size, phase dragPhase, snapped stripeSide) (dragTarget, bool) {
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
			stripes := dragStripeRects(ui.Rect{Width: viewport.Width, Height: viewport.Height})
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
func (a *App) dragDetachedTarget(item int, source zone, point ui.Point, viewport ui.Size) (dragTarget, bool) {
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
func (a *App) dragInsertion(item int, z zone, x, y float32) (string, ui.Rect) {
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

// paintDrag paints the gesture above the frame: stripe zones stay tinted, detached dock
// targets show their pane preview and localized title, and the insertion line marks the
// position in the target zone. A snapped stripe ghost stays in its button column, while a
// detached ghost follows the pointer with its original grab point. The source button stays
// where it is, dimmed (see chromeBox).
func (a *App) paintDrag(canvas *ui.Canvas) {
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
			canvas.Rounded(r.Inset(ui.All(-dragZoneOutset)), dragZoneRadius, a.colors.Accent.WithAlpha(tint))
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
func (a *App) paintSnappedToolGhost(canvas *ui.Canvas, d *dragState) {
	column := a.dragStripeColumn(d.snappedStripe)
	ghost := snappedToolGhostRect(
		ui.Point{X: d.x, Y: d.y}, d.grab, column,
		ui.Rect{Width: d.viewport.Width, Height: d.viewport.Height},
	)
	canvas.RoundedBorder(ghost, dragGhostRadius, dragGhostBorderWidth, a.colors.Accent, a.colors.Editor)
	if icon := catalog[d.item].icon; icon != nil {
		canvas.DrawIcon(*icon, ghost.Inset(ui.All(dragSnappedGhostIconInset)), a.colors.Text)
	}
}

// dragStripeColumn returns a laid out button column for side, falling back to the stripe
// bounds before the first drag frame has given empty zones a rectangle.
func (a *App) dragStripeColumn(side stripeSide) ui.Rect {
	for _, z := range stripeZones(side) {
		if column := a.chrome.zoneRects[z]; column.Width > 0 {
			return column
		}
	}
	return dragStripeRects(ui.Rect{Width: a.drag.viewport.Width, Height: a.drag.viewport.Height})[side]
}

// paintDetachedToolGhost draws the detached icon in the previous client's rounded square
// with the original pointer-to-button grab offset and theme-specific surface color.
func (a *App) paintDetachedToolGhost(canvas *ui.Canvas, d *dragState) {
	ghost := detachedToolGhostRect(ui.Point{X: d.x, Y: d.y}, d.grab)
	color := ui.RGB24(dragFloatingGhostLightRGB)
	if a.colors.Dark {
		color = ui.RGB24(dragFloatingGhostDarkRGB)
	}
	color = color.WithAlpha(dragFloatingGhostOpacity)
	canvas.RoundedBorder(ghost, dragFloatingGhostRadius, dragFloatingGhostBorderWidth, color, color)
	if icon := catalog[d.item].icon; icon != nil {
		canvas.DrawIcon(*icon, ghost.Inset(ui.All(dragFloatingGhostIconInset)), a.colors.Text.WithAlpha(dragFloatingGhostOpacity))
	}
}

// paintDetachedDropPreview highlights the pane a floating tool button would open in and
// labels it with the destination name from the typed language catalog.
func (a *App) paintDetachedDropPreview(canvas *ui.Canvas, target dragTarget) {
	previewColor := ui.RGB24(dragPreviewLightRGB)
	if a.colors.Dark {
		previewColor = ui.RGB24(dragPreviewDarkRGB)
	}
	canvas.Fill(target.preview, previewColor.WithAlpha(dragPreviewAlpha))

	title := dockMoveTitle(a.text, target.zone)
	if title == "" {
		return
	}
	labelWidth := min(
		canvas.TextWidthWeight(title, dragPreviewLabelFontSize, ui.WeightRegular)+2*dragPreviewLabelPadding,
		target.preview.Width,
	)
	labelHeight := min(
		float32(dragPreviewLabelFontSize+2*dragPreviewLabelPadding),
		target.preview.Height,
	)
	label := ui.Rect{
		X:     target.preview.X + (target.preview.Width-labelWidth)/2,
		Y:     target.preview.Y + (target.preview.Height-labelHeight)/2,
		Width: labelWidth, Height: labelHeight,
	}
	canvas.Rounded(label, dragPreviewLabelRadius, a.colors.Editor)
	canvas.LabelCenter(title, label, ui.TextStyle{
		Size: dragPreviewLabelFontSize, Weight: ui.WeightRegular, Color: a.colors.Text,
	})
}

// paintLegacyDragGhost keeps title and status drags on their original below-right ghost,
// because those bars do not detach into the workbench.
func (a *App) paintLegacyDragGhost(canvas *ui.Canvas, d *dragState) {
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
	canvas.RoundedBorder(ghost, dragGhostRadius, dragGhostBorderWidth, a.colors.Accent, a.colors.Editor)

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
	if catalog[item].id == itemRunConfig {
		return a.text.Title.CurrentFile
	}
	return a.chromeStatusText(item)
}
