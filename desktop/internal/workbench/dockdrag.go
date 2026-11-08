package workbench

import "github.com/vivaui/viva/ui"

const (
	// dragDetachDistance is how far a snapped pointer must pass the stripe's inner edge
	// before its tool button becomes a floating image.
	dragDetachDistance = 32
	// dragResnapPadding extends the stripe's outer edge into the workbench by this many
	// pixels, leaving a stable band between the detach and re-snap boundaries.
	dragResnapPadding = 8
	// dragFallbackBottomMinimum is the least height of the virtual bottom dock area when
	// no bottom height has been remembered yet.
	dragFallbackBottomMinimum = 200
	// dragFallbackBottomFraction is the part of the workspace height used for a virtual
	// bottom dock area when no bottom height has been remembered yet.
	dragFallbackBottomFraction = 0.25
)

// dragPhase is whether a stripe button stays attached to a stripe or floats with the
// pointer over the workbench.
type dragPhase uint8

const (
	// dragSnapped keeps the dragged button in its current stripe's button column.
	dragSnapped dragPhase = iota
	// dragDetached lets the button target dock panes across the workbench.
	dragDetached
)

// stripeSide identifies which of the two tool button columns holds a snapped drag.
type stripeSide uint8

const (
	stripeLeft stripeSide = iota
	stripeRight
)

// dragStripeRects returns the window's left and right stripe bounds. Their vertical
// extent excludes the title and status bars, which cannot receive tool button drops.
func dragStripeRects(viewport ui.Rect) [2]ui.Rect {
	height := max(viewport.Height-titleBarHeight-statusBarHeight, 0)
	return [2]ui.Rect{
		{X: viewport.X, Y: viewport.Y + titleBarHeight, Width: stripeWidth, Height: height},
		{X: viewport.X + viewport.Width - stripeWidth, Y: viewport.Y + titleBarHeight, Width: stripeWidth, Height: height},
	}
}

// stripeForZone identifies the side whose activity stripe contains a zone.
func stripeForZone(z zone) (stripeSide, bool) {
	switch z {
	case zoneLeftTop, zoneLeftBottom, zoneBottomLeft:
		return stripeLeft, true
	case zoneRightTop, zoneRightBottom, zoneBottomRight:
		return stripeRight, true
	}
	return 0, false
}

// stripeZones returns the top, split and bottom groups in their visual order.
func stripeZones(side stripeSide) [3]zone {
	if side == stripeRight {
		return [3]zone{zoneRightTop, zoneRightBottom, zoneBottomRight}
	}
	return [3]zone{zoneLeftTop, zoneLeftBottom, zoneBottomLeft}
}

// dragPhaseAt applies the detach and re-snap boundaries to a pointer position. The
// different boundaries leave a band where the current phase is retained, and a pointer
// event that crosses the whole workbench can detach and re-snap on the other stripe in one
// step.
func dragPhaseAt(phase dragPhase, snapped stripeSide, point ui.Point, stripes [2]ui.Rect) (dragPhase, stripeSide) {
	left, right := stripes[stripeLeft], stripes[stripeRight]
	if phase == dragSnapped {
		crossedInnerEdge := false
		switch snapped {
		case stripeLeft:
			crossedInnerEdge = point.X > left.X+left.Width+dragDetachDistance
		case stripeRight:
			crossedInnerEdge = point.X < right.X-dragDetachDistance
		}
		if !crossedInnerEdge {
			return dragSnapped, snapped
		}
		phase = dragDetached
	}

	nearLeft := point.X <= left.X+left.Width+dragResnapPadding
	nearRight := point.X >= right.X-dragResnapPadding
	switch {
	case nearLeft && nearRight:
		leftCenter := left.X + left.Width/2
		rightCenter := right.X + right.Width/2
		if absFloat32(point.X-rightCenter) < absFloat32(point.X-leftCenter) {
			return dragSnapped, stripeRight
		}
		return dragSnapped, stripeLeft
	case nearLeft:
		return dragSnapped, stripeLeft
	case nearRight:
		return dragSnapped, stripeRight
	default:
		return dragDetached, snapped
	}
}

// dragStripeZoneAt chooses a snapped target from the midpoints of the free gaps. The
// pointer may be just inside the editor while still snapped, so the stripe rectangle
// supplies its valid vertical range and the three zone rectangles supply only the gaps.
func dragStripeZoneAt(point ui.Point, stripe ui.Rect, side stripeSide, top, split, bottom ui.Rect) (zone, bool) {
	if point.Y < stripe.Y || point.Y >= stripe.Y+stripe.Height {
		return 0, false
	}
	if top.Height <= 0 && split.Height <= 0 && bottom.Height <= 0 {
		first := stripe.Y + stripe.Height/3
		second := stripe.Y + 2*stripe.Height/3
		zones := stripeZones(side)
		switch {
		case point.Y < first:
			return zones[0], true
		case point.Y < second:
			return zones[1], true
		default:
			return zones[2], true
		}
	}

	zones := stripeZones(side)
	topLimit := (top.Y + top.Height + split.Y) / 2
	splitLimit := (split.Y + split.Height + bottom.Y) / 2
	switch {
	case point.Y < topLimit:
		return zones[0], true
	case point.Y < splitLimit:
		return zones[1], true
	default:
		return zones[2], true
	}
}

// snappedToolGhostRect keeps the ghost centered in its stripe and preserves the press
// offset vertically, clamping it between the title and status bars.
func snappedToolGhostRect(point, grab ui.Point, stripe, viewport ui.Rect) ui.Rect {
	top := viewport.Y + titleBarHeight
	lastTop := viewport.Y + viewport.Height - statusBarHeight - dragSnappedGhostSize
	if lastTop < top {
		lastTop = top
	}
	return ui.Rect{
		X:      stripe.X + (stripe.Width-dragSnappedGhostSize)/2,
		Y:      min(max(point.Y-grab.Y, top), lastTop),
		Width:  dragSnappedGhostSize,
		Height: dragSnappedGhostSize,
	}
}

// detachedToolGhostRect follows the pointer while preserving where the user grabbed the
// source button.
func detachedToolGhostRect(point, grab ui.Point) ui.Rect {
	return ui.Rect{
		X:      point.X - grab.X,
		Y:      point.Y - grab.Y,
		Width:  dragFloatingGhostSize,
		Height: dragFloatingGhostSize,
	}
}

// dockAnchorID is one of the three tool window anchors reached from the stripes.
type dockAnchorID uint8

const (
	dockAnchorLeft dockAnchorID = iota
	dockAnchorBottom
	dockAnchorRight
	dockAnchorCount
)

// dragDockAnchor holds the actual or remembered area for one anchor, plus its panes when
// both groups are open. Side anchors split vertically; the bottom anchor splits across.
type dragDockAnchor struct {
	area, hitArea         ui.Rect
	first, second         zone
	firstPane, secondPane ui.Rect
	horizontal, split     bool
}

// previewFor returns the pane or half-area used to preview a drop in z.
func (a dragDockAnchor) previewFor(z zone) (ui.Rect, bool) {
	switch z {
	case a.first:
		if a.split {
			return a.firstPane, a.firstPane.Width > 0 && a.firstPane.Height > 0
		}
		first, _ := dockAreaHalves(a.area, a.horizontal)
		return first, first.Width > 0 && first.Height > 0
	case a.second:
		if a.split {
			return a.secondPane, a.secondPane.Width > 0 && a.secondPane.Height > 0
		}
		_, second := dockAreaHalves(a.area, a.horizontal)
		return second, second.Width > 0 && second.Height > 0
	}
	return ui.Rect{}, false
}

// targetAt chooses the group under point when it lies inside this anchor's dock area.
func (a dragDockAnchor) targetAt(point ui.Point) (zone, ui.Rect, bool) {
	if !rectContainsPoint(a.hitArea, point) {
		return 0, ui.Rect{}, false
	}
	if a.split {
		if a.horizontal {
			if point.X < a.secondPane.X {
				preview, ok := a.previewFor(a.first)
				return a.first, preview, ok
			}
			preview, ok := a.previewFor(a.second)
			return a.second, preview, ok
		}
		if point.Y < a.secondPane.Y {
			preview, ok := a.previewFor(a.first)
			return a.first, preview, ok
		}
		preview, ok := a.previewFor(a.second)
		return a.second, preview, ok
	}

	middle := a.area.Y + a.area.Height/2
	if a.horizontal {
		middle = a.area.X + a.area.Width/2
		if point.X < middle {
			preview, ok := a.previewFor(a.first)
			return a.first, preview, ok
		}
	} else if point.Y < middle {
		preview, ok := a.previewFor(a.first)
		return a.first, preview, ok
	}
	preview, ok := a.previewFor(a.second)
	return a.second, preview, ok
}

// dockAreaHalves divides an unsplit anchor into the two zones it can receive.
func dockAreaHalves(area ui.Rect, horizontal bool) (ui.Rect, ui.Rect) {
	first, second := area, area
	if horizontal {
		first.Width = area.Width / 2
		second.X = area.X + first.Width
		second.Width = area.Width - first.Width
		return first, second
	}
	first.Height = area.Height / 2
	second.Y = area.Y + first.Height
	second.Height = area.Height - first.Height
	return first, second
}

// dragDockButton is a visible stripe button that can take priority over a dock-area hit.
type dragDockButton struct {
	item int
	zone zone
	rect ui.Rect
}

// dragDockTargetAt gives a visible stripe button priority, then checks dock areas in
// source-anchor-first order. Its inputs are only geometry and a point, so release targets
// can be tested without clocks, animation or a running application.
func dragDockTargetAt(point ui.Point, sourceItem int, sourceZone zone, buttons []dragDockButton, anchors [dockAnchorCount]dragDockAnchor) (zone, ui.Rect, bool) {
	for _, button := range buttons {
		if button.item == sourceItem || !rectContainsPoint(button.rect, point) {
			continue
		}
		anchor, ok := dockAnchorForZone(button.zone)
		if !ok {
			continue
		}
		preview, ok := anchors[anchor].previewFor(button.zone)
		if ok {
			return button.zone, preview, true
		}
	}
	for _, anchor := range dockAnchorOrder(sourceZone) {
		if z, preview, ok := anchors[anchor].targetAt(point); ok {
			return z, preview, true
		}
	}
	return 0, ui.Rect{}, false
}

// dockAnchorForZone maps a stripe zone to the tool window anchor it opens.
func dockAnchorForZone(z zone) (dockAnchorID, bool) {
	switch z {
	case zoneLeftTop, zoneLeftBottom:
		return dockAnchorLeft, true
	case zoneBottomLeft, zoneBottomRight:
		return dockAnchorBottom, true
	case zoneRightTop, zoneRightBottom:
		return dockAnchorRight, true
	}
	return 0, false
}

// dockAnchorOrder puts the source anchor first and follows it with the other anchors in
// left, bottom, right order when their hit areas overlap.
func dockAnchorOrder(source zone) [dockAnchorCount]dockAnchorID {
	preferred, ok := dockAnchorForZone(source)
	if !ok {
		preferred = dockAnchorLeft
	}
	canonical := [dockAnchorCount]dockAnchorID{dockAnchorLeft, dockAnchorBottom, dockAnchorRight}
	var order [dockAnchorCount]dockAnchorID
	order[0] = preferred
	next := 1
	for _, anchor := range canonical {
		if anchor != preferred {
			order[next] = anchor
			next++
		}
	}
	return order
}

// dragDockAnchors builds the open or remembered pane rectangles used by detached drags.
func (a *App) dragDockAnchors(viewport ui.Size) [dockAnchorCount]dragDockAnchor {
	main := a.layout.main.Rect()
	plan := a.layout.frame
	if main.Width <= 0 || main.Height <= 0 {
		main = ui.Rect{
			X:      stripeWidth,
			Y:      titleBarHeight,
			Width:  max(viewport.Width-2*stripeWidth, 0),
			Height: max(viewport.Height-titleBarHeight-statusBarHeight, 0),
		}
		plan.width, plan.height, plan.topH = main.Width, main.Height, main.Height
	}
	workspaceWidth := min(max(plan.width, 0), main.Width)
	workspaceHeight := min(max(plan.height, 0), main.Height)
	if workspaceWidth <= 0 {
		workspaceWidth = main.Width
	}
	if workspaceHeight <= 0 {
		workspaceHeight = main.Height
	}
	topHeight := min(max(plan.topH, 0), workspaceHeight)
	if topHeight <= 0 && plan.bottomH <= 0 {
		topHeight = workspaceHeight
	}

	leftWidth := a.layout.left
	if plan.left() {
		leftWidth = plan.leftW
	}
	leftWidth = min(max(leftWidth, 0), workspaceWidth)
	leftArea := ui.Rect{X: main.X, Y: main.Y, Width: leftWidth, Height: topHeight}
	leftHit := leftArea
	leftHit.X -= stripeWidth
	leftHit.Width += stripeWidth
	leftAnchor := dragDockAnchor{
		area: leftArea, hitArea: leftHit,
		first: zoneLeftTop, second: zoneLeftBottom,
	}
	if plan.leftSplit() {
		leftAnchor.split = true
		leftAnchor.firstPane = ui.Rect{X: leftArea.X, Y: leftArea.Y, Width: leftArea.Width, Height: plan.leftUpperH}
		leftAnchor.secondPane = ui.Rect{
			X: leftArea.X, Y: leftArea.Y + plan.leftUpperH + shellSplitter,
			Width: leftArea.Width, Height: plan.leftLowerH,
		}
	}

	rightWidth := a.layout.right
	if plan.right() {
		rightWidth = plan.rightW
	}
	rightWidth = min(max(rightWidth, 0), workspaceWidth)
	rightArea := ui.Rect{
		X: main.X + workspaceWidth - rightWidth, Y: main.Y,
		Width: rightWidth, Height: topHeight,
	}
	rightHit := rightArea
	rightHit.Width += stripeWidth
	rightAnchor := dragDockAnchor{
		area: rightArea, hitArea: rightHit,
		first: zoneRightTop, second: zoneRightBottom,
	}
	if plan.rightSplit() {
		rightAnchor.split = true
		rightAnchor.firstPane = ui.Rect{X: rightArea.X, Y: rightArea.Y, Width: rightArea.Width, Height: plan.rightUpperH}
		rightAnchor.secondPane = ui.Rect{
			X: rightArea.X, Y: rightArea.Y + plan.rightUpperH + shellSplitter,
			Width: rightArea.Width, Height: plan.rightLowerH,
		}
	}

	bottomHeight := a.layout.bottom
	if plan.bottom() {
		bottomHeight = plan.bottomH
	} else if bottomHeight <= 0 {
		bottomHeight = max(dragFallbackBottomMinimum, main.Height*dragFallbackBottomFraction)
	}
	bottomHeight = min(max(bottomHeight, 0), workspaceHeight)
	bottomArea := ui.Rect{
		X: main.X, Y: main.Y + workspaceHeight - bottomHeight,
		Width: workspaceWidth, Height: bottomHeight,
	}
	bottomAnchor := dragDockAnchor{
		area: bottomArea, hitArea: bottomArea,
		first: zoneBottomLeft, second: zoneBottomRight, horizontal: true,
	}
	if plan.bottomLeft && plan.bottomRight {
		bottomAnchor.split = true
		bottomAnchor.firstPane = ui.Rect{
			X: bottomArea.X, Y: bottomArea.Y, Width: plan.bottomLeftW, Height: bottomArea.Height,
		}
		secondX := bottomArea.X + plan.bottomLeftW + shellSplitter
		bottomAnchor.secondPane = ui.Rect{
			X: secondX, Y: bottomArea.Y,
			Width: max(bottomArea.X+bottomArea.Width-secondX, 0), Height: bottomArea.Height,
		}
	}

	return [dockAnchorCount]dragDockAnchor{leftAnchor, bottomAnchor, rightAnchor}
}

// dragDockButtons returns the visible stripe button rectangles except the source button.
func (a *App) dragDockButtons(sourceItem int) []dragDockButton {
	var buttons []dragDockButton
	for z := zoneLeftTop; z <= zoneBottomRight; z++ {
		for _, item := range a.chrome.items[z] {
			if item == sourceItem {
				continue
			}
			r := a.chrome.rects[item]
			if r.Width > 0 && r.Height > 0 {
				buttons = append(buttons, dragDockButton{item: item, zone: z, rect: r})
			}
		}
	}
	return buttons
}

// rectContainsPoint uses half-open bounds so adjacent panes never both own their shared
// edge.
func rectContainsPoint(rect ui.Rect, point ui.Point) bool {
	return rect.Width > 0 && rect.Height > 0 &&
		point.X >= rect.X && point.X < rect.X+rect.Width &&
		point.Y >= rect.Y && point.Y < rect.Y+rect.Height
}

// absFloat32 measures which stripe is nearer when both re-snap regions overlap.
func absFloat32(value float32) float32 {
	if value < 0 {
		return -value
	}
	return value
}
