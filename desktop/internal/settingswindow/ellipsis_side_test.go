package settingswindow

import (
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// cutSidebarEntry is where the sidebar shows the start of full followed by "…".
func (d *windowDriver) cutSidebarEntry(full string) gfx.Rect {
	d.t.Helper()
	for _, label := range d.driver.Snapshot().Labels {
		head, cut := strings.CutSuffix(label.Value, "…")
		if cut && head != "" && strings.HasPrefix(full, head) && label.Bounds.X < sidebarWidth {
			return label.Bounds
		}
	}
	d.t.Fatalf("the sidebar does not cut %q short; pick a page it does", full)
	return gfx.Rect{}
}

// restForTip rests the pointer on text long enough for the tooltip delay and returns the text of
// the tooltip's lines joined in order, with the left edge of the leftmost line.
func (d *windowDriver) restForTip(text gfx.Rect, advance func(time.Duration) error) (string, float32) {
	d.t.Helper()
	if err := d.driver.Move(text.X+text.Width/2, text.Y+text.Height/2); err != nil {
		d.t.Fatal(err)
	}
	if err := advance(time.Second); err != nil {
		d.t.Fatal(err)
	}
	var got strings.Builder
	left := float32(-1)
	for _, label := range d.driver.Snapshot().Labels {
		if label.Layer != ui.TooltipLayer {
			continue
		}
		got.WriteString(label.Value)
		if left < 0 || label.Bounds.X < left {
			left = label.Bounds.X
		}
	}
	return got.String(), left
}

// A page name the sidebar cuts short shows in full to its right, over the page beside it, rather
// than below it over the next entries of the list.
func TestSidebarEllipsisTooltipOpensToTheRight(t *testing.T) {
	w := newWindow(NewController(Options{
		Text:     func() *i18n.Messages { return i18n.For(i18n.English) },
		Language: func() i18n.Language { return i18n.English },
	}), Values{Theme: "dark"})
	d := openWindow(t, w)
	full := titleOf(&w.text.Settings, pageBuild)
	text := d.cutSidebarEntry(full)
	got, left := d.restForTip(text, d.driver.Advance)
	if got != full {
		t.Fatalf("the tooltip of the sidebar entry shows %q, want %q", got, full)
	}
	if left < text.X+text.Width {
		t.Fatalf("the tooltip starts at x=%v, left of the end of the sidebar entry at %+v", left, text)
	}
}
