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

// Only Core refuses this rename: the destination is absent from the fixture.
// Capture the toast after the dialog closes, not its inline preflight error.
func TestVisualProjectTreeCoreRenameRefusal(t *testing.T) {
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
				root := filepath.Join(t.TempDir(), "RenameDemo")
				const source = "notes.txt"
				writeTreeFiles(t, root, source)
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language}); err != nil {
					t.Fatal(err)
				}
				kernel := &refusingTreeRenameKernel{testKernel: &testKernel{Client: core.NewClient()}}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{Scale: 1})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				p := h.openTree(t, root)
				h.openTreeFileTab(p, filepath.Join(root, source))
				h.rightClickAt(h.treeNameHit(source).Bounds)
				h.popupClick(h.shared("desktop.files.rename"))
				h.clickNamed(h.shared("desktop.files.name"))
				h.key(gfx.KeyEnd)
				h.typeText(".bak")
				confirm := h.shared("desktop.files.renameAction")
				h.clickNamed(confirm)
				h.await("Core's name conflict toast", func() bool {
					return h.shows(h.shared("desktop.files.nameExists"))
				})
				if !kernel.called.Load() || h.hasControl(confirm) {
					t.Fatal("expected a submitted rename refused by Core, not an inline name conflict")
				}
				if err := session.Screenshot(filepath.Join(out, "project-tree-core-rename-refusal-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
