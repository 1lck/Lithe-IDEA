//go:build vivahead && lithevisual

package workbench

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualIndentGuides(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, appearance := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		t.Run(appearance.theme, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "IndentDemo.java")
			const sample = "class IndentDemo {\n    void save(boolean valid) {\n        if (valid) {\n            for (int i = 0; i < 3; i++) {\n                System.out.println(i);\n\n                System.out.println(valid);\n            }\n        }\n    }\n}\n"
			if err := os.WriteFile(path, []byte(sample), 0o600); err != nil {
				t.Fatal(err)
			}
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": appearance.theme}); err != nil {
				t.Fatal(err)
			}
			client := core.NewClient()
			opts := DesktopOptions(client, prefs, "test")
			opts.Languages = []string{appearance.language}
			opts.OpenFile = path
			var session *headless.Session
			h := newHarnessWithDriver(t, opts, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 800, 400
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.app.openStandaloneFile(path)
			h.await("standalone editor open", func() bool {
				return h.app.project != nil && h.app.project.docs.byPath(path) != nil
			})
			d := h.app.project.docs.byPath(path)
			h.await("scope pairs ready", func() bool {
				state := h.app.editor.colorDecorations.docs[d.id]
				return state != nil && state.bracketView == d.view && state.bracketRevision == d.view.Revision()
			})
			caret := strings.Index(sample, "println(i)")
			d.view.SetSelection(caret, caret)
			if !h.app.editorPreferences.IndentGuides {
				t.Fatal("ordinary guides should be enabled by default")
			}
			on, off := true, false
			var previous []byte
			for _, scene := range []struct {
				name   string
				stored core.EditorStoredPreferences
			}{
				{"normal", core.EditorStoredPreferences{}},
				{"rainbow", core.EditorStoredPreferences{RainbowIndentGuides: &on}},
				{"off", core.EditorStoredPreferences{IndentGuides: &off, RainbowIndentGuides: &on}},
			} {
				resolved, err := client.ResolveEditorPreferences(t.Context(), scene.stored)
				if err != nil {
					t.Fatal(err)
				}
				h.app.editorPreferences = resolved
				h.app.invalidator.Invalidate()
				h.settle()
				png := filepath.Join(out, "indent-guides-"+appearance.theme+"-"+scene.name+".png")
				if err := session.Screenshot(png); err != nil {
					t.Fatal(err)
				}
				current, err := os.ReadFile(png)
				if err != nil {
					t.Fatal(err)
				}
				if bytes.Equal(previous, current) {
					t.Fatalf("%s rendered identically to the preceding presentation", scene.name)
				}
				previous = current
			}
		})
	}
}
