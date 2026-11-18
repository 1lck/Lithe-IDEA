//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

func TestVisualLSPActions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"en", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				visualLSPActions(t, out, theme, language)
			})
		}
	}
}

func visualLSPActions(t *testing.T, out, theme, language string) {
	t.Helper()
	const source = `package main

import "fmt"

func greet(name string, count int) string {
    return fmt.Sprintf("%s (%d)", name, count)
}

func main() {
    message := greet("Lithe", 3)
    fmt.Println(message)
}
`
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "Greeting")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "main.go")
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	var session *headless.Session
	kernel := &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
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
		t.Fatal("expected the synthetic editor document to open")
	}
	h.app.focusDocument(d.id)
	nameAt := strings.Index(source, `"Lithe", 3`)
	countAt := nameAt + len(`"Lithe", `)
	d.view.SetSelection(countAt, countAt)
	line, column := d.view.CaretUTF16()
	picture := func(scene string, labels ...string) {
		t.Helper()
		for _, label := range labels {
			if !h.shows(label) {
				t.Fatalf("%s did not paint %q", scene, label)
			}
		}
		if err := session.Screenshot(filepath.Join(out, scene+"-"+theme+"-"+language+".png")); err != nil {
			t.Fatal(err)
		}
	}
	paint := func() {
		h.app.invalidator.Invalidate()
		h.settleChain()
	}

	paint()
	picture("editor-before", "main.go")

	// Register a ready synthetic session without a server process. These
	// captures use canned Core results; protocol behavior is tested separately.
	service, err := pluginservice.Open(kernel, prefs, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	const pluginID = "dev.lithe.test.visual-lsp"
	tracker := pluginlsp.New(&closeRecordKernel{}, "visual-lsp")
	uri := "file://" + filepath.ToSlash(path)
	if _, err := tracker.Open(t.Context(), pluginlsp.Document{URI: uri, LanguageID: "visual-lsp", Text: source}); err != nil {
		t.Fatal(err)
	}
	h.app.pluginServerMu.Lock()
	h.app.pluginServers = map[string]*pluginServer{pluginID: {
		session: &pluginservice.LanguageSession{
			PluginID: pluginID, Session: pluginbackend.Session{ID: "visual-lsp"}, Documents: tracker,
		},
		project: p, buildReady: true, cancel: func() {},
		features: map[string]bool{featureCodeActions: true, featureInlayHints: true},
	}}
	h.app.pluginServerLanguages = map[string]string{"visual-lsp": pluginID}
	h.app.pluginServerMu.Unlock()
	d.languageID = "visual-lsp"
	d.sync.opened, d.sync.pluginID, d.sync.uri = true, pluginID, uri
	d.inlay.initialized = true
	d.inlay.revision = d.view.Revision()
	d.inlay.coveredEnd = d.view.TextSnapshot().LineCount() - 1
	h.app.semantics.project = p

	h.app.storeRawPluginDiagnostics(pluginID, path, []core.PluginDiagnostic{{
		Message: "Choose an intention for this call",
		Range: core.PluginDiagnosticRange{
			Start: core.PluginDiagnosticPosition{Line: line, UTF16Column: column},
			End:   core.PluginDiagnosticPosition{Line: line, UTF16Column: column + 1},
		},
	}})
	h.app.semantics.codeActions = codeActionsState{
		open: true, documentID: d.id, revision: d.view.Revision(),
		actions: []core.PluginSemanticCodeAction{
			{Title: "Extract greeting count to a constant", Group: "quickfix", IsPreferred: true},
			{Title: "Inline the message variable", Group: "refactor"},
			{Title: "Extract a greeting helper", Group: "refactor"},
			{Title: "Move greeting to a separate file", Group: "refactor"},
			{Title: "Convert to a named return value", Group: "refactor"},
			{Title: "Organize imports", Group: "source"},
			{Title: "Add a documentation comment", Group: "source"},
			{Title: "Add a test for the greeting", Group: "source"},
			{Title: "Update related call sites", Group: "other"},
			{Title: "Sort declarations", Group: "source"},
			{Title: "Inline greeting formatting", Group: "refactor"},
			{Title: "Replace string formatting with a helper", Group: "refactor"},
		},
	}
	paint()
	caret, ok := d.view.CaretRect()
	if !ok {
		t.Fatal("missing caret geometry for code actions")
	}
	actionLabel := h.shared("desktop.semantics.codeActions")
	foundGutterAction := false
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Role != gfx.RoleButton || hit.Label != actionLabel {
			continue
		}
		center := hit.Bounds.Y + hit.Bounds.Height/2
		if center < caret.Y || center >= caret.Y+caret.Height || hit.Bounds.X >= caret.X {
			t.Fatalf("code action button is outside the caret row's gutter: button %+v, caret %+v", hit.Bounds, caret)
		}
		foundGutterAction = true
	}
	if !foundGutterAction {
		t.Fatal("missing code action button in the editor gutter")
	}
	picture("code-actions", "Extract greeting count to a constant", h.shared("desktop.semantics.codeActionPreferred"))

	h.app.semantics.codeActions = codeActionsState{}
	const signature = "greet(name string, count int) string"
	const parameter = "count int"
	start := strings.Index(signature, parameter)
	end := start + len(parameter)
	active := 0
	paramDoc := "How many greetings to format."
	sigDoc := "Formats a greeting and its repetition count."
	h.app.semantics.signatureHelp = signatureHelpState{
		open: true, documentID: d.id, revision: d.view.Revision(), line: line, column: column,
		help: &core.PluginSemanticSignatureHelp{
			ActiveParameter: &active,
			Signatures: []core.PluginSemanticSignatureInfo{
				{Label: signature, Documentation: &sigDoc, Parameters: []core.PluginSemanticParameterInfo{
					{Label: parameter, ByteStart: &start, ByteEnd: &end, Documentation: &paramDoc},
				}},
				{Label: "greet(name string) string"},
			},
		},
	}
	paint()
	picture("signature-help", parameter, paramDoc)

	h.app.semantics.signatureHelp = signatureHelpState{}
	h.app.editorPreferences.InlayHints = true
	_, nameColumn := d.view.PositionOf(nameAt)
	const nameHint = "name:"
	const countHint = "count:"
	tip := "The name to include in the greeting."
	position := core.PluginDocumentPosition{Line: line, UTF16Column: nameColumn}
	d.inlay.hints = []core.PluginSemanticInlayHint{
		{Position: position, Label: nameHint, Tooltip: &tip, PaddingRight: true, TextEdits: []core.PluginTextEdit{
			{Range: core.PluginDocumentRange{Start: position, End: position}, NewText: "/* name */ "},
		}},
		{Position: core.PluginDocumentPosition{Line: line, UTF16Column: column}, Label: countHint, PaddingRight: true},
	}
	prepared, err := editorview.PrepareInlayHints(t.Context(), d.view.TextSnapshot(), d.view.Revision(), []editorview.InlayHintSpec{
		{ID: 0, Line: line, UTF16Column: nameColumn, Label: nameHint, PaddingRight: true, Interactive: true},
		{ID: 1, Line: line, UTF16Column: column, Label: countHint, PaddingRight: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !d.view.SetPreparedInlayHints(prepared) {
		t.Fatal("the visual editor did not accept its hints")
	}
	paint()
	for _, label := range session.Snapshot().Texts {
		if label.Value != nameHint {
			continue
		}
		x, y := label.Bounds.X+1, label.Bounds.Y+1
		if err := h.driver.Move(x, y); err != nil {
			t.Fatal(err)
		}
		break
	}
	picture("inlay-hints", nameHint, countHint, tip, h.shared("desktop.semantics.inlayHintApply"))
}
