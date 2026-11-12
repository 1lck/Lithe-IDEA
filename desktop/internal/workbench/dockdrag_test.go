package workbench

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestDragPhaseAtUsesDetachAndResnapHysteresis(t *testing.T) {
	stripes := dragStripeRects(gfx.Rect{Width: 1000, Height: 700})
	leftInner := stripes[stripeLeft].X + stripes[stripeLeft].Width
	rightInner := stripes[stripeRight].X
	point := func(x float32) gfx.Point { return gfx.Point{X: x, Y: stripes[stripeLeft].Y} }
	tests := []struct {
		name       string
		phase      dragPhase
		snapped    stripeSide
		x          float32
		wantPhase  dragPhase
		wantStripe stripeSide
	}{
		{name: "left detach edge stays snapped", phase: dragSnapped, snapped: stripeLeft, x: leftInner + dragDetachDistance, wantPhase: dragSnapped, wantStripe: stripeLeft},
		{name: "left detaches past edge", phase: dragSnapped, snapped: stripeLeft, x: leftInner + dragDetachDistance + 1, wantPhase: dragDetached, wantStripe: stripeLeft},
		{name: "right detach edge stays snapped", phase: dragSnapped, snapped: stripeRight, x: rightInner - dragDetachDistance, wantPhase: dragSnapped, wantStripe: stripeRight},
		{name: "right detaches past edge", phase: dragSnapped, snapped: stripeRight, x: rightInner - dragDetachDistance - 1, wantPhase: dragDetached, wantStripe: stripeRight},
		{name: "snapped phase holds in hysteresis band", phase: dragSnapped, snapped: stripeRight, x: rightInner - dragDetachDistance/2, wantPhase: dragSnapped, wantStripe: stripeRight},
		{name: "detached phase holds in hysteresis band", phase: dragDetached, snapped: stripeRight, x: rightInner - dragDetachDistance/2, wantPhase: dragDetached, wantStripe: stripeRight},
		{name: "detached phase waits outside resnap edge", phase: dragDetached, snapped: stripeRight, x: rightInner - dragResnapPadding - 1, wantPhase: dragDetached, wantStripe: stripeRight},
		{name: "detached phase resnaps at right edge", phase: dragDetached, snapped: stripeRight, x: rightInner - dragResnapPadding, wantPhase: dragSnapped, wantStripe: stripeRight},
		{name: "detached phase resnaps at left edge", phase: dragDetached, snapped: stripeRight, x: leftInner + dragResnapPadding, wantPhase: dragSnapped, wantStripe: stripeLeft},
		{name: "crossing from right snaps to left in one event", phase: dragSnapped, snapped: stripeRight, x: leftInner + dragResnapPadding, wantPhase: dragSnapped, wantStripe: stripeLeft},
		{name: "crossing from left snaps to right in one event", phase: dragSnapped, snapped: stripeLeft, x: rightInner - dragResnapPadding, wantPhase: dragSnapped, wantStripe: stripeRight},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotPhase, gotStripe := dragPhaseAt(tc.phase, tc.snapped, point(tc.x), stripes)
			if gotPhase != tc.wantPhase || gotStripe != tc.wantStripe {
				t.Fatalf("dragPhaseAt(%v, %v, x=%v) = (%v, %v), want (%v, %v)",
					tc.phase, tc.snapped, tc.x, gotPhase, gotStripe, tc.wantPhase, tc.wantStripe)
			}
		})
	}
}

func TestDragStripeZoneAtUsesMidpointsOfFreeGaps(t *testing.T) {
	stripe := gfx.Rect{Y: titleBarHeight, Height: 600}
	top := gfx.Rect{Y: stripe.Y, Height: chromeToolButton}
	split := gfx.Rect{Y: stripe.Y + 400, Height: chromeToolButton}
	bottom := gfx.Rect{Y: split.Y + split.Height, Height: chromeToolButton}
	topLimit := (top.Y + top.Height + split.Y) / 2
	splitLimit := (split.Y + split.Height + bottom.Y) / 2
	tests := []struct {
		name string
		y    float32
		want zone
	}{
		{name: "before top gap midpoint", y: topLimit - 1, want: zoneRightTop},
		{name: "at top gap midpoint", y: topLimit, want: zoneRightBottom},
		{name: "before split and bottom midpoint", y: splitLimit - 1, want: zoneRightBottom},
		{name: "at split and bottom midpoint", y: splitLimit, want: zoneBottomRight},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := dragStripeZoneAt(gfx.Point{Y: tc.y}, stripe, stripeRight, top, split, bottom)
			if !ok || got != tc.want {
				t.Fatalf("dragStripeZoneAt(y=%v) = (%v, %v), want (%v, true)", tc.y, got, ok, tc.want)
			}
		})
	}
	for _, y := range []float32{stripe.Y - 1, stripe.Y + stripe.Height} {
		if got, ok := dragStripeZoneAt(gfx.Point{Y: y}, stripe, stripeRight, top, split, bottom); ok {
			t.Errorf("dragStripeZoneAt(y=%v) = (%v, true), want no zone outside the stripe", y, got)
		}
	}
}

func TestDragStripeZoneAtDividesUnlaidZonesInVisualOrder(t *testing.T) {
	stripe := gfx.Rect{Y: 40, Height: 300}
	firstLimit := stripe.Y + stripe.Height/3
	secondLimit := stripe.Y + 2*stripe.Height/3
	tests := []struct {
		y    float32
		want zone
	}{
		{y: firstLimit - 1, want: zoneLeftTop},
		{y: firstLimit, want: zoneLeftBottom},
		{y: secondLimit - 1, want: zoneLeftBottom},
		{y: secondLimit, want: zoneBottomLeft},
	}
	for _, tc := range tests {
		got, ok := dragStripeZoneAt(gfx.Point{Y: tc.y}, stripe, stripeLeft, gfx.Rect{}, gfx.Rect{}, gfx.Rect{})
		if !ok || got != tc.want {
			t.Errorf("dragStripeZoneAt(y=%v) = (%v, %v), want (%v, true)", tc.y, got, ok, tc.want)
		}
	}
}

func TestToolGhostRectsKeepTheGrabOffsetAndClampTheSnappedGhost(t *testing.T) {
	viewport := gfx.Rect{Height: 600}
	stripe := gfx.Rect{X: 100, Width: stripeWidth}
	grab := gfx.Point{X: 7, Y: 9}

	got := snappedToolGhostRect(gfx.Point{Y: 250}, grab, stripe, viewport)
	want := gfx.Rect{
		X: stripe.X + (stripe.Width-dragSnappedGhostSize)/2,
		Y: 250 - grab.Y, Width: dragSnappedGhostSize, Height: dragSnappedGhostSize,
	}
	if got != want {
		t.Fatalf("snapped ghost = %+v, want %+v with the press offset retained", got, want)
	}
	if got := snappedToolGhostRect(gfx.Point{}, grab, stripe, viewport); got.Y != titleBarHeight {
		t.Errorf("snapped ghost top = %v, want title bar edge %v", got.Y, float32(titleBarHeight))
	}
	wantBottom := viewport.Height - statusBarHeight - dragSnappedGhostSize
	if got := snappedToolGhostRect(gfx.Point{Y: viewport.Height}, grab, stripe, viewport); got.Y != wantBottom {
		t.Errorf("snapped ghost bottom = %v, want top edge %v before the status bar", got.Y, wantBottom)
	}

	got = detachedToolGhostRect(gfx.Point{X: 400, Y: 250}, grab)
	want = gfx.Rect{X: 400 - grab.X, Y: 250 - grab.Y, Width: dragFloatingGhostSize, Height: dragFloatingGhostSize}
	if got != want {
		t.Fatalf("detached ghost = %+v, want %+v with the press offset retained", got, want)
	}
}

func TestDragDockTargetAtChoosesDockGroupsAndPreviewFrames(t *testing.T) {
	leftArea := gfx.Rect{X: stripeWidth, Y: 40, Width: 200, Height: 400}
	bottomArea := gfx.Rect{X: stripeWidth, Y: 440, Width: 920, Height: 200}
	rightArea := gfx.Rect{X: 760, Y: 40, Width: 200, Height: 400}
	anchors := [dockAnchorCount]dragDockAnchor{
		dockAnchorLeft: {
			area: leftArea, hitArea: gfx.Rect{X: 0, Y: leftArea.Y, Width: leftArea.Width + stripeWidth, Height: leftArea.Height},
			first: zoneLeftTop, second: zoneLeftBottom,
		},
		dockAnchorBottom: {
			area: bottomArea, hitArea: bottomArea,
			first: zoneBottomLeft, second: zoneBottomRight, horizontal: true,
		},
		dockAnchorRight: {
			area: rightArea, hitArea: gfx.Rect{X: rightArea.X, Y: rightArea.Y, Width: rightArea.Width + stripeWidth, Height: rightArea.Height},
			first: zoneRightTop, second: zoneRightBottom,
		},
	}
	tests := []struct {
		name        string
		point       gfx.Point
		source      zone
		wantZone    zone
		wantPreview gfx.Rect
	}{
		{name: "right upper half", point: gfx.Point{X: 800, Y: 100}, source: zoneLeftTop, wantZone: zoneRightTop, wantPreview: gfx.Rect{X: rightArea.X, Y: rightArea.Y, Width: rightArea.Width, Height: rightArea.Height / 2}},
		{name: "right lower half", point: gfx.Point{X: 800, Y: 300}, source: zoneLeftTop, wantZone: zoneRightBottom, wantPreview: gfx.Rect{X: rightArea.X, Y: rightArea.Y + rightArea.Height/2, Width: rightArea.Width, Height: rightArea.Height - rightArea.Height/2}},
		{name: "left area extends over its stripe", point: gfx.Point{X: 20, Y: 100}, source: zoneRightTop, wantZone: zoneLeftTop, wantPreview: gfx.Rect{X: leftArea.X, Y: leftArea.Y, Width: leftArea.Width, Height: leftArea.Height / 2}},
		{name: "bottom right half", point: gfx.Point{X: 800, Y: 500}, source: zoneRightTop, wantZone: zoneBottomRight, wantPreview: gfx.Rect{X: bottomArea.X + bottomArea.Width/2, Y: bottomArea.Y, Width: bottomArea.Width - bottomArea.Width/2, Height: bottomArea.Height}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotZone, gotPreview, ok := dragDockTargetAt(tc.point, -1, tc.source, nil, anchors)
			if !ok || gotZone != tc.wantZone || gotPreview != tc.wantPreview {
				t.Fatalf("dragDockTargetAt(%+v) = (%v, %+v, %v), want (%v, %+v, true)",
					tc.point, gotZone, gotPreview, ok, tc.wantZone, tc.wantPreview)
			}
		})
	}

	if got := dockAnchorOrder(zoneRightBottom); got != [dockAnchorCount]dockAnchorID{dockAnchorRight, dockAnchorLeft, dockAnchorBottom} {
		t.Errorf("dockAnchorOrder(right) = %v, want source anchor followed by left and bottom", got)
	}
}

func TestDragDockTargetAtUsesActualSplitPaneAndVisibleButtonPriority(t *testing.T) {
	area := gfx.Rect{X: 760, Y: 40, Width: 200, Height: 400}
	upper := gfx.Rect{X: area.X, Y: area.Y, Width: area.Width, Height: 180}
	lower := gfx.Rect{X: area.X, Y: area.Y + upper.Height + shellSplitter, Width: area.Width, Height: area.Height - upper.Height - shellSplitter}
	anchors := [dockAnchorCount]dragDockAnchor{
		dockAnchorRight: {
			area: area, hitArea: gfx.Rect{X: area.X, Y: area.Y, Width: area.Width + stripeWidth, Height: area.Height},
			first: zoneRightTop, second: zoneRightBottom, firstPane: upper, secondPane: lower, split: true,
		},
	}
	point := gfx.Point{X: area.X + area.Width/2, Y: area.Y + chromeToolButton}

	gotZone, gotPreview, ok := dragDockTargetAt(point, -1, zoneLeftTop, nil, anchors)
	if !ok || gotZone != zoneRightTop || gotPreview != upper {
		t.Fatalf("split upper target = (%v, %+v, %v), want right top and the actual upper pane %+v", gotZone, gotPreview, ok, upper)
	}

	buttons := []dragDockButton{
		{item: 7, zone: zoneLeftTop, rect: gfx.Rect{X: point.X - 2, Y: point.Y - 2, Width: 4, Height: 4}},
		{item: 8, zone: zoneRightBottom, rect: gfx.Rect{X: point.X - 2, Y: point.Y - 2, Width: 4, Height: 4}},
	}
	gotZone, gotPreview, ok = dragDockTargetAt(point, 7, zoneLeftTop, buttons, anchors)
	if !ok || gotZone != zoneRightBottom || gotPreview != lower {
		t.Fatalf("button-priority target = (%v, %+v, %v), want right bottom and the actual lower pane %+v", gotZone, gotPreview, ok, lower)
	}
}

func TestDragDockTargetAtReturnsNoTargetOutsideDockAreas(t *testing.T) {
	point := gfx.Point{X: 500, Y: 300}
	if gotZone, gotPreview, ok := dragDockTargetAt(point, -1, zoneRightTop, nil, [dockAnchorCount]dragDockAnchor{}); ok {
		t.Fatalf("dragDockTargetAt(%+v) = (%v, %+v, true), want no target", point, gotZone, gotPreview)
	}
}
