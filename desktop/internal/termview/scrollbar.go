package termview

import (
	"math"

	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/ui"
)

// scrollbarShown reports whether the terminal has history to scroll through. The
// alternate screen has none: the program on it owns the whole grid.
func (v *View) scrollbarShown() bool {
	return !v.screen.Modes().AltScreen && v.screen.Scrollback() > 0
}

// scrollArea is the terminal's text as a scroll area: the history above the screen and the
// screen itself, one cell height per line. It paints only the bar, over the right edge of the
// grid, in the terminal's own colors since the window theme has no say in what the terminal's
// ground looks like. A nil canvas gives the geometry alone. fade scales the bar's opacity, 0
// being hidden.
func (v *View) scrollArea(canvas *ui.Canvas, area ui.Rect, fade float32) components.ScrollArea {
	history := float32(v.screen.Scrollback()) * v.cellH
	// Painting the bar reads only these two colors of the theme: the thumb at rest and the
	// thumb under the pointer. The focus ring is not painted since the bar never takes focus.
	theme := ui.Theme{
		Border:          withAlpha(v.pal.termFG, 0.22*fade),
		MutedForeground: withAlpha(v.pal.termFG, 0.55*fade),
	}
	return components.BeginScrollArea(canvas, theme, area, ui.Size{Width: area.Width, Height: area.Height + history}).
		Offset(0, float32(v.screen.Scrollback()-v.screen.ViewOffset())*v.cellH).
		VerticalScrollbar(v.cfg.BarID, v.cfg.Messages.ScrollbarLabel, "")
}

// barFade is how opaque the scrollbar is in this frame. The bar is lit while the pointer is
// anywhere over the terminal or its bar and while it is dragged, and fades out when the
// pointer leaves. A view moved by the keyboard lights it for barLinger, since the pointer may
// be elsewhere. It asks for the frame that starts the fade.
func (v *View) barFade(canvas *ui.Canvas) float32 {
	id := v.cfg.BarID
	now := canvas.Now()
	offset := v.screen.ViewOffset()
	over := v.bar.dragging || canvas.Pressed() == id || canvas.Hovered() == id || canvas.Hovered() == v.cfg.HitID
	if offset != v.bar.offset {
		v.bar.offset, v.bar.since, v.bar.lit = offset, now, true
	}
	target := float32(0)
	if over {
		target = 1
	} else if v.bar.lit {
		if remaining := barLinger - (now - v.bar.since); remaining > 0 {
			target = 1
			canvas.RequestFrameIn(remaining)
		} else {
			v.bar.lit = false
		}
	}
	return canvas.Animate(id, 0, target, ui.DefaultMotion())
}

// paintScrollbar draws the scrollbar over the right edge of the grid. It is only drawn while
// the view moves or the pointer is over the terminal, but its track always takes hits while
// there is history, so moving to the right edge brings it back.
func (v *View) paintScrollbar(canvas *ui.Canvas) {
	if !v.scrollbarShown() || v.cellH <= 0 {
		return
	}
	fade := v.barFade(canvas)
	area := v.scrollArea(canvas, v.layout.area, fade)
	area.EndContent()
}

// barPointer drags the thumb and pages when the track beside it is pressed. It reports false
// for what is not the bar's, so the event goes on to the grid.
func (v *View) barPointer(event ui.PointerEvent) (ui.EventResult, bool) {
	if v.cellH <= 0 {
		return ui.EventResult{}, false
	}
	if !v.scrollbarShown() {
		v.bar.dragging = false
		return ui.EventResult{}, false
	}
	bounds := v.scrollArea(nil, v.layout.area, 1).Geometry()
	switch event.Kind {
	case ui.PointerDown:
		if event.Button != ui.PointerButtonPrimary && event.Button != ui.PointerButtonNone {
			return ui.EventResult{}, false
		}
		thumb := bounds.VerticalThumb
		switch {
		case event.Y < thumb.Y:
			return v.scrollView(v.layout.rows - 1), true
		case event.Y >= thumb.Y+thumb.Height:
			return v.scrollView(-(v.layout.rows - 1)), true
		}
		v.bar.dragging = true
		v.bar.grab = event.Y - thumb.Y
		return ui.EventResult{Handled: true, Repaint: true}, true
	case ui.PointerMove, ui.PointerUp:
		if !v.bar.dragging {
			return ui.EventResult{}, false
		}
		offset := bounds.VerticalOffsetForThumb(event.Y - v.bar.grab)
		line := int(math.Round(float64(offset / v.cellH)))
		result := v.scrollView(v.screen.Scrollback() - line - v.screen.ViewOffset())
		if event.Kind == ui.PointerUp {
			v.bar.dragging = false
		}
		return result, true
	case ui.PointerExit:
		if !v.bar.dragging {
			return ui.EventResult{}, false
		}
		v.bar.dragging = false
		return ui.EventResult{Handled: true}, true
	}
	return ui.EventResult{}, false
}
