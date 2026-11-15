package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// The screenshot archive was captured from a824bd5c. These are the surfaces of
// that client's Lithe palette, rather than Viva's default IDE theme.
func TestBaselineWorkbenchSurfaces(t *testing.T) {
	for _, dark := range []bool{false, true} {
		theme, colors := lightLook()
		surface, chrome := gfx.RGB24(0xffffff), gfx.RGB24(0xe8ebef)
		if dark {
			theme, colors = darkLook()
			surface, chrome = gfx.RGB24(0x191a1c), gfx.RGB24(0x28292c)
		}
		if colors.Panel != surface || colors.Editor != surface || colors.Chrome != chrome {
			t.Fatalf("dark=%v: tool windows and editor must share the baseline surface; got %+v", dark, colors)
		}
		if theme.Transition.Duration != 0 {
			t.Fatal("product menus must open without a transition")
		}
	}
}

func TestBaselineWelcomeEmptyStateHasVisualHierarchy(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	var title, hint gfx.Rect
	for _, text := range h.driver.Snapshot().Labels {
		if text.Value == h.app.text.Welcome.EmptyTitle {
			title = text.Bounds
		}
		if text.Value == h.app.text.Welcome.EmptyHint {
			hint = text.Bounds
		}
	}
	if title.Width == 0 || hint.Width == 0 || hint.Y <= title.Y {
		t.Fatalf("empty state title=%v hint=%v", title, hint)
	}
	if h.app.text.Welcome.EmptyTitle != "没有最近项目" {
		t.Fatalf("empty state did not use the original shared label: %q", h.app.text.Welcome.EmptyTitle)
	}
}
