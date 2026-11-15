package settingswindow

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

func TestBaselineSettingsSurfaceHierarchy(t *testing.T) {
	for _, test := range []struct {
		dark       bool
		page, card gfx.Color
	}{
		{false, gfx.RGB24(0xf5f5f7), gfx.RGB24(0xffffff)},
		{true, gfx.RGB24(0x1c1d20), gfx.RGB24(0x2b2d30)},
	} {
		p := paletteFor(test.dark)
		if p.window != test.page || p.card != test.card {
			t.Fatalf("dark=%v: page=%v card=%v", test.dark, p.window, p.card)
		}
	}
}

func TestBaselineSettingsControlsFitReferenceWindow(t *testing.T) {
	w := newWindow(NewController(Options{}), Values{Theme: "dark", Language: "en"})
	d := openWindow(t, w)
	shot := d.driver.Snapshot()
	if shot.Width != 900 || shot.Height != 700 {
		t.Fatalf("initial window=%dx%d, want 900x700", shot.Width, shot.Height)
	}
	for _, label := range []string{"Search settings", "Language", "Cancel", "OK"} {
		hit := d.hit(label)
		if hit.Bounds.X < 0 || hit.Bounds.Y < 0 || hit.Bounds.X+hit.Bounds.Width > 900 || hit.Bounds.Y+hit.Bounds.Height > 700 {
			t.Fatalf("%s outside reference window: %v", label, hit.Bounds)
		}
	}
}
