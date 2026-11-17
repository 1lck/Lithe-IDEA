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

func TestVisualDiagnosticUnderline(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []string{"en", "zh-Hans"} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language+"-"+theme, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				root := t.TempDir()
				path := filepath.Join(root, "Diagnostics.txt")
				text := "MissingType variable;\n\tMissingType variable;\n中MissingType variable;\n😀MissingType variable;\n\t中😀MissingType variable;\n\nWarningType variable;\n"
				if err := os.WriteFile(path, []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1100, 700
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
					t.Fatal("editor missing")
				}
				d.view.SetMarkers([]editorview.Marker{{Line: 0, Start: 0, End: 11, Severity: editorview.MarkerError}, {Line: 1, Start: 1, End: 12, Severity: editorview.MarkerError}, {Line: 2, Start: 1, End: 12, Severity: editorview.MarkerError}, {Line: 3, Start: 2, End: 13, Severity: editorview.MarkerError}, {Line: 4, Start: 4, End: 15, Severity: editorview.MarkerError}, {Line: 6, Start: 0, End: 11, Severity: editorview.MarkerWarning}})
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "diagnostic-"+language+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
