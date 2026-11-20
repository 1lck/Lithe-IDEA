package workbench

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// fixtureEntrypointVariable tells the copied test binary it is the entrypoint a provider run
// started (TestFixtureEntrypointRunner).
const fixtureEntrypointVariable = "LITHE_FIXTURE_ENTRYPOINT"

// TestFixtureEntrypointRunner is the program the entrypoint fixture's prepared run starts: it
// prints the arguments it got and exits.
func TestFixtureEntrypointRunner(t *testing.T) {
	if os.Getenv(fixtureEntrypointVariable) == "" {
		t.Skip("not a fixture entrypoint run")
	}
	fmt.Println("entrypoint ran")
	os.Exit(0)
}

// providerEntrypointsManifest is the provider fixture with an entrypoint run (buildProviders 1).
var providerEntrypointsManifest = strings.Replace(strings.Replace(providerTestsManifest,
	`"requires": {"buildProviders": 0,`, `"requires": {"buildProviders": 1,`, 1),
	`"model": {"source": "provider"},`,
	`"model": {"source": "provider"},
    "run": [{"id": "main", "source": "provider", "name": "Main Class", "entrypoints": true}],`, 1)

// entrypointHarness installs the entrypoint provider fixture and puts the fixture build tool
// and the copied test binary, as fixture-service, on PATH.
func entrypointHarness(t *testing.T) *harness {
	t.Helper()
	return newHarnessWithOptions(t, entrypointOptions(t, "dark", "zh-Hans"))
}

// entrypointOptions are entrypointHarness's options in theme and language.
func entrypointOptions(t *testing.T, theme, language string) Options {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"`+theme+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.provider-tests", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(providerEntrypointsManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, filepath.Join(installed, "provider"))
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.provider-tests", true); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	tool, program := filepath.Join(bin, "fixture-tool"), filepath.Join(bin, "fixture-service")
	if runtime.GOOS == "windows" {
		tool, program = tool+".exe", program+".exe"
		t.Setenv("PATHEXT", ".EXE")
	}
	if err := writeFakeExecutable(tool); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, program)
	t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))
	return Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{language},
		// The provider is a copy of this large instrumented test binary: under load its start
		// can exceed Core's 10s default. The bound stays finite.
		PluginInitializeTimeout: 60 * time.Second,
	}
}

// entrypointWorkspace is the fixture workspace: src/Main.java holds the entrypoint the
// provider finds, src/Util.java none.
func entrypointWorkspace(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "EntrypointDemo")
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, marker := range []string{"fixture.marker", "entrypoints.marker"} {
		if err := os.WriteFile(filepath.Join(root, marker), []byte("fixture\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	sources := map[string]string{
		"Main.java": "package example;\n\npublic final class Main {\n    public static void main(String[] args) {\n        System.out.println(\"entrypoint ran\");\n    }\n}\n",
		"Util.java": "package example;\n\nfinal class Util {\n}\n",
	}
	for name, text := range sources {
		if err := os.WriteFile(filepath.Join(root, "src", name), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// Run on Current File asks the build provider for the open file's entrypoint, saves it as a
// local run configuration named after it, selects it in the title bar and starts it without a
// target, with the entrypoint as launchOptions.entrypoint. A file without an entrypoint says
// so, and running the entrypoint again reuses the saved configuration.
func TestRunOnCurrentFileStartsTheEntrypointAndSavesItsConfiguration(t *testing.T) {
	h := entrypointHarness(t)
	root := entrypointWorkspace(t)
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.loadTitleRunConfigs(p) })
	awaitStateWithin(t, h, time.Minute, "the provider model", func() bool {
		return len(p.build.instances) == 1 && p.build.instances[0].modelLoaded && p.runConfigsSettled()
	})
	if runs := p.build.instances[0].System.EntrypointRuns; len(runs) != 1 || runs[0].ID != "main" {
		t.Fatalf("entrypoint runs = %+v, want the declared main run", runs)
	}
	if len(p.runConfigs.list) != 0 {
		t.Fatalf("configurations = %+v, want none before a run: an entrypoint run lists nothing by itself", p.runConfigs.list)
	}

	notRunnable := i18n.Shared(h.app.language(), "desktop.title.currentFileNotRunnable")
	openSource(t, h, p, filepath.Join(root, "src", "Util.java"))
	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, "")
		a.titleRun(p)
	})
	awaitStateWithin(t, h, time.Minute, "the answer for a file without an entrypoint", func() bool {
		return slices.Contains(noticeTexts(h.app), notRunnable)
	})
	if len(p.runConfigs.list) != 0 || p.build.active() {
		t.Fatalf("a file without an entrypoint saved %+v or started a run", p.runConfigs.list)
	}

	openSource(t, h, p, filepath.Join(root, "src", "Main.java"))
	h.app.post(func(a *App) { a.titleRun(p) })
	first := awaitProcessRun(t, h, p, "Main", nil)
	if !strings.Contains(first.output.all(), "entrypoint ran") {
		t.Fatalf("console:\n%s", first.output.all())
	}
	if len(p.runConfigs.list) != 1 || p.runConfigs.currentFile || p.runConfigs.selected != p.runConfigs.list[0].ID {
		t.Fatalf("configurations = %+v selected %q current file %v, want the saved Main chosen", p.runConfigs.list, p.runConfigs.selected, p.runConfigs.currentFile)
	}
	saved := p.runConfigs.list[0]
	reference, ok := saved.BuildReference()
	if !ok || reference.Run != "main" || reference.TargetID != "" || saved.Name != "Main" {
		t.Fatalf("saved configuration = %+v reference %+v", saved, reference)
	}
	data, err := os.ReadFile(filepath.Join(root, "prepare-run.json"))
	if err != nil {
		t.Fatal(err)
	}
	var prepared struct {
		Target        json.RawMessage `json:"target"`
		LaunchOptions struct {
			Entrypoint string `json:"entrypoint"`
		} `json:"launchOptions"`
	}
	if err := json.Unmarshal(data, &prepared); err != nil {
		t.Fatal(err)
	}
	if prepared.LaunchOptions.Entrypoint != "example.Main" || (len(prepared.Target) != 0 && string(prepared.Target) != "null") {
		t.Fatalf("prepareRun params = %s, want the entrypoint and no target", data)
	}

	// Current File again finds the same entrypoint and reuses its configuration.
	h.app.post(func(a *App) {
		a.chooseTitleConfiguration(p, "")
		a.titleRun(p)
	})
	awaitProcessRun(t, h, p, "Main", first)
	if len(p.runConfigs.list) != 1 || p.runConfigs.list[0].ID != saved.ID {
		t.Fatalf("configurations = %+v, want the one saved Main", p.runConfigs.list)
	}
}

// openSource opens file in the editor and waits until it is the selected document, which Run
// on Current File reads.
func openSource(t *testing.T, h *harness, p *project, file string) {
	t.Helper()
	h.app.post(func(a *App) { a.openFileAtPosition(p, file, 0, 0) })
	awaitStateWithin(t, h, 10*time.Second, "the open "+filepath.Base(file), func() bool {
		doc := p.selectedDocument(p.docs.group)
		return doc != nil && doc.path == file
	})
}

func TestCurrentFileUsesAnEditorRunActionWithoutABuildEntrypoint(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	writeFixture(t, root, map[string]string{"source.txt": "entry\n"})
	h.open(root)
	p := h.app.project
	openSource(t, h, p, filepath.Join(root, "source.txt"))
	d := p.selectedDocument(p.docs.group)
	if d.view.Revision() != 0 {
		t.Fatalf("test needs the initial revision, got %d", d.view.Revision())
	}
	h.app.post(func(a *App) {
		p.build.loaded = true
		d.actions = []pluginservice.EditorAction{{
			Title: "Run editor entry", Icon: "run",
			Range: pluginservice.EditorActionRange{StartLine: 1, StartColumn: 1},
		}}
		a.chooseTitleConfiguration(p, "")
		a.titleRun(p)
	})
	h.settle()
	want := i18n.SharedFormat(h.app.language(), "desktop.editorActions.starting", map[string]string{"label": "Run editor entry"})
	if !slices.Contains(noticeTexts(h.app), want) {
		t.Fatalf("Run did not invoke the editor entry: notices = %v", noticeTexts(h.app))
	}
}
