package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/hscroll"
	"github.com/vivaui/viva/ui"
)

// sidewaysTabBar is how thick the thumb along the top of a strip of tabs is: thinner than a
// list's, as it sits in the strip's few points above the tabs.
const sidewaysTabBar = 3

// drawSidewaysThumb declares the thumb of the sideways scrollbar of s while there is more to
// scroll to: along the bottom of the box being declared, or along its top when top is set,
// for a strip of tabs. The box must be the one whose rectangle s.Area records, so the thumb
// lines up with it. The thumb is an absolute child of the box, painted over the content and
// under any popup, and takes no pointer hits.
func (a *App) drawSidewaysThumb(f *ui.Frame, s *hscroll.State, top bool) {
	left, length, ok := s.Thumb()
	if !ok {
		return
	}
	thumb := a.colors.Subtle
	thumb.Alpha *= 0.45
	thick := float32(hscroll.Thickness)
	if top {
		thick = sidewaysTabBar
	}
	bar := f.Row().Absolute().Left(left).Width(length).Height(thick).Radius(thick / 2).Background(thumb)
	if top {
		bar.Top(0)
	} else {
		bar.Bottom(2)
	}
}
