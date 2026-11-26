//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualProblemsSourcePreviewRainbow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		t.Run(theme, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "totals.go")
			const sample = "package sample\nfunc total(values []int) int {\n    result := 0\n    for _, value := range values {\n        if value > 0 {\n            result += value\n        }\n    }\n    return result\n}\n"
			if err := os.WriteFile(path, []byte(sample), 0o600); err != nil {
				t.Fatal(err)
			}
			on := true
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{
				Theme: themeChoice(theme), Language: "en", DisableAutoSave: true,
				EditorPreferences: core.EditorStoredPreferences{
					RainbowBrackets: &on, RainbowVariables: &on, IndentGuides: &on, RainbowIndentGuides: &on,
					RainbowLightColors: []string{"#B04A45", "#317856", "#6752BA", "#996111"},
					RainbowDarkColors:  []string{"#EF8B80", "#91C99F", "#B3A0EA", "#E6BF70"},
				},
			}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{"en"},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1440, 1000
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
			h.await("rainbow preview source document opened", func() bool { return p.docs.byPath(path) != nil })
			h.app.pluginDiagnostics = map[string]*plugindiag.Set{"dev.lithe.test.rainbow-preview": problemSet(t,
				plugindiag.Diagnostic{FileKey: path, DisplayPath: "totals.go", Line: 5, Column: 12,
					Severity: plugindiag.SeverityWarning, Message: "Check total for overflow"},
			)}
			h.app.markProblemsChanged()
			h.app.problems.show, h.app.problems.project = true, true
			openProblemsPanel(t, h)
			h.clickNamed(problemsRowNamed(t, h, problemsDiagnosticRow(t, h, "Check total for overflow")))
			sp := &h.app.problems.preview
			h.await("rainbow full-source preview ready", func() bool {
				return sp.view != nil && sp.path == path && viewHasForeground(sp.view, 0xB04A45)
			})
			h.click(center(h.hit(sp.hit)))
			caret := strings.Index(sample, "result +=")
			sp.view.SetSelection(caret, caret)
			h.app.invalidator.Invalidate()
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "problems-source-preview-rainbow-"+theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
