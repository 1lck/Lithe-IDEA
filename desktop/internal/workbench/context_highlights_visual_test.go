//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualEditorContextHighlights(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, appearance := range []struct{ theme, language string }{{"light", "en-US"}, {"dark", "zh-Hans"}} {
		t.Run(appearance.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": appearance.theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{appearance.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1000, 640
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			root := t.TempDir()
			text := "package demo\n\nfunc sample(value int) int {\n    if value > 0 {\n        return value + 1\n    }\n    return value\n}\n"
			path := filepath.Join(root, "sample.go")
			if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
				t.Fatal(err)
			}
			h.open(root)
			p := h.app.project
			h.app.openFile(p, path)
			h.await("source opened", func() bool { return p.docs.byPath(path) != nil })
			v := p.docs.byPath(path).view
			capture := func(scene string) {
				t.Helper()
				h.app.invalidator.Invalidate()
				h.settle()
				if err := session.Screenshot(filepath.Join(out, scene+"-"+appearance.theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
			selected := strings.Index(text, "value +")
			v.SetSelection(selected, selected+len("value"))
			capture("context-before")
			var ranges []editorview.Range
			for offset := 0; offset < len(text); {
				at := strings.Index(text[offset:], "value")
				if at < 0 {
					break
				}
				start := offset + at
				offset = start + len("value")
				ranges = append(ranges, editorview.Range{Start: start, End: offset})
			}
			v.SetSymbolHighlights(ranges)
			capture("context-symbol")
			open, close := strings.LastIndex(text, "{"), strings.Index(text, "    }")+4
			v.SetSelection(open, open)
			v.SetSymbolHighlights(nil)
			v.SetBracketMatches([]editorview.BracketMatch{
				{Offset: uint32(open), Mate: uint32(close)},
				{Offset: uint32(close), Mate: uint32(open)},
			})
			capture("context-brackets")
		})
	}
}
