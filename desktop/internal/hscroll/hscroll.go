// Package hscroll scrolls content sideways inside a box that is narrower than it. Viva's
// scroll areas only scroll up and down, so a list whose names must not be cut short, or a
// strip of tabs that do not fit, lays its content out at its full width, moves it left by
// State.Offset with a negative margin and clips it to the box that shows it.
//
// The content's width and the box are only known once a frame is laid out, so the caller
// hands them to Fit after layout and asks for another frame when Fit reports a change: the
// next frame lays the content out at the corrected offset. A State touches no Viva box, so
// the tests run it without a window.
package hscroll

import "github.com/vivaui/viva/gfx"

// Thickness is how thick the thumb of a sideways scrollbar is, and MinThumb the least
// length it keeps however wide the content is, so it can still be seen.
const (
	Thickness = 6
	MinThumb  = 24
)

// State is one sideways scroll.
type State struct {
	// Offset is how far the content is moved left, from 0 to Max.
	Offset float32
	// Content is the content's width and Area where the box that shows it was, as the last
	// frame measured them. A wheel event is checked against Area.
	Content float32
	Area    gfx.Rect
}

// Viewport is the width of the box that shows the content.
func (s *State) Viewport() float32 { return s.Area.Width }

// Max is the furthest the content can be moved left: none while it fits its box.
func (s *State) Max() float32 { return max(s.Content-s.Area.Width, 0) }

// Overflows says the content is wider than its box, so there is something to scroll to.
// Half a point is allowed for the rounding of the layout.
func (s *State) Overflows() bool { return s.Area.Width > 0 && s.Content > s.Area.Width+0.5 }

// Fit records what a frame measured, the box that shows the content and the content's
// width, and keeps Offset in range for them. It reports whether the offset, the content's
// width or the box's width changed, what the frame laid the content and the thumb out with,
// in which case the caller asks for another frame. Where the box is does not count: both
// are laid out against it wherever it is, so a box that only moves, as when a splitter is
// dragged, costs no extra frame.
func (s *State) Fit(area gfx.Rect, content float32) bool {
	offset, viewport, width := s.Offset, s.Area.Width, s.Content
	s.Area, s.Content = area, content
	s.Offset = clamp(s.Offset, 0, s.Max())
	return s.Offset != offset || s.Area.Width != viewport || s.Content != width
}

// Reveal scrolls the least that shows the content from left to right, measured from the
// content's left edge. A span wider than the box shows its left end. It reports whether the
// offset changed. Before the box has been measured it does nothing.
func (s *State) Reveal(left, right float32) bool {
	width := s.Area.Width
	if width <= 0 {
		return false
	}
	before := s.Offset
	switch {
	case left < s.Offset || right-left > width:
		s.Offset = left
	case right > s.Offset+width:
		s.Offset = right - width
	}
	s.Offset = clamp(s.Offset, 0, s.Max())
	return s.Offset != before
}

// Thumb is the thumb of the scrollbar that shows how much of the content the box shows and
// where: how far its left edge is from the box's left edge, and its length. The caller
// declares it as an absolute child of the box, so it is painted over the content and under
// any popup. ok is false while the content fits its box, when there is no scrollbar.
func (s *State) Thumb() (left, length float32, ok bool) {
	if !s.Overflows() {
		return 0, 0, false
	}
	viewport := s.Area.Width
	length = min(max(viewport*viewport/s.Content, MinThumb), viewport)
	left = (viewport - length) * (s.Offset / s.Max())
	return left, length, true
}

// Grab starts a drag of the thumb by a press at window x. A press on the thumb keeps the
// point of the thumb it took; a press on the bar beside the thumb takes the thumb by its
// middle and moves it there at once, so the content jumps to that place. It returns the
// point of the thumb that was taken, measured from the thumb's left edge, for DragTo, and
// whether the offset changed. ok is false while there is no thumb.
func (s *State) Grab(x float32) (grab float32, changed, ok bool) {
	left, length, ok := s.Thumb()
	if !ok {
		return 0, false, false
	}
	at := x - s.Area.X
	if at >= left && at <= left+length {
		return at - left, false, true
	}
	grab = length / 2
	return grab, s.DragTo(x, grab), true
}

// DragTo moves the thumb so that its point grab, as Grab returned it, is at window x, and
// scrolls the content to match. It reports whether the offset changed.
func (s *State) DragTo(x, grab float32) bool {
	_, length, ok := s.Thumb()
	if !ok {
		return false
	}
	track := s.Area.Width - length
	if track <= 0 {
		return false
	}
	before := s.Offset
	s.Offset = clamp((x-s.Area.X-grab)/track*s.Max(), 0, s.Max())
	return s.Offset != before
}

// Wheel scrolls by a wheel event over Area: a sideways swipe, or the wheel with Shift held.
// When vertical is set, as on a strip of tabs, which has nothing to scroll up and down, a
// plain turn of the wheel scrolls sideways as well. A wheel that turns in steps rather than
// points moves at least step. The second result says whether the event was the scroll's;
// an up and down swipe it does not take is left to whatever scrolls up and down.
func (s *State) Wheel(event gfx.ScrollEvent, step float32, vertical bool) (gfx.EventResult, bool) {
	r := s.Area
	if r.Width <= 0 || event.X < r.X || event.X >= r.Right() || event.Y < r.Y || event.Y >= r.Bottom() {
		return gfx.EventResult{}, false
	}
	shift := event.Modifiers&gfx.ModifierShift != 0
	dx := event.DeltaX
	switch {
	case shift && dx == 0:
		dx = event.DeltaY
	case vertical && abs(event.DeltaY) > abs(dx):
		dx = event.DeltaY
	case abs(dx) < abs(event.DeltaY) && !shift:
		return gfx.EventResult{}, false
	}
	if dx == 0 {
		return gfx.EventResult{}, false
	}
	if vertical && !s.Overflows() {
		// A strip that fits has nothing to scroll; the event is not taken, so nothing
		// claims a wheel it did nothing with.
		return gfx.EventResult{}, false
	}
	if !event.Precise && abs(dx) < step {
		dx = step * dx / abs(dx)
	}
	before := s.Offset
	s.Offset = clamp(s.Offset+dx, 0, s.Max())
	return gfx.EventResult{Handled: true, Repaint: s.Offset != before}, true
}

func clamp(v, low, high float32) float32 { return min(max(v, low), high) }

func abs(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}
