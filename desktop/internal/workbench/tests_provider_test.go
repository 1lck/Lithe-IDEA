package workbench

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// providerTestsManifest is a build system whose tests and model are answered by
// its own provider process. Core still plans the test request and decodes the
// canonical report; the host only starts the provider and routes frames.
const providerTestsManifest = `{
  "schemaVersion": 2,
  "id": "dev.lithe.test.provider-tests",
  "displayName": "Provider Tests Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 3,
  "requires": {"buildProviders": 8, "buildSystems": 1, "serverProcess": 1},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["languageServer.launch", "process.build"],
  "activationEvents": ["onBuildSystem:fixture-provider-tests"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-provider-tests",
    "displayName": "Provider Tests",
    "detection": {"markers": ["fixture.marker"]},
    "invocation": {"executables": [{"kind": "command", "command": "fixture-tool"}]},
    "provider": {
      "launch": {"kind": "packaged", "path": "provider"},
      "arguments": ["-test.run=^TestProviderTestRunner$"],
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "model": {"source": "provider"},
    "test": {
      "source": "provider",
      "scopes": ["workspace"],
      "arguments": [],
      "results": {"decoder": "provider"}
    }
  }]
}`

// TestProviderTestRunner is the fixture provider process. It is the copied test
// binary started by the host with the manifest's -test.run argument; the marker
// in its working directory is what tells it apart from an ordinary suite run.
func TestProviderTestRunner(t *testing.T) {
	if _, err := os.Stat("fixture.marker"); err != nil {
		t.Skip("not the provider fixture workspace")
	}
	blocked := false
	if _, err := os.Stat("block.marker"); err == nil {
		blocked = true
	}
	reader := bufio.NewReader(os.Stdin)
	write := func(value any) {
		body, err := json.Marshal(value)
		if err != nil {
			os.Exit(2)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(3)
		}
	}
	reply := func(id json.RawMessage, result any) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	fail := func(id json.RawMessage, code int, message string) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
	}
	notify := func(method string, params any) {
		write(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
	}
	var pending json.RawMessage
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				os.Exit(0)
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					os.Exit(4)
				}
			}
		}
		if length < 0 || length > 1<<20 {
			os.Exit(5)
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			os.Exit(6)
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			os.Exit(7)
		}
		if len(request.ID) == 0 {
			if request.Method == "$/cancelRequest" && len(pending) != 0 {
				fail(pending, -32800, "Request cancelled")
				pending = nil
			}
			continue
		}
		switch request.Method {
		case "initialize":
			experimental := map[string]any{"litheBuild": map[string]any{"version": 8}}
			if _, err := os.Stat("settings-action.marker"); err == nil {
				experimental["litheFunctions"] = map[string]any{"version": 2, "functions": []any{map[string]any{"id": "snapshot.refresh"}}}
			}
			reply(request.ID, map[string]any{"capabilities": map[string]any{"experimental": experimental}})
		case "lithe/function/invoke":
			if err := os.WriteFile("action-invoked.marker", []byte("called"), 0o600); err != nil {
				os.Exit(8)
			}
			if _, err := os.Stat("block-action.marker"); err == nil {
				pending = request.ID
				continue
			}
			reply(request.ID, map[string]any{"value": "fixture action completed"})
		case "lithe/build/model":
			reply(request.ID, map[string]any{
				"format":   "litheBuildModel",
				"version":  1,
				"projects": []any{map[string]any{"path": ".", "name": "fixture"}},
			})
		case "lithe/build/test":
			if blocked {
				// The host's cancel notification ends this request; the parent
				// test waits on the published run state, not on a timer.
				pending = request.ID
				continue
			}
			notify("lithe/build/progress", map[string]any{
				"operationID": request.ID,
				"message":     "running provider tests",
				"output":      "provider output\n",
			})
			reply(request.ID, map[string]any{
				"exitCode": 1,
				"output":   "provider output\n",
				"testResults": map[string]any{
					"format":  "litheTestResults",
					"version": 1,
					"tests": []any{
						map[string]any{"suite": "ProviderSuite", "case": "providerPasses", "status": "passed"},
						map[string]any{
							"suite": "ProviderSuite", "case": "providerFails", "status": "failed",
							"message": "provider failure", "path": "tests/provider_test.go", "line": 5,
						},
					},
				},
			})
		case "shutdown":
			reply(request.ID, nil)
		case "exit":
			os.Exit(0)
		default:
			reply(request.ID, nil)
		}
	}
}

// providerTestsHarness installs the provider plugin package with the running
// test binary as its packaged provider executable.
func providerTestsHarness(t *testing.T, supplied ...pluginservice.Kernel) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.provider-tests", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(providerTestsManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(filepath.Join(installed, "provider"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	_, copyErr := io.Copy(target, source)
	closeTargetErr := target.Close()
	closeSourceErr := source.Close()
	if copyErr != nil || closeTargetErr != nil || closeSourceErr != nil {
		t.Fatalf("copy provider: %v, close: %v, %v", copyErr, closeTargetErr, closeSourceErr)
	}
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.provider-tests", true); err != nil {
		t.Fatal(err)
	}
	var backendKernel pluginservice.Kernel = &testKernel{Client: core.NewClient()}
	if len(supplied) > 0 {
		backendKernel = supplied[0]
	}
	return newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: backendKernel,
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"zh-Hans"},
	})
}

func TestTestsPanelProviderRunPublishesDecodedResults(t *testing.T) {
	h := providerTestsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.marker"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tests", "provider_test.go"), []byte("package tests\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openTestsPanel(t, h, root)
	if p.testInstance() == nil || p.testInstance().System.Provider == false {
		t.Fatalf("the provider instance was not detected: %+v", p.build.instances)
	}

	clickRun(t, h)
	awaitTestRun(t, h, p)
	if p.tests.failed != "" {
		t.Fatalf("the provider run failed: %s", p.tests.failed)
	}
	if !p.tests.hasResults || p.tests.verdict.Outcome != "testsFailed" {
		t.Fatalf("verdict = %+v, results = %+v, want testsFailed from provider results", p.tests.verdict, p.tests.results)
	}
	summary := p.tests.results.Summary
	if summary.Total != 2 || summary.Passed != 1 || summary.Failed != 1 {
		t.Fatalf("summary = %+v, want provider's 2 total, 1 passed, 1 failed", summary)
	}
	if !h.shows("ProviderSuite") || !h.shows("providerFails") || !h.shows("provider failure") {
		t.Fatal("the result tree does not show the provider's decoded suite, case and message")
	}
	row := -1
	for index, spec := range p.tests.rows {
		if !spec.header && p.tests.results.Tests[spec.index].Case == "providerFails" {
			row = index
		}
	}
	if row < 0 {
		t.Fatal("the provider's failing case has no row")
	}
	h.clickNamed(p.tests.results.Tests[p.tests.rows[row].index].Case)
	opened := filepath.Join(root, "tests", "provider_test.go")
	if p.docs.byPath(opened) == nil {
		t.Fatalf("the provider failure did not open %s", opened)
	}
}

func TestTestsPanelProviderStopCancels(t *testing.T) {
	h := providerTestsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.marker"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "block.marker"), []byte("block\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openTestsPanel(t, h, root)
	clickRun(t, h)
	awaitStateWithin(t, h, 20*time.Second, "the provider test to start", func() bool {
		return p.tests.running && p.tests.operation != nil
	})
	stop := center(h.pageHit(h.app.text.Tests.Stop).Bounds)
	if err := h.driver.Click(stop.X, stop.Y); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, 20*time.Second, "the cancelled provider run to publish", func() bool {
		return !p.tests.running
	})
	if p.tests.verdict.Outcome != "cancelled" {
		t.Fatalf("verdict = %+v, want cancelled", p.tests.verdict)
	}
	if p.tests.hasResults {
		t.Fatal("a cancelled provider run claimed test results")
	}
}

func TestTestsPanelProviderCloseProjectStops(t *testing.T) {
	h := providerTestsHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.marker"), []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "block.marker"), []byte("block\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openTestsPanel(t, h, root)
	clickRun(t, h)
	awaitStateWithin(t, h, 20*time.Second, "the provider test to start", func() bool {
		return p.tests.running && p.tests.operation != nil
	})
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool {
		return h.app.project == nil
	})
	h.settle()
	if p.tests.running {
		t.Fatal("closing the project left the provider run marked running")
	}
}
