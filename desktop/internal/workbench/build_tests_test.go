package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// providerDiscoveryManifest is the provider fixture declaring project and target tests, the
// suite and case filters a discovered test needs, and discovery.
func providerDiscoveryManifest(t *testing.T) string {
	t.Helper()
	const scopes = `"scopes": ["workspace"],`
	if !strings.Contains(providerTestsManifest, scopes) {
		t.Fatal("the provider fixture no longer declares its test scopes")
	}
	return strings.Replace(providerTestsManifest, scopes, `"scopes": ["workspace", "project", "target"],
      "targetTags": ["test"],
      "filters": ["suite", "case"],
      "discovery": true,`, 1)
}

// providerTestRequest is the lithe/build/test request the fixture provider received last.
type providerTestRequest struct {
	Project *core.BuildSelection `json:"project"`
	Target  *core.BuildSelection `json:"target"`
	Suite   string               `json:"suite"`
	Case    string               `json:"case"`
}

func readProviderTestRequest(t *testing.T, root string) providerTestRequest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, "test-request.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "test-request.json")); err != nil {
		t.Fatal(err)
	}
	var request providerTestRequest
	if err := json.Unmarshal(data, &request); err != nil {
		t.Fatal(err)
	}
	return request
}

// hasPopupItem reports whether the open menu has an item with label.
func (h *harness) hasPopupItem(label string) bool {
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel {
			return true
		}
	}
	return false
}

// The Build tool window runs the tests of a project and of a target the declaration accepts,
// discovers tests through the provider and runs one alone; each run shows in the Tests tool
// window, whose Rerun repeats the selection and whose Run All Tests widens it again. A saved
// source file revokes the discovered list.
func TestBuildWindowRunsProjectTargetAndDiscoveredTests(t *testing.T) {
	h := providerTestsHarnessWith(t, providerDiscoveryManifest(t))
	root := t.TempDir()
	for _, marker := range []string{"fixture.marker", "discovery.marker"} {
		if err := os.WriteFile(filepath.Join(root, marker), []byte("fixture\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "lib"), 0o700); err != nil {
		t.Fatal(err)
	}
	// The host resolves the provider's build tool before it starts the provider; the fixture
	// provider never runs it.
	bin := t.TempDir()
	tool := filepath.Join(bin, "fixture-tool")
	if runtime.GOOS == "windows" {
		tool += ".exe"
		t.Setenv("PATHEXT", ".EXE")
	}
	if err := writeFakeExecutable(tool); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))
	h.open(root)
	p := h.app.project
	if p == nil {
		t.Fatal("the project did not open")
	}
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	showBuild := func() {
		t.Helper()
		if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
			h.app.reduceChrome(core.ToggleChrome(itemRun))
		}
		h.app.invalidator.Invalidate()
		h.settle()
		h.settle()
	}
	showBuild()
	awaitStateWithin(t, h, 60*time.Second, "the provider model", func() bool {
		instance := p.selectedBuildInstance()
		return instance != nil && instance.modelLoaded && len(instance.Model.Targets) == 2
	})
	showBuild()
	finished := func(what string) {
		t.Helper()
		awaitStateWithin(t, h, 60*time.Second, what, func() bool {
			return !p.tests.running && (p.tests.hasResults || p.tests.failed != "")
		})
		if p.tests.failed != "" {
			t.Fatalf("%s failed: %s", what, p.tests.failed)
		}
		if p.tests.verdict.Outcome != "passed" {
			t.Fatalf("%s verdict = %+v", what, p.tests.verdict)
		}
		if !h.app.chrome.isOpen(catalogIndex[itemTests]) {
			t.Fatalf("%s did not show the Tests tool window", what)
		}
	}
	runTests := i18n.Shared(h.app.language(), "native.runTests")

	// A project runs its own tests.
	h.rightClickAt(h.labelBounds("library"))
	h.click(center(h.popupHit(runTests)))
	finished("the project run")
	if request := readProviderTestRequest(t, root); request.Project == nil || request.Project.Name != "library" || request.Target != nil || request.Suite != "" {
		t.Fatalf("project run request = %+v", request)
	}

	// A target carrying a declared tag runs with its project; one without it has no entry.
	showBuild()
	h.rightClickAt(h.labelBounds("libapp"))
	if h.hasPopupItem(runTests) {
		t.Fatal("a target without a declared test tag offers Run Tests")
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.rightClickAt(h.labelBounds("libtests"))
	h.click(center(h.popupHit(runTests)))
	finished("the target run")
	if request := readProviderTestRequest(t, root); request.Target == nil || request.Target.Name != "libtests" || request.Project == nil || request.Project.Name != "library" {
		t.Fatalf("target run request = %+v", request)
	}

	// Discovery runs when asked and lists the provider's tests; one runs alone.
	showBuild()
	h.clickNamed(i18n.Shared(h.app.language(), "native.discoverTests"))
	awaitStateWithin(t, h, 60*time.Second, "the discovered tests", func() bool {
		tests := p.build.discovered[p.selectedBuildInstance().ID]
		return tests != nil && !tests.loading && (tests.loaded || tests.failed != "")
	})
	tests := p.build.discovered[p.selectedBuildInstance().ID]
	if tests.failed != "" || len(tests.tests) != 2 {
		t.Fatalf("discovery = %+v", tests)
	}
	h.app.invalidator.Invalidate()
	h.settle()
	label := h.labelBounds("LibSuite · libPasses")
	if label == (gfx.Rect{}) {
		t.Fatal("the discovered test has no row")
	}
	at := center(label)
	if err := h.driver.DoubleClick(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	finished("the discovered test run")
	request := readProviderTestRequest(t, root)
	if request.Suite != "LibSuite" || request.Case != "libPasses" || request.Project == nil || request.Project.Path != "lib" {
		t.Fatalf("discovered test request = %+v", request)
	}

	// Rerun repeats the single test; Run All Tests widens to the workspace.
	h.clickNamed(h.app.text.Tests.Rerun)
	finished("the rerun")
	if again := readProviderTestRequest(t, root); again.Suite != "LibSuite" || again.Case != "libPasses" {
		t.Fatalf("rerun request = %+v", again)
	}
	h.clickNamed(h.app.text.Tests.RunAll)
	finished("the workspace run")
	if all := readProviderTestRequest(t, root); all.Project != nil || all.Target != nil || all.Suite != "" {
		t.Fatalf("workspace run request = %+v", all)
	}
	if p.tests.last == nil || p.tests.last.scope() != "workspace" {
		t.Fatalf("last selection = %+v", p.tests.last)
	}

	// Saving a source file inside the build directory revokes the discovered list.
	source := filepath.Join(root, "lib", "source.txt")
	if err := os.WriteFile(source, []byte("source\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openFile(p, source)
	h.settle()
	doc := p.docs.byPath(source)
	if doc == nil {
		t.Fatalf("the source file did not open: %q", h.app.notice)
	}
	h.app.insertForTest(doc, "edit ")
	h.app.saveDocument(p, doc.id)
	awaitStateWithin(t, h, 30*time.Second, "the revoked discovery", func() bool {
		return p.build.discovered[p.selectedBuildInstance().ID] == nil
	})
}
