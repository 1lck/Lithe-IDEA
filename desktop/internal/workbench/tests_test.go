package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// testsPanelManifest is a declarative build system whose only purpose is a
// workspace test command. Core validates it, plans the command and decodes the
// JUnit report; the host only runs the plan and presents the decoded tree.
const testsPanelManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.tests-panel",
  "displayName": "Tests Panel Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build"],
  "activationEvents": ["onBuildSystem:fixture-tests"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-tests",
    "displayName": "Fixture Tests",
    "detection": {"markers": ["fixture.test"]},
    "invocation": {"executables": [{"kind": "projectFile", "path": "run-tests.exe"}]},
    "test": {
      "scopes": ["workspace"],
      "arguments": ["-test.run=^TestFixtureTestRunner$"],
      "results": {"decoder": "junitXml", "reports": ["reports/*.xml"]}
    }
  }]
}`

// TestFixtureTestRunner is the test process the fixture build system starts.
// The workbench copies the test binary into the fixture workspace and Core plans
// this test as the process arguments, so the whole run is a real process. Under
// an ordinary suite run the marker file is absent and the test skips.
func TestFixtureTestRunner(t *testing.T) {
	if _, err := os.Stat("fixture.test"); err != nil {
		t.Skip("not the fixture test workspace")
	}
	if _, err := os.Stat("block.marker"); err == nil {
		// This process exists so the host can stop it. The parent test waits on
		// the observable run state, never on this sleep.
		time.Sleep(10 * time.Minute)
		return
	}
	if err := os.MkdirAll("reports", 0o700); err != nil {
		t.Fatal(err)
	}
	report := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="FixtureSuite">
  <testcase classname="FixtureSuite" name="passes" time="0.010"/>
  <testcase classname="FixtureSuite" name="fails" time="0.020" file="tests/fixture_test.go" line="3">
    <failure message="expected 2, got 3">trace</failure>
  </testcase>
</testsuite>`
	if err := os.WriteFile(filepath.Join("reports", "fixture.xml"), []byte(report), 0o600); err != nil {
		t.Fatal(err)
	}
}

// testsHarness installs the fixture plugin into an isolated plugin root and
// marks it enabled without the user installation or trust flow.
func testsHarness(t *testing.T) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.tests-panel", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(testsPanelManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.tests-panel", true); err != nil {
		t.Fatal(err)
	}
	return newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"zh-Hans"},
	})
}

// installTestRunner links the running test binary into the fixture workspace.
// Invoking it with Core's planned -test.run argument starts the helper above.
func installTestRunner(t *testing.T, root string) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "run-tests.exe")
	if err := os.Symlink(executable, link); err != nil {
		// Windows without symlink permission: copy the binary and keep it
		// executable enough for the platform's process launcher.
		data, readErr := os.ReadFile(executable)
		if readErr != nil {
			t.Fatalf("symlink runner: %v; read runner: %v", err, readErr)
		}
		if writeErr := os.WriteFile(link, data, 0o755); writeErr != nil {
			t.Fatal(writeErr)
		}
	}
}

// openTestsPanel opens the project and the Tests tool window, then lets the
// detection and model steps chain until the panel has an instance.
func openTestsPanel(t *testing.T, h *harness, root string) *project {
	t.Helper()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemTests))
	for range 4 {
		h.settle()
	}
	p := h.app.project
	if p == nil {
		t.Fatal("the project did not open")
	}
	return p
}

// clickRun starts the fixture run through the real button. It does not wait
// for every task, because the blocking fixture stays running by design.
func clickRun(t *testing.T, h *harness) {
	t.Helper()
	at := center(h.pageHit(h.app.text.Tests.Run).Bounds)
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
}

// awaitTestRun pumps frames until the run finished, bounded by the deadline.
func awaitTestRun(t *testing.T, h *harness, p *project) {
	t.Helper()
	awaitStateWithin(t, h, 30*time.Second, "the test run to finish", func() bool {
		return !p.tests.running && (p.tests.hasResults || p.tests.failed != "")
	})
}

func TestTestsPanelRunsFixtureAndOpensFailureLocation(t *testing.T) {
	h := testsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.test"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tests", "fixture_test.go"), []byte("package fixture\n\nfunc TestFails() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	installTestRunner(t, root)
	p := openTestsPanel(t, h, root)
	if p.testInstance() == nil {
		t.Fatalf("the Tests panel did not detect the fixture instance: %+v", p.build.instances)
	}

	clickRun(t, h)
	awaitTestRun(t, h, p)
	if p.tests.failed != "" {
		t.Fatalf("the run failed: %s", p.tests.failed)
	}
	if !p.tests.hasResults || p.tests.verdict.Outcome != "testsFailed" {
		t.Fatalf("verdict = %+v, results = %+v, want testsFailed", p.tests.verdict, p.tests.results)
	}
	summary := p.tests.results.Summary
	if summary.Total != 2 || summary.Passed != 1 || summary.Failed != 1 {
		t.Fatalf("summary = %+v, want 2 total, 1 passed, 1 failed", summary)
	}
	if !h.shows("FixtureSuite") || !h.shows("fails") || !h.shows("expected 2, got 3") {
		t.Fatal("the result tree does not show the suite, case and failure message")
	}

	// Clicking the failing case opens its decoded source location.
	row := -1
	for index, spec := range p.tests.rows {
		if !spec.header && p.tests.results.Tests[spec.index].Case == "fails" {
			row = index
		}
	}
	if row < 0 {
		t.Fatal("the failing case has no row")
	}
	h.clickNamed(p.tests.results.Tests[p.tests.rows[row].index].Case)
	opened := filepath.Join(root, "tests", "fixture_test.go")
	if p.docs.byPath(opened) == nil {
		t.Fatalf("the failing case did not open %s", opened)
	}
}

func TestTestsPanelStopCancelsAndPublishesNoOutcome(t *testing.T) {
	h := testsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.test"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "block.marker"), []byte("block\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	installTestRunner(t, root)
	p := openTestsPanel(t, h, root)
	clickRun(t, h)
	awaitStateWithin(t, h, 20*time.Second, "the fixture run to start", func() bool {
		return p.tests.running && p.tests.operation != nil
	})
	stop := center(h.pageHit(h.app.text.Tests.Stop).Bounds)
	if err := h.driver.Click(stop.X, stop.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the stopped run to publish", func() bool {
		return !p.tests.running
	})
	if p.tests.verdict.Outcome != "cancelled" {
		t.Fatalf("verdict = %+v, want cancelled", p.tests.verdict)
	}
	if p.tests.hasResults {
		t.Fatal("a cancelled run claimed test results")
	}
	if !h.shows(h.app.text.Tests.Cancelled) {
		t.Fatal("the panel does not show the cancelled status")
	}
}

func TestTestsPanelCloseProjectStopsRun(t *testing.T) {
	h := testsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.test"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "block.marker"), []byte("block\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	installTestRunner(t, root)
	p := openTestsPanel(t, h, root)
	clickRun(t, h)
	awaitStateWithin(t, h, 20*time.Second, "the fixture run to start", func() bool {
		return p.tests.running
	})
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool {
		return h.app.project == nil
	})
	h.settle()
	if p.tests.running {
		t.Fatal("closing the project left the test run marked running")
	}
}

func TestTestsPanelWithoutTestPluginSaysSo(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.app.reduceChrome(core.ToggleChrome(itemTests))
	h.settle()
	if !h.shows("此工作区没有声明测试的构建系统。") {
		t.Fatal("the Tests panel did not explain that no build system declares tests")
	}
}

func TestTestsPanelDropsStaleResultAndBoundsOutput(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	p.tests.generation = 2
	p.tests.running = true

	// A result from generation 1 belongs to a replaced run and must not replace
	// the current state.
	h.app.finishTestRun(p, 1, testSelection{}, core.BuildTestResults{Summary: core.BuildTestSummary{Total: 1, Passed: 1}}, core.BuildTestTermination{Kind: "exited"})
	if p.tests.hasResults || !p.tests.running {
		t.Fatalf("a stale result changed the run state: %+v", p.tests)
	}

	p.tests.generation = 3
	h.app.appendTestOutput(p, 3, strings.Repeat("line\n", testOutputMaxLines+50))
	if len(p.tests.output) > testOutputMaxLines {
		t.Fatalf("output has %d lines, want at most %d", len(p.tests.output), testOutputMaxLines)
	}
	if p.tests.outputBytes > testOutputBytes {
		t.Fatalf("output has %d bytes, want at most %d", p.tests.outputBytes, testOutputBytes)
	}
}

func TestFlattenTestRowsIsBounded(t *testing.T) {
	results := core.BuildTestResults{Tests: make([]core.BuildTestCase, testMaxRows+50)}
	for index := range results.Tests {
		results.Tests[index] = core.BuildTestCase{Suite: "Suite", Case: "case", Status: "passed"}
	}
	rows := flattenTestRows(results)
	if len(rows) > testMaxRows {
		t.Fatalf("rows = %d, want at most %d", len(rows), testMaxRows)
	}
	if len(rows) == 0 || !rows[0].header || rows[0].suite != "Suite" {
		t.Fatalf("first row = %+v, want the suite header", rows[0])
	}
}
