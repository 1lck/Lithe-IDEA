package hscroll

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

var area = gfx.Rect{X: 100, Y: 50, Width: 200, Height: 40}

func TestFitKeepsTheOffsetInRangeAndReportsChanges(t *testing.T) {
	var s State
	if !s.Fit(area, 500) {
		t.Fatal("the first measurement is a change")
	}
	if s.Fit(area, 500) {
		t.Fatal("the same measurement again is not a change")
	}
	moved := area
	moved.X, moved.Y, moved.Height = 140, 90, 80
	if s.Fit(moved, 500) || s.Area != moved {
		t.Fatalf("a box that only moves is recorded but is not a change, area %+v", s.Area)
	}
	s.Fit(area, 500)
	s.Offset = 250
	if !s.Fit(area, 400) || s.Offset != 200 {
		t.Fatalf("offset = %v, want 200 once the content is narrower", s.Offset)
	}
	if !s.Fit(area, 150) || s.Offset != 0 || s.Overflows() {
		t.Fatalf("content that fits: offset %v, overflows %v", s.Offset, s.Overflows())
	}
	s.Offset = -5
	if !s.Fit(area, 150) || s.Offset != 0 {
		t.Fatalf("a negative offset is clamped to 0, got %v", s.Offset)
	}
}

func TestOverflowsAllowsHalfAPointOfRounding(t *testing.T) {
	s := State{Area: area, Content: 200.4}
	if s.Overflows() {
		t.Fatal("content within half a point of the box fits")
	}
	s.Content = 201
	if !s.Overflows() || s.Max() != 1 {
		t.Fatalf("overflows %v, max %v", s.Overflows(), s.Max())
	}
	if (&State{Content: 10}).Overflows() {
		t.Fatal("a box not measured yet does not overflow")
	}
}

func TestRevealScrollsTheLeast(t *testing.T) {
	s := State{Area: area, Content: 1000, Offset: 300}
	if s.Reveal(350, 450) || s.Offset != 300 {
		t.Fatalf("a span in view does not scroll, offset %v", s.Offset)
	}
	if !s.Reveal(600, 700) || s.Offset != 500 {
		t.Fatalf("a span to the right brings its right edge to the box's, offset %v", s.Offset)
	}
	if !s.Reveal(100, 180) || s.Offset != 100 {
		t.Fatalf("a span to the left brings its left edge to the box's, offset %v", s.Offset)
	}
	if !s.Reveal(400, 900) || s.Offset != 400 {
		t.Fatalf("a span wider than the box shows its left end, offset %v", s.Offset)
	}
	if !s.Reveal(950, 1000) || s.Offset != 800 {
		t.Fatalf("the offset stops at the end of the content, offset %v", s.Offset)
	}
	unmeasured := State{Content: 1000}
	if unmeasured.Reveal(500, 600) || unmeasured.Offset != 0 {
		t.Fatal("before the box is measured nothing scrolls")
	}
}

func TestThumbShowsTheShareInView(t *testing.T) {
	s := State{Area: area, Content: 200}
	if _, _, ok := s.Thumb(); ok {
		t.Fatal("content that fits has no thumb")
	}
	s.Content = 400
	left, length, ok := s.Thumb()
	if !ok || left != 0 || length != 100 {
		t.Fatalf("at the start: left %v, length %v, ok %v", left, length, ok)
	}
	s.Offset = s.Max()
	if left, length, _ = s.Thumb(); left != 100 || length != 100 {
		t.Fatalf("at the end: left %v, length %v", left, length)
	}
	s.Content, s.Offset = 100000, 0
	if _, length, _ = s.Thumb(); length != MinThumb {
		t.Fatalf("a very wide content keeps the least length, got %v", length)
	}
}

func scroll(x, y, dx, dy float32) gfx.ScrollEvent {
	return gfx.ScrollEvent{X: x, Y: y, DeltaX: dx, DeltaY: dy, Precise: true}
}

func TestWheelTakesSidewaysSwipesOverItsBox(t *testing.T) {
	s := State{Area: area, Content: 500}
	if _, taken := s.Wheel(scroll(50, 60, 30, 0), 24, false); taken {
		t.Fatal("a swipe outside the box is not taken")
	}
	result, taken := s.Wheel(scroll(150, 60, 30, 2), 24, false)
	if !taken || !result.Handled || !result.Repaint || s.Offset != 30 {
		t.Fatalf("sideways swipe: taken %v, result %+v, offset %v", taken, result, s.Offset)
	}
	if _, taken = s.Wheel(scroll(150, 60, 2, 30), 24, false); taken || s.Offset != 30 {
		t.Fatal("an up and down swipe is left to the vertical scroll")
	}
	shifted := scroll(150, 60, 0, 40)
	shifted.Modifiers = gfx.ModifierShift
	if _, taken = s.Wheel(shifted, 24, false); !taken || s.Offset != 70 {
		t.Fatalf("Shift turns the wheel sideways, offset %v", s.Offset)
	}
	s.Offset = s.Max()
	result, taken = s.Wheel(scroll(150, 60, 30, 0), 24, false)
	if !taken || !result.Handled || result.Repaint || s.Offset != 300 {
		t.Fatalf("at the end: taken %v, result %+v, offset %v", taken, result, s.Offset)
	}
}

func TestWheelStepsAtLeastOneStepForAWheelThatClicks(t *testing.T) {
	s := State{Area: area, Content: 500}
	event := scroll(150, 60, 3, 0)
	event.Precise = false
	if _, taken := s.Wheel(event, 24, false); !taken || s.Offset != 24 {
		t.Fatalf("offset %v, want one step of 24", s.Offset)
	}
	event.DeltaX = -3
	if _, taken := s.Wheel(event, 24, false); !taken || s.Offset != 0 {
		t.Fatalf("offset %v, want back at 0", s.Offset)
	}
}

func TestVerticalWheelScrollsAStripThatOverflows(t *testing.T) {
	s := State{Area: area, Content: 500}
	if _, taken := s.Wheel(scroll(150, 60, 0, 40), 24, true); !taken || s.Offset != 40 {
		t.Fatalf("a plain wheel scrolls the strip, offset %v", s.Offset)
	}
	fits := State{Area: area, Content: 150}
	if _, taken := fits.Wheel(scroll(150, 60, 0, 40), 24, true); taken {
		t.Fatal("a strip that fits does not take the wheel")
	}
}
