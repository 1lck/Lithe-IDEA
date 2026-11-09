package workbench

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// debugFixtureManifest declares one packaged stdio debug adapter. Core still
// validates the manifest; the host only resolves and starts the process.
const debugFixtureManifest = `{
  "schemaVersion": 2,
  "id": "dev.lithe.test.debug-adapter",
  "displayName": "Debug Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 4,
  "requires": {"debugAdapters": 1, "serverProcess": 1},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["debug.launch"],
  "activationEvents": ["onDebug:fixture"],
  "languages": [],
  "debugAdapters": [{
    "id": "fixture",
    "displayName": "Fixture DAP",
    "adapterID": "fixture-dap",
    "requests": ["launch"],
    "launch": {
      "process": {
        "launch": {"kind": "packaged", "path": "adapter"},
        "arguments": ["-test.run=^TestDebugAdapterRunner$"]
      },
      "transport": "stdio"
    }
  }]
}`

// debugHarness installs the fixture adapter package and its copied test
// binary. Every run below uses the real adapter process and the real Core
// session; nothing is replaced by a fake DAP implementation.
func debugHarness(t *testing.T) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.debug-adapter", "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(debugFixtureManifest), 0o600); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, filepath.Join(installed, "adapter"))
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.debug-adapter", true); err != nil {
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

func openDebugPanel(t *testing.T, h *harness, root string) *project {
	t.Helper()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	for range 4 {
		h.settle()
	}
	p := h.app.project
	if p == nil {
		t.Fatal("the project did not open")
	}
	if len(p.debug.adapters) != 1 {
		t.Fatalf("adapters = %+v, want the fixture adapter", p.debug.adapters)
	}
	return p
}

func TestDebugPanelBreakpointPauseContinueFrames(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "tests", "debug_source.go")
	if err := os.WriteFile(source, []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.openFileAtPosition(p, source, 2, 0)
	h.settle()

	h.click(center(h.hit(debugToggleBreakpointID)))
	if lines := p.debug.breakpoints[source]; len(lines) != 1 || lines[0] != 3 {
		t.Fatalf("breakpoints = %+v, want line 3 of %s", p.debug.breakpoints, source)
	}

	h.click(center(h.hit(debugStartID)))
	awaitStateWithin(t, h, 30*time.Second, "the paused debuggee and its stack", func() bool {
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
	if !h.shows("main") || !h.shows("worker") {
		t.Fatal("the Debug panel does not show the adapter's stack frames")
	}
	frames := p.debug.frames
	if frames[0].Line != 3 || frames[1].Line != 8 {
		t.Fatalf("frames = %+v, want the adapter's one-based lines", frames)
	}

	h.click(center(h.hit(debugContinueID)))
	awaitStateWithin(t, h, 20*time.Second, "the continued session", func() bool {
		return p.debug.state == "running" && len(p.debug.frames) == 0
	})
	h.click(center(h.hit(debugPauseID)))
	awaitStateWithin(t, h, 20*time.Second, "the paused session", func() bool {
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})

	h.click(center(h.hit(debugStopID)))
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool {
		return p.debug.session == nil && p.debug.state == "idle"
	})
}

func TestDebugPanelCloseProjectStopsSession(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.click(center(h.hit(debugStartID)))
	awaitStateWithin(t, h, 30*time.Second, "the paused session", func() bool {
		return p.debug.state == "paused"
	})
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool {
		return h.app.project == nil
	})
	if p.debug.session != nil || len(p.debug.frames) != 0 {
		t.Fatalf("closing the project kept debug state: %+v", p.debug)
	}
	h.settle()
}

func TestDebugPanelWithoutAdaptersSaysSo(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	h.settle()
	h.settle()
	if !h.shows("已安装的插件没有声明 stdio 调试适配器。") {
		t.Fatal("the Debug panel did not explain that no adapter is installed")
	}
}

func TestDebugLateErrorDoesNotChangeReplacementSession(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	old := &debugSession{generation: 1}
	current := &debugSession{generation: 2}
	p.debug.session = current
	defer func() { p.debug.session = nil }()
	p.debug.generation = 2
	p.debug.status = "current"
	h.app.finishDebugError(p, old, errors.New("old failure"))
	if p.debug.failure != "" || p.debug.status != "current" {
		t.Fatalf("old session changed replacement: failure=%q status=%q", p.debug.failure, p.debug.status)
	}
	p.debug.session = nil
}

func TestDebugPanelAdapterExitWithoutTerminated(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("exit"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.startDebug(p)
	awaitStateWithin(t, h, 5*time.Second, "adapter exit to release session", func() bool { return p.debug.session == nil })
}

// delayedDebugCreate models a Core call already in flight when Stop is pressed.
// Returning success after cancellation proves destruction is ordered after creation.
type delayedDebugCreate struct {
	Kernel
	entered   chan struct{}
	release   chan struct{}
	destroyed chan string
}

func (k *delayedDebugCreate) CreateDebugSession(_ context.Context, r core.DebugCreateSessionRequest) (core.DebugUpdate, error) {
	close(k.entered)
	select {
	case <-k.release:
	case <-time.After(5 * time.Second):
		return core.DebugUpdate{}, context.DeadlineExceeded
	}
	return k.Kernel.CreateDebugSession(context.Background(), r)
}

func (k *delayedDebugCreate) DestroyDebugSession(ctx context.Context, id string) ([]string, error) {
	children, err := k.Kernel.DestroyDebugSession(ctx, id)
	k.destroyed <- id
	return children, err
}

func TestDebugStopBeforeCreateReturnsDestroysLateSession(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	gate := &delayedDebugCreate{Kernel: h.app.kernel, entered: make(chan struct{}), release: make(chan struct{}), destroyed: make(chan string, 4)}
	h.app.kernel = gate
	var once sync.Once
	release := func() { once.Do(func() { close(gate.release) }) }
	defer release()
	h.app.startDebug(p)
	session := p.debug.session
	select {
	case <-gate.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("create did not start")
	}
	h.app.stopDebug(p)
	select {
	case <-gate.destroyed:
		t.Fatal("destroy ran before in-flight create finished")
	default:
	}
	release()
	h.settle()
	select {
	case id := <-gate.destroyed:
		if id != session.id {
			t.Fatal("destroyed wrong session")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("late session not destroyed")
	}
	// A real Core receive must now reject the removed ID.
	if _, err := gate.Kernel.ReceiveDebug(context.Background(), session.id, []byte("x")); err == nil {
		t.Fatal("Core session survived Stop")
	}
}

func TestDebugBlockedWriteEndsOnCancellation(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	session := &debugSession{stdin: writer, ctx: ctx}
	started := make(chan struct{})
	finished := make(chan error, 1)
	go func() {
		close(started)
		finished <- session.writeFrames([]string{base64.StdEncoding.EncodeToString(make([]byte, 1<<20))})
	}()
	<-started
	cancel()
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("cancelled write succeeded without a reader")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("write did not unblock on cancellation")
	}
}
