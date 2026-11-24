//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

func TestVisualNavigationGutter(t *testing.T) {
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
				visualNavigationGutter(t, out, theme, language)
			})
		}
	}
}

func visualNavigationGutter(t *testing.T, out, theme, language string) {
	t.Helper()
	const source = `interface Greeter {
    String greet(String name);
}

class BaseGreeter {
    public String greet(String name) {
        return "Hello " + name;
    }
}

class CustomGreeter extends BaseGreeter implements Greeter {
    @Override
    public String greet(String name) {
        return "Hi, " + name;
    }
}
`
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "NavSample")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "CustomGreeter.java")
	implA := filepath.Join(root, "FormalGreeter.java")
	implB := filepath.Join(root, "FriendlyGreeter.java")
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{implA, implB} {
		if err := os.WriteFile(p, []byte("class Sample {}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
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
		t.Fatal("expected the synthetic Java document to open")
	}
	h.app.focusDocument(d.id)

	service, err := pluginservice.Open(kernel, prefs, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	const pluginID = "dev.lithe.test.visual-nav"
	tracker := pluginlsp.New(&closeRecordKernel{}, "visual-nav")
	uri := "file://" + filepath.ToSlash(path)
	if _, err := tracker.Open(t.Context(), pluginlsp.Document{URI: uri, LanguageID: "java", Text: source}); err != nil {
		t.Fatal(err)
	}
	server := &pluginServer{
		session: &pluginservice.LanguageSession{
			PluginID: pluginID, Session: pluginbackend.Session{ID: "visual-nav"}, Documents: tracker,
		},
		project: p, buildReady: true, cancel: func() {},
		features: map[string]bool{featureImplementation: true},
	}
	h.app.pluginServerMu.Lock()
	h.app.pluginServers = map[string]*pluginServer{pluginID: server}
	h.app.pluginServerLanguages = map[string]string{"java": pluginID}
	h.app.pluginServerMu.Unlock()
	d.languageID = "java"
	d.sync.opened, d.sync.pluginID, d.sync.uri = true, pluginID, uri

	h.app.post(func(a *App) {
		a.clearEditorActions(d)
		snapshot := editorActionSnapshot{documentID: d.id, version: d.view.Revision(), collection: d.actionCollection}
		actions := []pluginservice.EditorAction{
			{ID: "greeter-down", Title: "Implemented by CustomGreeter", Icon: "navigate-implemented", Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1, EndLine: 1, EndColumn: 18}},
			{ID: "base-down", Title: "Overridden by CustomGreeter", Icon: "navigate-overridden", Range: pluginservice.EditorActionRange{StartLine: 5, StartColumn: 1, EndLine: 5, EndColumn: 18}},
			{ID: "custom-up", Title: "Implements Greeter", Icon: "navigate-implementing", Range: pluginservice.EditorActionRange{StartLine: 11, StartColumn: 1, EndLine: 11, EndColumn: 20}},
			{ID: "method-up", Title: "Overrides BaseGreeter.greet()", Icon: "navigate-overriding", Range: pluginservice.EditorActionRange{StartLine: 13, StartColumn: 1, EndLine: 13, EndColumn: 20}},
			{ID: "method-down", Title: "Overridden by FormalGreeter", Icon: "navigate-overridden", Range: pluginservice.EditorActionRange{StartLine: 13, StartColumn: 1, EndLine: 13, EndColumn: 20}, Alternatives: []pluginservice.EditorActionChoice{{ID: "method-down-2", Title: "Overridden by FriendlyGreeter", Icon: "navigate-overridden"}}},
		}
		a.presentEditorActions(p, snapshot, actions, nil, nil)
	})

	paint := func() {
		h.app.invalidator.Invalidate()
		h.settleChain()
	}
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

	paint()
	picture("nav-gutter", "CustomGreeter.java")

	// Hover tooltip over the green I↓ icon on line 0.
	ifaceCell := findGutterIconCell(t, d, 0, 1)
	if err := h.driver.Move(ifaceCell.X+ifaceCell.Width/2, ifaceCell.Y+ifaceCell.Height/2); err != nil {
		t.Fatal(err)
	}
	paint()
	picture("nav-hover-tooltip", "Implemented by CustomGreeter")

	// Move off gutter icon and show multi-target implementations popup anchored at the dual-slot line.
	if err := h.driver.Leave(); err != nil {
		t.Fatal(err)
	}
	dualDownCell := findGutterIconCell(t, d, 12, 1)
	h.app.post(func(a *App) {
		a.presentDefinitionTargetsAt(p, d, pluginSemanticImplementation, []core.PluginSemanticLocation{
			{URI: "file://" + filepath.ToSlash(implA), FilePath: implA, Range: core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 6}}},
			{URI: "file://" + filepath.ToSlash(implB), FilePath: implB, Range: core.PluginDocumentRange{Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 6}}},
		}, 2, d.view.Revision(), &dualDownCell)
	})
	paint()
	picture("nav-implementations-popup", "FormalGreeter.java:1:7", "FriendlyGreeter.java:1:7")

	// Close popup and right-click on CustomGreeter.greet to inspect the context menu entries.
	h.app.post(func(a *App) { a.closeSemanticDefinition() })
	paint()
	methodPos := strings.Index(source, "greet(String name) {\n        return \"Hi")
	methodLine, methodCol := d.view.PositionOf(methodPos)
	d.view.GoToNavigation(methodLine, methodCol, false)
	paint()
	caret, ok := d.view.CaretRect()
	if !ok {
		t.Fatal("missing caret geometry on method line")
	}
	if err := h.driver.ClickButton(caret.X+2, caret.Y+caret.Height/2, gfx.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	paint()
	picture("nav-context-menu",
		h.shared("desktop.editorMenu.goToDefinition"),
		h.shared("desktop.editorMenu.goToImplementation"),
		h.shared("desktop.editorMenu.goToSuper"),
	)
}
