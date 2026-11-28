//go:build vivahead && lithevisual

package workbench

import (
	"image"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

func TestVisualGitGraphArrow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	dir := newGraphArrowRepository(t)
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice("dark"), Language: "zh-Hans", DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	var session *headless.Session
	const scale = 1.25
	h := newHarnessWithDriver(t, Options{Kernel: gitKernel{core.NewClient()}, Store: prefs, Languages: []string{"zh-Hans"}}, func(config app.Config) (*app.Driver, func(), error) {
		config.Width, config.Height = 1200, 850
		var err error
		session, err = headless.Open(config, nil, headless.Options{Scale: scale})
		if err != nil {
			return nil, nil, err
		}
		return session.Driver(), session.Close, nil
	})
	var before *image.RGBA
	testGraphArrowJump(t, h, dir, func(arrow gfx.Hit, hovered bool) {
		img, err := session.Image()
		if err != nil {
			t.Fatal(err)
		}
		if !hovered {
			before = img
			focusGraphArrow(t, h, arrow.ID)
			focused, err := session.Image()
			if err != nil {
				t.Fatal(err)
			}
			if !graphArrowPixelsChanged(before, focused, arrow.Bounds, scale) {
				t.Fatal("the arrow pixels did not change on keyboard focus")
			}
			if err := session.Screenshot(filepath.Join(out, "git-log-arrow-focus-dark-1.25x.png")); err != nil {
				t.Fatal(err)
			}
			h.key(gfx.KeyTab)
			if h.driver.Snapshot().Focused == arrow.ID {
				t.Fatal("Tab did not leave the graph arrow")
			}
			return
		}
		if !graphArrowPixelsChanged(before, img, arrow.Bounds, scale) {
			t.Fatal("the arrow pixels did not change on hover")
		}
		if err := session.Screenshot(filepath.Join(out, "git-log-arrow-hover-dark-1.25x.png")); err != nil {
			t.Fatal(err)
		}
	})
}

func graphArrowPixelsChanged(before, after *image.RGBA, bounds gfx.Rect, scale float64) bool {
	x0, y0 := int(math.Ceil(float64(bounds.X)*scale)), int(math.Ceil(float64(bounds.Y)*scale))
	x1, y1 := int(math.Floor(float64(bounds.Right())*scale)), int(math.Floor(float64(bounds.Bottom())*scale))
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			if before.RGBAAt(x, y) != after.RGBAAt(x, y) {
				return true
			}
		}
	}
	return false
}
