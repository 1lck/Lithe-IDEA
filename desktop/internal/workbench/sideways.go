package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/hscroll"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// sidewaysTabBar is how thick the thumb along the top of a strip of tabs is: thinner
	// than a list's, as it sits in the strip's few points above the tabs.
	sidewaysTabBar = 3
	// sidewaysTabGrip and sidewaysListGrip are how tall the band that takes a press on a
	// strip's and a list's scrollbar is: a little taller than the thumb, so a thin thumb is
	// easy to take, and not so tall that it takes the presses meant for what is under it.
	sidewaysTabGrip  = 6
	sidewaysListGrip = hscroll.Thickness + 4
	// sidewaysListInset is how far a list's thumb is from the bottom of its box.
	sidewaysListInset = 2
)

// The identities of the sideways scrollbars: that of the Git log's
// changed files and, as tabScrollbar.At(n), that of the strip of the n-th group of tabs the
// frame declares.
var (
	logFilesScrollbar = tree.ID(shellPage, "log-files-scrollbar")
	tabScrollbar      = tree.Sub(shellPage, tree.Name("editor-tab-scrollbar"))
)

// sidewaysBars are the sideways scrollbars the last frame declared, so that a press on one
// finds the scroll it moves, and the drag of a thumb that is under way.
type sidewaysBars struct {
	bars []sidewaysBar
	drag sidewaysDrag
}

// sidewaysBar is the scroll that the bar whose hit is id moves.
type sidewaysBar struct {
	id     gfx.ID
	scroll *hscroll.State
}

// sidewaysDrag is a thumb being dragged: the bar it is on, the scroll it moves and the point
// of the thumb the press took, as hscroll.State.Grab returned it.
type sidewaysDrag struct {
	id     gfx.ID
	scroll *hscroll.State
	grab   float32
}

// beginFrame forgets the bars of the last frame, before a frame declares its own. The drag
// under way is kept: it goes on across frames until the button is released.
func (b *sidewaysBars) beginFrame() {
	clear(b.bars)
	b.bars = b.bars[:0]
}

// drawSidewaysThumb declares the sideways scrollbar of s while there is more to scroll to:
// along the bottom of the box being declared, or along its top when top is set, for a strip
// of tabs. The box must be the one whose rectangle s.Area records, so the bar lines up with
// it. The bar is an absolute child of the box, painted over the content and under any popup.
// Its hit, id, runs the box's width, so the thumb can be dragged and a press beside it moves
// it there; the thumb brightens while the pointer is over the bar and while it is dragged.
func (a *App) drawSidewaysThumb(f *ui.Frame, id gfx.ID, s *hscroll.State, top bool) {
	left, length, ok := s.Thumb()
	if !ok {
		return
	}
	a.sideways.bars = append(a.sideways.bars, sidewaysBar{id: id, scroll: s})
	thumb := a.colors.Subtle
	thumb.Alpha *= 0.45
	hot := a.colors.Subtle
	hot.Alpha *= 0.8
	thick, grip := float32(sidewaysTabBar), float32(sidewaysTabGrip)
	if !top {
		thick, grip = hscroll.Thickness, sidewaysListGrip
	}
	track := f.Row().Absolute().Left(0).Width(s.Viewport()).Height(grip).
		HitWith(id, a.text.Editor.HorizontalScrollbar, gfx.HitOptions{Role: gfx.RoleSeparator, SkipFocus: true})
	if top {
		track.Top(0)
	} else {
		track.Bottom(0)
	}
	track.Children(func() {
		color := thumb
		if a.sideways.drag.id == id {
			color = hot
		}
		bar := f.Row().Absolute().Left(left).Width(length).Height(thick).Radius(thick / 2).
			Background(color).StateFrom(track).Hover(ui.Look{}.Background(hot))
		if top {
			bar.Top(0)
		} else {
			bar.Bottom(sidewaysListInset)
		}
	})
}

// sidewaysPointer drags the thumb of a sideways scrollbar the last frame declared: a press on
// a bar takes the thumb, or moves it under the pointer when it is beside it, the moves that
// follow drag it, and the release lets it go. The second result is false for an event that
// is not the bars'.
func (a *App) sidewaysPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	b := &a.sideways
	switch event.Kind {
	case gfx.PointerDown:
		b.drag = sidewaysDrag{}
		if event.Target.IsZero() || (event.Button != gfx.PointerButtonPrimary && event.Button != gfx.PointerButtonNone) {
			return gfx.EventResult{}, false
		}
		for _, bar := range b.bars {
			if bar.id != event.Target {
				continue
			}
			grab, _, ok := bar.scroll.Grab(event.X)
			if !ok {
				return gfx.EventResult{}, false
			}
			b.drag = sidewaysDrag{id: bar.id, scroll: bar.scroll, grab: grab}
			return gfx.EventResult{Handled: true, Repaint: true}, true
		}
		return gfx.EventResult{}, false

	case gfx.PointerMove:
		if b.drag.scroll == nil {
			return gfx.EventResult{}, false
		}
		return gfx.EventResult{Handled: true, Repaint: b.drag.scroll.DragTo(event.X, b.drag.grab)}, true

	case gfx.PointerUp:
		if b.drag.scroll == nil {
			return gfx.EventResult{}, false
		}
		b.drag.scroll.DragTo(event.X, b.drag.grab)
		b.drag = sidewaysDrag{}
		return gfx.EventResult{Handled: true, Repaint: true}, true

	case gfx.PointerExit:
		// The runtime reports an exit during a held press only once the button is released,
		// so this ends a drag whose release was lost.
		active := b.drag.scroll != nil
		b.drag = sidewaysDrag{}
		return gfx.EventResult{Repaint: active}, active
	}
	return gfx.EventResult{}, false
}
