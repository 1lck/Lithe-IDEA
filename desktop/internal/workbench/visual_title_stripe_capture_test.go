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

// TestVisualTitleButtonsOnStripes captures the Debug, Search and Settings buttons of the title
// bar on the tool stripes: the default title bar, Settings being dragged to the end of the right
// stripe's top group, the three buttons on the stripes, the settings menu beside its button
// there, the Search tip on the stripe, the stripe menu of Debug and the title bar menu of
// Settings. Dark scenes are in Chinese, light ones in English. It needs only
// LITHE_VISUAL_OUTPUT_DIR.
func TestVisualTitleButtonsOnStripes(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	// onStripes moves Debug and Search to the end of the left stripe's top group and Settings to
	// the end of the right stripe's top group, as drops there do.
	onStripes := func(h *harness) {
		h.app.post(func(a *App) {
			a.reduceChrome(core.MoveChrome(itemTitleDebug, core.ZoneLeftTop, ""))
			a.reduceChrome(core.MoveChrome(itemTitleSearch, core.ZoneLeftTop, ""))
			a.reduceChrome(core.MoveChrome(itemTitleSettings, core.ZoneRightTop, ""))
		})
		h.settle()
	}
	scenes := []struct {
		id   string
		show func(*harness)
	}{
		{"title-default", func(*harness) {}},
		{"settings-dragging", func(h *harness) {
			target := h.app.chrome.zoneRects[zoneRightTop]
			start, end := center(h.button(itemTitleSettings)), gfx.Point{X: target.X + target.Width/2, Y: target.Y + target.Height - 2}
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
		}},
		{"buttons-on-stripes", onStripes},
		{"settings-menu-on-stripe", func(h *harness) {
			onStripes(h)
			h.click(center(h.button(itemTitleSettings)))
			h.settle()
		}},
		{"search-tip-on-stripe", func(h *harness) {
			onStripes(h)
			at := center(h.button(itemTitleSearch))
			if err := h.driver.Move(at.X, at.Y); err != nil {
				t.Fatal(err)
			}
			h.settle()
		}},
		{"debug-stripe-menu", func(h *harness) {
			onStripes(h)
			h.rightClickAt(h.button(itemTitleDebug))
		}},
		{"settings-title-menu", func(h *harness) {
			h.rightClickAt(h.button(itemTitleSettings))
			h.clickNamed(h.shared("desktop.tools.moveTo"))
			h.settle()
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
