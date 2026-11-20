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

func TestVisualProjectMenuRemove(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"en-US", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				root := t.TempDir()
				current, recent := filepath.Join(root, "CurrentProject"), filepath.Join(root, "RecentProject")
				for _, path := range []string{current, recent} {
					if err := os.Mkdir(path, 0700); err != nil {
						t.Fatal(err)
					}
				}
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.open(current)
				missing := filepath.Join(root, "MissingProject")
				h.app.reduceRecent([]core.RecentProject{{Path: recent, LastOpenedAt: 3}, {Path: missing, LastOpenedAt: 2}}, core.NormalizeRecent(), true)
				h.app.openProjectMenu()
				h.await("missing recent project", func() bool { return h.app.missing[missing] })
				h.settle()
				if err := session.Screenshot(filepath.Join(out, "project-menu-remove-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
