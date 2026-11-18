//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualStripeEllipsis captures the tool stripes and the "…" button that lists the stripe
// buttons the user hid: the stripes with nothing hidden, the list beside the button at the end
// of the left stripe's top group, the button being dragged to the end of the right stripe, and
// the list beside it there and in the right stripe's top group. Dark scenes are in Chinese,
// light ones in English. It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualStripeEllipsis(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	// hideCommit hides the Commit button, which brings the "…" button out, and returns the
	// bounds of the "…" button.
	hideCommit := func(h *harness) gfx.Rect {
		h.app.post(func(a *App) { a.hideEntry(catalogIndex[itemCommit]) })
		h.settle()
		return h.pageHit(h.shared("native.toolWindows")).Bounds
	}
	// dragToRightEnd presses on the "…" button at from and moves it over the end of the right
	// stripe; release drops it there.
	dragToRightEnd := func(h *harness, from gfx.Rect) (release func()) {
		target := h.app.chrome.zoneRects[zoneBottomRight]
		start, end := center(from), gfx.Point{X: target.X + target.Width/2, Y: target.Y + target.Height - 2}
		if err := h.driver.Press(start.X, start.Y, gfx.PointerButtonPrimary); err != nil {
			t.Fatal(err)
		}
		for i := 1; i <= 8; i++ {
			f := float32(i) / 8
			if err := h.driver.Move(start.X+(end.X-start.X)*f, start.Y+(end.Y-start.Y)*f); err != nil {
				t.Fatal(err)
			}
		}
		h.settle()
		return func() {
			if err := h.driver.Release(end.X, end.Y, gfx.PointerButtonPrimary); err != nil {
				t.Fatal(err)
			}
			h.settle()
		}
	}
	scenes := []struct {
		id   string
		show func(*harness)
	}{
		{"stripes-default", func(*harness) {}},
		{"ellipsis-left-list", func(h *harness) {
			h.click(center(hideCommit(h)))
			h.settle()
		}},
		{"ellipsis-dragging", func(h *harness) {
			dragToRightEnd(h, hideCommit(h))
		}},
		{"ellipsis-right-bottom-list", func(h *harness) {
			dragToRightEnd(h, hideCommit(h))()
			h.clickNamed(h.shared("native.toolWindows"))
		}},
		{"ellipsis-right-top-list", func(h *harness) {
			hideCommit(h)
			h.app.post(func(a *App) { a.reduceChrome(core.MoveChrome(itemToolWindows, core.ZoneRightTop, "")) })
			h.settle()
			h.clickNamed(h.shared("native.toolWindows"))
		}},
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		for _, scene := range scenes {
			t.Run(scene.id+"-"+look.theme, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": look.theme}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1100, 680
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				root := t.TempDir()
				writeTreeFiles(t, root, "src/main.txt", "notes.txt", "readme.txt")
				h.openTree(t, root)
				scene.show(h)
				if err := session.Screenshot(filepath.Join(out, scene.id+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
