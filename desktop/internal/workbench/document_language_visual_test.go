//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualSearchFirstLineLanguage(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"en", "zh-Hans"} {
			name := theme + "-" + language
			t.Run(name, func(t *testing.T) {
				root := newTestRepository(t)
				path := writeFirstLineViewFile(t, root)
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &gitKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1280, 800
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				registerFirstLineViewSyntax(t, h)
				p := h.openCommit(root)
				tab := openDiffTab(t, h, p, filepath.Base(path))
				if tab.after == nil || tab.after.view.ReadOnly() {
					t.Fatal("the working copy is not editable")
				}
				if err := session.Screenshot(filepath.Join(out, "first-line-diff-"+name+".png")); err != nil {
					t.Fatal(err)
				}

				h.app.openFile(p, path)
				doc := p.docs.byPath(path)
				if doc == nil || doc.tabless || !doc.view.ApplyEdit(editorview.Edit{StartLine: 0, EndLine: 1, Text: "ordinary text\n"}, true) {
					t.Fatal("could not edit the first line in the document tab")
				}
				h.app.openEverywhere(p)
				h.settle()
				h.clickNamed(h.shared("desktop.everywhere.text"))
				h.app.everywhereView.delay = 0
				h.app.everywhereView.preview = true
				h.app.everywhereView.query.SetText("ordinary")
				preview := &h.app.everywhereView.source
				h.await("the changed script in the search preview", func() bool {
					return preview.view != nil && preview.path == path
				})
				if err := session.Screenshot(filepath.Join(out, "first-line-preview-"+name+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
