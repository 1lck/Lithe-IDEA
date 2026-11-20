package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestOpenFileUsesPluginFirstLineLanguage(t *testing.T) {
	t.Run("grammar", func(t *testing.T) { testOpenFileUsesPluginFirstLineLanguage(t, false) })
	t.Run("metadata", func(t *testing.T) { testOpenFileUsesPluginFirstLineLanguage(t, true) })
}

func testOpenFileUsesPluginFirstLineLanguage(t *testing.T, standalone bool) {
	t.Helper()
	kernel := core.NewClient()
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/languages/first-line.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	const id = "dev.lithe.test.first-line"
	grammarPath := "grammars/sample.tmLanguage.json"
	if standalone {
		var declaration map[string]json.RawMessage
		var languages []map[string]json.RawMessage
		if err := json.Unmarshal(manifest, &declaration); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(declaration["languages"], &languages); err != nil {
			t.Fatal(err)
		}
		delete(languages[0], "grammar")
		declaration["languages"], err = json.Marshal(languages)
		if err != nil {
			t.Fatal(err)
		}
		manifest, err = json.Marshal(declaration)
		if err != nil {
			t.Fatal(err)
		}
		grammarPath = "grammars/sample.first-line.json"
	}
	if _, err := pluginhost.Validate(t.Context(), kernel, manifest, pluginhost.Declared()); err != nil {
		t.Fatal(err)
	}
	grammar, err := os.ReadFile(contractfixture.Path("fixtures/languages/" + grammarPath))
	if err != nil {
		t.Fatal(err)
	}
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, id, "1.0.0")
	if err := os.MkdirAll(filepath.Join(installed, "grammars"), 0o700); err != nil {
		t.Fatal(err)
	}
	for path, contents := range map[string][]byte{
		"plugin.json": manifest,
		grammarPath:   grammar,
	} {
		if err := os.WriteFile(filepath.Join(installed, path), contents, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	settings := store.At(t.TempDir())
	if err := os.WriteFile(filepath.Join(settings.Dir(), settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(settings).SetEnabled(id, true); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{Kernel: kernel, PluginKernel: kernel, Store: settings, PluginRoot: pluginRoot})
	root := t.TempDir()
	h.open(root)
	h.app.reloadPluginLanguages()
	p := h.app.project
	start := "#!/usr/bin/env -S sample3"
	for _, tc := range []struct{ name, text, want string }{
		{"script", start + " -f\r\nvalue\r\n", "sample"},
		{"no-newline", start, "sample"},
		{"later-line", "\n" + start, ""},
		{"long-header", start + " " + strings.Repeat("x", 1024) + "\n", ""},
		{"typed.sample", "value", "sample"},
		{"main.go", start, "go"},
		{"Makefile", start, "makefile"},
		{"unmapped.ext", start, ""},
		{"script.sh", start, "shell"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(root, tc.name)
			if err := os.WriteFile(path, []byte(tc.text), 0o600); err != nil {
				t.Fatal(err)
			}
			h.app.openFile(p, path)
			h.settle()
			doc := p.docs.byPath(path)
			if doc == nil {
				t.Fatal("document did not open")
			}
			if doc.languageID != tc.want {
				t.Fatalf("language = %q, want %q", doc.languageID, tc.want)
			}
			if tc.name == "script" {
				doc.view.GoToLine(2)
				h.app.runLineOperation(p, doc, core.ToggleLineComment)
				h.settle()
				text := doc.view.TextSnapshot().String()
				if !strings.Contains(text, "// value") {
					t.Fatalf("edit did not use the resolved language's line comment: %q", text)
				}
			}
		})
	}
}
