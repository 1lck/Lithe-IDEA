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
	"github.com/vivaui/viva/ui"
)

// TestVisualReferencesToolWindow captures the References tool window after Find Usages on a
// constant used in two files: the tree of usages under their files, the toolbar, the header's
// tab and the preview of the selected usage; then the editor's menu opened on the constant.
// Dark/light x Chinese/English are independent sessions and OS-free.
func TestVisualReferencesToolWindow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{
		{"dark", "zh-Hans"}, {"dark", "en"},
		{"light", "zh-Hans"}, {"light", "en"},
	} {
		t.Run(look.theme+"-"+look.language, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme: themeChoice(look.theme), Language: look.language,
				DisableAutoSave: true,
			}); err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(t.TempDir(), "viva")
			if err := os.MkdirAll(filepath.Join(root, "ui"), 0700); err != nil {
				t.Fatal(err)
			}
			absolute := filepath.Join(root, "ui", "absolute.go")
			layout := filepath.Join(root, "ui", "layout.go")
			files := map[string]string{
				absolute: "package ui\n\n// The ways a box is placed.\nconst (\n\tabsSelf  uint8 = 1 << 0\n\tabsChild uint8 = 1 << 1\n)\n\n// placedSelf reports whether the box is placed by itself.\nfunc placedSelf(flags uint8) bool {\n\treturn flags&absSelf != 0\n}\n",
				layout:   "package ui\n\nfunc (b *Box) Absolute() *Box {\n\tb.flags |= absSelf\n\treturn b\n}\n\nfunc (b *Box) measure() {\n\tif b.flags&absSelf == 0 {\n\t\tb.flow()\n\t}\n}\n",
			}
			for path, source := range files {
				if err := os.WriteFile(path, []byte(source), 0600); err != nil {
					t.Fatal(err)
				}
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()},
				Store:  prefs, Languages: []string{look.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1440, 900
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(root)
			p := h.app.project
			h.app.openFile(p, absolute)
			h.settleChain()
			d := p.docs.byPath(absolute)
			if d == nil {
				t.Fatal("editor not opened")
			}
			usage := func(path string, line, column int) core.PluginSemanticLocation {
				return core.PluginSemanticLocation{
					URI: "file://" + filepath.ToSlash(path), FilePath: path,
					Range: core.PluginDocumentRange{
						Start: core.PluginDocumentPosition{Line: line, UTF16Column: column},
						End:   core.PluginDocumentPosition{Line: line, UTF16Column: column + len("absSelf")},
					},
				}
			}
			targets := []core.PluginSemanticLocation{
				usage(absolute, 4, 1), usage(absolute, 10, 14),
				usage(layout, 3, 12), usage(layout, 8, 12),
			}
			showVisualReferences(h.app, p, d, targets)
			h.settleChain()
			h.await("the usage's preview", func() bool { return visualReferencesReady(h.app) })
			h.settleChain()
			// Keep the chosen usage while the refreshed tree has not declared any
			// rows and focus clears. The screenshot must still show its preview.
			s := &h.app.editor.refs
			selected := s.selected
			s.focus = s.view.RowID(s.selectedRow)
			if s.focus.IsZero() {
				t.Fatal("the selected usage has no painted identity")
			}
			s.view = ui.TreeState{}
			h.app.syncReferenceSelection(new(gfx.Canvas))
			if s.selected != selected {
				t.Fatalf("cleared focus selected %q, want %q", s.selected, selected)
			}
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "references-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}

			// The editor's menu opened on absSelf, whose Find Usages asks at the word clicked.
			d.view.GoToNavigation(4, 3, false)
			h.settleChain()
			cell, ok := d.view.CaretRect()
			if !ok {
				t.Fatal("the editor has not painted")
			}
			if err := session.Driver().ClickButton(cell.X, cell.Y+cell.Height/2, gfx.PointerButtonSecondary); err != nil {
				t.Fatal(err)
			}
			h.settleChain()
			h.popupHit(h.shared("desktop.editorMenu.findUsages"))
			if err := session.Screenshot(filepath.Join(out, "references-menu-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// showVisualReferences fills the References tool window as an answer of Find Usages on absSelf
// at its declaration does.
func showVisualReferences(a *App, p *project, d *document, targets []core.PluginSemanticLocation) {
	a.showReferences(p, targets, referenceQuery{documentID: d.id, line: 4, column: 1}, "absSelf")
}

// visualReferencesReady reports whether the window shows what is captured: the preview loaded
// and every usage's line, which Core cuts off the window thread.
func visualReferencesReady(a *App) bool {
	s := &a.editor.refs
	if s.preview.view == nil {
		return false
	}
	for _, line := range s.lines {
		if line.Text == "" {
			return false
		}
	}
	return true
}
