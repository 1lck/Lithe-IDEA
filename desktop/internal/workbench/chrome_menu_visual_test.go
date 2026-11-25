//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualWorkbenchStripeContextMenu captures the real workspace and its Project
// menu after a resize. Dark uses Chinese and light uses English.
func TestVisualWorkbenchStripeContextMenu(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the stripe context menu")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		t.Run(look.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": look.theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: core.NewClient(), Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(t.TempDir())
			h.settleChain()
			if err := h.driver.Resize(1000, 800); err != nil {
				t.Fatal(err)
			}
			if err := session.Screenshot(filepath.Join(out, "workbench-stripe-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
			h.rightClickAt(h.button(itemProject))
			if !h.hasPopupItem(h.shared("native.hideEntry")) {
				t.Fatal("the Project context menu did not open")
			}
			if err := session.Screenshot(filepath.Join(out, "workbench-stripe-menu-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
