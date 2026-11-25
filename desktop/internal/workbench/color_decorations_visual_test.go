//go:build vivahead && lithevisual

package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// This captures the actual workbench editor with synthetic, Core-normalized sources. Concrete
// plugin installation and algorithms are verified in their owning plugin repository.
func TestVisualColorDecorations(t *testing.T) {
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
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				kernel := &testKernel{Client: core.NewClient()}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				root := t.TempDir()
				text := "// Foreground layers preserve semantic styles\nfunc sample(value int) int {\n    return (value + (2 * 3))\n}\n"
				path := filepath.Join(root, "sample.go")
				if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
					t.Fatal(err)
				}
				h.open(root)
				p := h.app.project
				if p == nil {
					t.Fatal("project did not open")
				}
				h.app.openFile(p, path)
				h.await("source opened", func() bool { return p.docs.byPath(path) != nil })
				d := p.docs.byPath(path)
				legend := syntax.NewSemanticLegend([]string{"keyword", "function", "variable", "comment"}, []string{"deprecated"})
				d.view.SetSemantic(d.view.TextSnapshot(), legend, []syntax.SemanticToken{
					{Line: 0, StartChar: 0, Length: 43, Type: 3}, {Line: 1, StartChar: 0, Length: 4, Type: 0},
					{Line: 1, StartChar: 5, Length: 6, Type: 1}, {Line: 1, StartChar: 12, Length: 5, Type: 2, Modifiers: 1},
					{Line: 2, StartChar: 4, Length: 6, Type: 0}, {Line: 2, StartChar: 12, Length: 5, Type: 2, Modifiers: 1},
				})
				selected := strings.Index(text, "value +")
				d.view.SetSelection(selected, selected+len("value"))
				h.settle()
				base := filepath.Join(out, "color-decorations-"+theme+"-"+language)
				if err := session.Screenshot(base + "-before.png"); err != nil {
					t.Fatal(err)
				}
				rangeValue := func(line, start, end int) any {
					return map[string]any{"start": map[string]int{"line": line, "character": start}, "end": map[string]int{"line": line, "character": end}}
				}
				colors := []map[string]string{{"id": "outer", "light": "#A34E00", "dark": "#FFB86C"}, {"id": "inner", "light": "#7A28A0", "dark": "#BD93F9"}, {"id": "name", "light": "#006E64", "dark": "#50E3C2"}}
				decorations := []map[string]any{
					{"range": rangeValue(1, 11, 12), "colorId": "outer"}, {"range": rangeValue(1, 12, 17), "colorId": "name"},
					{"range": rangeValue(1, 21, 22), "colorId": "outer"}, {"range": rangeValue(2, 11, 12), "colorId": "outer"},
					{"range": rangeValue(2, 12, 17), "colorId": "name"}, {"range": rangeValue(2, 20, 21), "colorId": "inner"},
					{"range": rangeValue(2, 26, 27), "colorId": "inner"}, {"range": rangeValue(2, 27, 28), "colorId": "outer"},
				}
				decoded, err := kernel.DecodeEditorProviders(t.Context(), map[string]any{"kind": "mergeColorDecorations", "value": map[string]any{"sources": []any{map[string]any{"sourceId": "dev.lithe.test.foreground/colors", "colorLegend": colors, "value": map[string]any{"decorations": decorations}}}}})
				if err != nil {
					t.Fatal(err)
				}
				var result struct {
					Decorations []core.PluginColorDecoration `json:"decorations"`
				}
				if err := json.Unmarshal(decoded, &result); err != nil {
					t.Fatal(err)
				}
				spans := make([]editorview.ColorDecoration, 0, len(result.Decorations))
				for _, r := range result.Decorations {
					spans = append(spans, editorview.ColorDecoration{StartLine: r.Range.Start.Line, StartCharacter: r.Range.Start.Character, EndLine: r.Range.End.Line, EndCharacter: r.Range.End.Character, Light: r.Light, Dark: r.Dark})
				}
				d.view.SetPreparedColorDecorations(editorview.PrepareColorDecorations(d.view.TextSnapshot(), spans))
				h.settle()
				if err := session.Screenshot(base + "-after.png"); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
