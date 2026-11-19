//go:build vivahead && lithevisual

package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
	"os"
	"path/filepath"
	"testing"
)

func TestVisualSearchResults(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []string{"zh-Hans", "en"} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language+"-"+theme, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				root := t.TempDir()
				for name, text := range map[string]string{"search-notes.txt": "Search results\nSearch in unsaved documents\n", "docs/guide.txt": "Search across the project\n"} {
					if err := os.MkdirAll(filepath.Dir(filepath.Join(root, name)), 0755); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0600); err != nil {
						t.Fatal(err)
					}
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1440, 900
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.app.searchView.delay = 0
				h.app.everywhereView.delay = 0
				h.open(root)
				p := h.app.project
				h.app.openFindInFiles(p, false)
				h.app.searchView.query.SetText("Search")
				h.await("grouped search", func() bool {
					return !p.search.loading && len(p.search.matches) == 3 && len(p.search.presentation.Rows) == 5 && p.search.counts != nil
				})
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "search-project-"+language+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
				h.app.searchView.optionsOpen = true
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "search-options-"+language+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
				h.app.searchView.optionsOpen = false
				h.app.openEverywhere(p)
				h.app.everywhereView.query.SetText("Search")
				h.await("All content", func() bool { return !p.everywhere.loading && len(p.everywhere.matches) >= 4 })
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "search-all-"+language+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
