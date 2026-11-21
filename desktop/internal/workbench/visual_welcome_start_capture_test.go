//go:build vivahead && lithevisual

package workbench

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualWelcomeStartButtons captures the welcome page's ways to start at the default
// window width and at the narrowest one the window allows. Dark scenes are in Chinese, light
// ones in English. It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualWelcomeStartButtons(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("LITHE_VISUAL_OUTPUT_DIR is not set")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		for _, width := range []int{1280, 900} {
			name := fmt.Sprintf("welcome-%d-%s", width, look.theme)
			t.Run(name, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": look.theme}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = width, 600
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				if err := session.Screenshot(filepath.Join(out, name+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
