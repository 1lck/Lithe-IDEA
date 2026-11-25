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

// TestVisualDeletedDocument captures both ways out after the open file's directory
// is removed: explicitly recreate the file, or discard the preserved editor and close.
func TestVisualDeletedDocument(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"en-US", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
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
				root := filepath.Join(t.TempDir(), "RecreationDemo")
				writeTreeFiles(t, root, "test/controller/Document.txt")
				p := h.openTree(t, root)
				path := filepath.Join(root, "test", "controller", "Document.txt")
				h.app.openFile(p, path)
				h.await("the open document", func() bool { return p.docs.byPath(path) != nil })
				d := p.docs.byPath(path)
				h.await("the initial document check", func() bool { return !d.checking && !d.checkPending })
				for _, watch := range p.docs.watches {
					watch.close()
				}
				p.docs.watches = nil
				h.settle()
				if err := os.RemoveAll(filepath.Dir(path)); err != nil {
					t.Fatal(err)
				}
				d.checkPending = true
				h.app.scheduleDocumentChecks(p)
				h.await("the deleted-file notice", func() bool {
					return d.conflicted && d.conflictMissing && !d.checking && !d.checkPending
				})
				h.settle()
				if !h.shows(h.shared("desktop.document.discardAndClose")) || !h.shows(h.shared("native.allowRecreatingFile")) {
					t.Fatal("deleted-file notice did not paint both actions")
				}
				if err := session.Screenshot(filepath.Join(out, "deleted-document-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
				h.clickShared("desktop.document.discardAndClose")
				h.await("the discarded tab", func() bool { return p.docs.byPath(path) == nil })
			})
		}
	}
}
