//go:build vivahead && lithevisual

package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/draftstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
	"os"
	"path/filepath"
	"testing"
)

func TestVisualEditorEssentials(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"find-replace", "recovery-conflict", "recent-edits", "scratch-editor", "scratch-list"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				root := filepath.Join(t.TempDir(), "EssentialsDemo")
				if err := os.MkdirAll(root, 0700); err != nil {
					t.Fatal(err)
				}
				source := "// Editor essentials demo\n\nfunc greet(name string) string {\n    message := \"Hello, \" + name\n    return message\n}\n\nfunc preview() {\n    greet(\"Lithe\")\n    greet(\"世界 😀\")\n}\n"
				path := filepath.Join(root, "greeting.txt")
				if err := os.WriteFile(path, []byte(source), 0600); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1440, 900
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				if scene == "recovery-conflict" {
					if err := h.app.recovery.store.Save(draftstore.Entry{Root: root, Path: path, Name: "greeting.txt", BaseHash: draftstore.Hash([]byte("older baseline")), Text: source + "\n// Recovered unsaved note: finish this change.\n"}); err != nil {
						t.Fatal(err)
					}
				}
				h.open(root)
				p := h.app.project
				h.app.openFile(p, path)
				h.settleChain()
				d := p.docs.byPath(path)
				if d == nil {
					t.Fatal("editor missing")
				}
				switch scene {
				case "find-replace":
					d.find.debounce = -1
					d.view.SetSelection(0, 0)
					h.app.openEditorFind(true)
					d.find.query.SetText("greet")
					d.find.replacement.SetText("welcome")
					h.app.refreshEditorFind(p, d)
					h.await("search matches", func() bool { return !d.find.pending && len(d.find.matches) == 3 })
				case "recovery-conflict":
					if !d.conflicted || !d.dirty() {
						t.Fatal("recovery must preserve a dirty conflict")
					}
				case "recent-edits":
					h.app.insertForTest(d, "\n// Work in progress\n")
					other := filepath.Join(root, "tasks.txt")
					if err := os.WriteFile(other, []byte("Review editor settings\nKeep recovery copy\n"), 0600); err != nil {
						t.Fatal(err)
					}
					h.app.openFile(p, other)
					h.settleChain()
					h.app.insertForTest(p.docs.byPath(other), "Ready for review\n")
					h.app.openRecentFiles(true)
					h.settleChain()
					if len(h.app.recentFiles.list) != 2 {
						t.Fatal("edit history missing")
					}
				case "scratch-editor", "scratch-list":
					h.app.newScratch(p)
					scratch := p.selectedDocument(p.docs.group)
					h.app.insertForTest(scratch, "# Working notes\n\nWrite before choosing a destination.\n\n- Search and replace\n- Durable recovery\n- Independent keymap schemes\n\n中文与 emoji 😀 are preserved.\n")
					h.app.flushCheckpoint(p, scratch, false)
					h.settleChain()
					if scene == "scratch-list" {
						h.app.closeDocument(p, scratch.id)
						h.settleChain()
						h.app.openScratchList()
						h.settleChain()
						if len(h.app.drafts.entries) != 1 {
							t.Fatal("persisted scratch missing")
						}
					}
				}
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, scene+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
				// A capture may intentionally show a recovery conflict; release it before normal cleanup.
				if d.conflicted {
					h.app.keepDocumentEditor(p, d)
					h.app.saveDocument(p, d.id)
					h.settleChain()
				}
				h.app.recentFiles.open, h.app.drafts.open = false, false
			})
		}
	}
}
