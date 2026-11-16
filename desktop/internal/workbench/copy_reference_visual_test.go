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

// TestVisualCopyReferenceLocation captures the actual editor's secondary-click
// menu and the result pasted into an editor via the primary+V shortcut.
// Dark/light x Chinese/English are independent sessions and OS-free.
func TestVisualCopyReferenceLocation(t *testing.T) {
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
			root := filepath.Join(t.TempDir(), "ReferenceDemo")
			if err := os.MkdirAll(root, 0700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(root, "DemoClass.java")
			source := "package com.example;\n\npublic class DemoClass {\n    void goHome(String city, Integer count) {\n        System.out.println(city);\n    }\n}\n"
			if err := os.WriteFile(path, []byte(source), 0600); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()},
				Store: prefs, Languages: []string{look.language},
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
			h.app.openFile(p, path)
			h.settleChain()
			d := p.docs.byPath(path)
			if d == nil {
				t.Fatal("editor not opened")
			}
			d.view.GoToLine(5)
			h.app.focusDocument(d.id)
			h.settleChain()
			h.rightClickAt(h.topHit(d.hit))
			if !h.shows(h.shared("native.copySourceLocation")) {
				t.Fatal("reference copy action missing from context menu")
			}
			if err := session.Screenshot(filepath.Join(out, "reference-menu-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}
			// PositionAt the secondary press controls the reference's line, not
			// the caret set above. Copying a plain file is a valid fallback.
			h.clickNamed(h.shared("native.copySourceLocation"))
			h.await("reference on clipboard", func() bool {
				return len(h.driver.Clipboard()) >= len(path)+3 && h.driver.Clipboard()[:len(path)+2] == path+"#L"
			})
			reference := h.driver.Clipboard()
			if reference[:len(path)] != path || reference[len(path):len(path)+2] != "#L" {
				t.Fatalf("unexpected clipboard reference %q", reference)
			}
			resultPath := filepath.Join(root, "pasted-result.txt")
			if err := os.WriteFile(resultPath, []byte(""), 0600); err != nil {
				t.Fatal(err)
			}
			h.app.openFile(p, resultPath)
			h.settleChain()
			resultDoc := p.docs.byPath(resultPath)
			if resultDoc == nil {
				t.Fatal("result editor not opened")
			}
			h.app.focusDocument(resultDoc.id)
			h.settleChain()
			handled, err := h.driver.ShortcutChord(primaryModifier(), 'v')
			if err != nil || !handled {
				t.Fatalf("clipboard paste shortcut handled=%v error=%v", handled, err)
			}
			h.await("paste result appears", func() bool {
				return resultDoc.view.TextSnapshot().String() == reference
			})
			if err := session.Screenshot(filepath.Join(out, "reference-pasted-"+look.theme+"-"+look.language+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
