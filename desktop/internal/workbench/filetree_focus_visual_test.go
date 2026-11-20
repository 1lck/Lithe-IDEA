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

func TestVisualProjectTreeMissingFile(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{Scale: 1})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				locateMissingTreeFile(t, h)
				h.settle()
				if err := session.Screenshot(filepath.Join(out, "project-tree-missing-file-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
