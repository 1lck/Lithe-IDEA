// Package splitpane owns the bounds and stable pointer coordinates of a resizable pane.
// The caller paints its handle, supplies the available width and persists completed changes.
package splitpane

import (
	"math"

	"github.com/vivaui/viva/ui"
)

// State remembers the user's preferred size separately from a temporary window constraint.
// Minimum, Maximum, OtherMinimum and Divider are logical pixels.
type State struct {
	Minimum, Maximum, OtherMinimum, Divider float32
	preferred                               float32
	dragging                                bool
	startX, startSize, original             float32
}

func New(initial, minimum, maximum, otherMinimum, divider float32) State {
	if math.IsNaN(float64(initial)) || math.IsInf(float64(initial), 0) || initial <= 0 {
		initial = minimum
	}
	return State{Minimum: minimum, Maximum: maximum, OtherMinimum: otherMinimum, Divider: divider, preferred: min(max(initial, minimum), maximum)}
}

// Limits returns the available pane range for the current container width.
func (s *State) Limits(extent float32) (float32, float32) {
	maximum := min(s.Maximum, max(0, extent-s.Divider-s.OtherMinimum))
	return min(s.Minimum, maximum), maximum
}

// Size is the actual size at this extent without overwriting the preference.
func (s *State) Size(extent float32) float32 {
	lo, hi := s.Limits(extent)
	return min(max(s.preferred, lo), hi)
}

func (s *State) Preferred() float32 { return s.preferred }

// Pointer consumes a captured primary drag. committed is true only after release
// changed the requested size; intermediate moves never persist anything.
func (s *State) Pointer(event ui.PointerEvent, id ui.ID, extent float32) (result ui.EventResult, committed bool) {
	switch event.Kind {
	case ui.PointerDown:
		if event.Target != id || (event.Button != ui.PointerButtonPrimary && event.Button != ui.PointerButtonNone) {
			return
		}
		s.dragging, s.startX, s.startSize, s.original = true, event.X, s.Size(extent), s.preferred
		return ui.EventResult{Handled: true, Focus: id, Repaint: true}, false
	case ui.PointerMove, ui.PointerUp:
		if !s.dragging {
			return
		}
		lo, hi := s.Limits(extent)
		value := min(max(s.startSize+event.X-s.startX, lo), hi)
		// A click on a temporarily clamped pane must not replace the stored
		// preference with the constrained width; neither should dragging back.
		preference := value
		if value == min(max(s.startSize, lo), hi) {
			preference = s.original
		}
		changed := preference != s.preferred
		s.preferred = preference
		if event.Kind == ui.PointerUp {
			s.dragging = false
			return ui.EventResult{Handled: true, Repaint: changed}, preference != s.original
		}
		return ui.EventResult{Handled: true, Repaint: changed}, false
	case ui.PointerExit:
		if s.dragging {
			s.preferred, s.dragging = s.original, false
			return ui.EventResult{Repaint: true}, false
		}
	}
	return
}

// Key supports the same keyboard controls as Viva's Splitter.
func (s *State) Key(event ui.KeyEvent, id ui.ID, extent float32) (ui.EventResult, bool) {
	if event.Target != id || event.Release || event.Modifiers != 0 {
		return ui.EventResult{}, false
	}
	lo, hi := s.Limits(extent)
	current := s.Size(extent)
	next := current
	switch event.Key {
	case ui.KeyLeft, ui.KeyUp:
		next -= 16
	case ui.KeyRight, ui.KeyDown:
		next += 16
	case ui.KeyHome:
		next = lo
	case ui.KeyEnd:
		next = hi
	default:
		return ui.EventResult{}, false
	}
	next = min(max(next, lo), hi)
	if next == current {
		return ui.EventResult{Handled: true}, false
	}
	changed := next != s.preferred
	s.preferred = next
	return ui.EventResult{Handled: true, Repaint: changed}, changed
}

// Cancel restores the preference when the pane disappears mid-drag.
func (s *State) Cancel() {
	if s.dragging {
		s.preferred, s.dragging = s.original, false
	}
}
