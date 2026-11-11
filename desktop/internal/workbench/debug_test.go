package workbench

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
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
    "configurations": {"launch":{"arguments":{"stopOnEntry":true}}},
    "launch": {
      "process": {
        "launch": {"kind": "packaged", "path": "adapter"},
        "arguments": ["-test.run=^TestDebugAdapterRunner$"]
      },
      "transport": "stdio"
    }
  }]
}`

func debugFixtureProgramName() string {
	if runtime.GOOS == "windows" {
		return "adapter.exe"
	}
	return "adapter"
}

// debugHarness installs the fixture adapter package and its copied test
// binary. Every run below uses the real adapter process and the real Core
// session; nothing is replaced by a fake DAP implementation.
func debugHarness(t *testing.T) *harness {
	t.Helper()
	return debugHarnessWith(t, debugFixtureManifest)
}

// debugHarnessWith is debugHarness with another manifest for the fixture package.
func debugHarnessWith(t *testing.T, manifest string) *harness {
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
	if runtime.GOOS == "windows" {
		manifest = strings.ReplaceAll(manifest, `"path": "adapter"`, `"path": "adapter.exe"`)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, filepath.Join(installed, debugFixtureProgramName()))
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

	h.clickNamed(h.app.text.Debug.ToggleBreakpoint)
	if lines := p.debug.breakpoints[source]; len(lines) != 1 || lines[0].line != 3 {
		t.Fatalf("breakpoints = %+v, want line 3 of %s", p.debug.breakpoints, source)
	}

	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused debuggee and its stack", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
	if !h.shows("main") || !h.shows("worker") {
		t.Fatal("the Debug panel does not show the adapter's stack frames")
	}
	frames := p.debug.frames
	if frames[0].Line != 3 || frames[1].Line != 8 {
		t.Fatalf("frames = %+v, want the adapter's one-based lines", frames)
	}

	h.clickNamed(h.app.text.Debug.Continue)
	awaitStateWithin(t, h, 20*time.Second, "the continued session", func() bool {
		return p.debug.state == "running" && len(p.debug.frames) == 0
	})
	h.clickNamed(h.app.text.Debug.Pause)
	awaitStateWithin(t, h, 20*time.Second, "the paused session", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})

	h.clickNamed(h.app.text.Debug.Stop)
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
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused session", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
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
	if !h.shows("已安装的插件没有声明此客户端能启动的调试适配器。") {
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

// Stepping before the stack of the previous stop arrived makes Core refuse that late
// reply as stale. The new stop inspects again, so the panel shows no failure.
func TestDebugStaleInspectionIsNotAFailure(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	session := &debugSession{generation: 1}
	p.debug.session, p.debug.generation = session, 1
	defer func() { p.debug.session = nil }()
	h.app.applyDebugUpdate(p, session, core.DebugUpdate{State: "running", Events: []core.DebugEvent{
		{Type: "operationFailed", OperationID: "stack-1", Command: "stackTrace", Code: debugStaleReference, Message: "The debuggee resumed or stopped again before the adapter replied."},
	}})
	if p.debug.failure != "" {
		t.Fatalf("a stale inspection was shown as a failure: %q", p.debug.failure)
	}
	h.app.applyDebugUpdate(p, session, core.DebugUpdate{State: "paused", Events: []core.DebugEvent{
		{Type: "operationFailed", OperationID: "stack-2", Command: "stackTrace", Code: "adapterRejected", Message: "no stack"},
	}})
	if p.debug.failure != "no stack" {
		t.Fatalf("a rejected inspection was not shown: %q", p.debug.failure)
	}
}

// debugAdapterExitWait bounds the wait for a real adapter process to start and
// exit. The adapter is a copy of this test binary, whose startup depends on how
// busy the machine is, so the bound is as generous as the other tests that wait
// on that process; the wait itself ends on the event, not on the bound.
const debugAdapterExitWait = 30 * time.Second

func TestDebugPanelAdapterExitWithoutTerminated(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("exit"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	h.app.startDebug(p)
	session := p.debug.session
	awaitStateWithin(t, h, debugAdapterExitWait, "adapter exit to release session", func() bool { return p.debug.session == nil })
	// The adapter's first output can end the session before the startup goroutine,
	// which stores the process right after Start returns, has run that line. Its
	// startupDone is closed when startup finishes, so waiting for it orders the
	// check after the store instead of racing it.
	select {
	case <-session.startupDone:
	case <-time.After(debugAdapterExitWait):
		t.Fatal("the debug startup did not finish before the deadline")
	}
	if session.process.Load() == nil {
		t.Fatalf("the adapter never started: %s", p.debug.failure)
	}
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
	session := &debugSession{ctx: ctx}
	session.setTransport(writer)
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

// captureDebugLaunch observes the actual configuration sent to the DAP engine.
type captureDebugLaunch struct {
	Kernel
	configurations chan core.DebugLaunchConfiguration
}

func (k *captureDebugLaunch) LaunchDebug(ctx context.Context, sessionID, operationID string, configuration core.DebugLaunchConfiguration) (core.DebugUpdate, error) {
	select {
	case k.configurations <- configuration:
	case <-ctx.Done():
		return core.DebugUpdate{}, ctx.Err()
	}
	return k.Kernel.LaunchDebug(ctx, sessionID, operationID, configuration)
}

func TestDebugLaunchUsesCoreDeclaredArguments(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = gate
	h.app.startDebug(p)
	awaitStateWithin(t, h, 5*time.Second, "Core launch configuration", func() bool { return len(gate.configurations) == 1 })
	configuration := <-gate.configurations
	if configuration.Arguments["stopOnEntry"] != true {
		t.Fatalf("DAP configuration discarded plugin defaults: %+v", configuration)
	}
}

// The user's stepping policy for the adapter goes with the launch, and its collapse switch
// decides how the call stack shows filtered frames; without one Core uses the defaults.
func TestDebugLaunchCarriesTheUsersSteppingFilters(t *testing.T) {
	h := debugHarness(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug"), 0o600); err != nil {
		t.Fatal(err)
	}
	p := openDebugPanel(t, h, root)
	adapter := p.debug.adapters[p.debug.selectedAdapter].Declaration.AdapterID
	policy := core.DebugSteppingFilters{ClassNameFilters: []string{"java.*"}, SkipConstructors: true, HideFilteredStackFrames: true}
	h.app.setSteppingFilters(adapter, &policy)
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = gate
	h.app.startDebug(p)
	awaitStateWithin(t, h, 5*time.Second, "Core launch configuration", func() bool { return len(gate.configurations) == 1 })
	configuration := <-gate.configurations
	if got := configuration.SteppingFilters; got == nil || !got.SkipConstructors || !slices.Equal(got.ClassNameFilters, policy.ClassNameFilters) {
		t.Fatalf("launch stepping filters = %+v, want %+v", got, policy)
	}
	if !p.debug.hideFiltered {
		t.Fatal("the session does not collapse filtered frames although the policy asks to")
	}
}

// With collapsing on, each run of filtered frames below the top one is one row; a click on
// it shows the frames until the next stack arrives.
func TestCallStackCollapsesFilteredFrames(t *testing.T) {
	h := debugHarness(t)
	p := openDebugPanel(t, h, t.TempDir())
	h.app.post(func(*App) {
		p.debug.frames = []core.DebugStackFrame{
			{ID: 1, Name: "main", IsFiltered: true},
			{ID: 2, Name: "invoke0", IsFiltered: true},
			{ID: 3, Name: "invoke", IsFiltered: true},
			{ID: 4, Name: "run"},
			{ID: 5, Name: "start", IsFiltered: true},
		}
		p.debug.hideFiltered = true
	})
	h.settle()
	two := i18n.SharedFormat(h.app.language(), "desktop.debug.filteredFrames", map[string]string{"count": "2"})
	h.press(h.hitLabeled(two))
	if !p.debug.framesExpanded {
		t.Fatal("clicking the collapsed row did not show the frames")
	}
	h.settle()
	for _, name := range []string{"invoke0", "invoke"} {
		h.hitLabeled(name)
	}
}

func TestDebugFrameRowsKeepTheTopAndSelectedFrames(t *testing.T) {
	frames := []core.DebugStackFrame{{IsFiltered: true}, {IsFiltered: true}, {IsFiltered: true}, {}, {IsFiltered: true}, {IsFiltered: true}}
	rows := debugFrameRows(nil, frames, true, 2)
	want := []debugFrameRow{{frame: 0}, {frame: 1, hidden: 1}, {frame: 2}, {frame: 3}, {frame: 4, hidden: 2}}
	if !slices.Equal(rows, want) {
		t.Fatalf("rows = %+v, want %+v", rows, want)
	}
	if rows := debugFrameRows(nil, frames, false, 0); len(rows) != len(frames) {
		t.Fatalf("without collapsing rows = %+v", rows)
	}
}

// A plugin run with a launch debug target hands its process to the adapter: Core binds
// the run's program, arguments, directory and environment into the launch, and the run
// learns when the session ends.
func TestRunLaunchTargetBindsTheRunsProcessIntoTheLaunch(t *testing.T) {
	manifest := strings.Replace(debugFixtureManifest, `"requires": {"debugAdapters": 1`, `"requires": {"debugAdapters": 2`, 1)
	manifest = strings.Replace(manifest, `"configurations": {"launch":{"arguments":{"stopOnEntry":true}}}`,
		`"configurationTypes": ["fixture"], "configurations": {"launch":{"arguments":{"stopOnEntry":true},`+
			`"targetBindings":{"program":"target.path","cwd":"target.workingDirectory","args":"target.arguments","env":"target.environment"}}}`, 1)
	h := debugHarnessWith(t, manifest)
	root := t.TempDir()
	p := openDebugPanel(t, h, root)
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 1)}
	h.app.kernel = gate
	program := filepath.Join(root, "app")
	type outcome struct {
		session pluginservice.RunDebugSession
		err     error
	}
	launched := make(chan outcome, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		session, err := h.app.launchDebugForRun(ctx, pluginservice.RunDebugLaunchRequest{
			PluginID: "dev.lithe.test.debug-adapter", WorkspaceRoot: root, Label: "Run app", ConfigurationType: "fixture",
			Executable: program, Arguments: []string{"--port", "8080"}, WorkingDirectory: root, Environment: map[string]string{"APP_MODE": "dev"},
		})
		launched <- outcome{session, err}
	}()
	awaitStateWithin(t, h, 10*time.Second, "the launch to be planned", func() bool { return len(launched) == 1 || len(gate.configurations) == 1 })
	awaitStateWithin(t, h, 10*time.Second, "the session to start", func() bool { return len(launched) == 1 })
	result := <-launched
	if result.err != nil || result.session.ID == "" {
		t.Fatalf("launch = %+v", result)
	}
	awaitStateWithin(t, h, 10*time.Second, "Core launch configuration", func() bool { return len(gate.configurations) == 1 })
	arguments := (<-gate.configurations).Arguments
	args, _ := arguments["args"].([]any)
	env, _ := arguments["env"].(map[string]any)
	if arguments["program"] != program || arguments["cwd"] != root || len(args) != 2 || args[0] != "--port" || env["APP_MODE"] != "dev" {
		t.Fatalf("launch arguments = %+v", arguments)
	}
	// The release ends on a background goroutine that may post nothing, so the waiter
	// wakes the window itself once the end arrives.
	ended := make(chan struct{})
	go func() {
		select {
		case <-result.session.Ended:
		case <-t.Context().Done():
			return
		}
		close(ended)
		h.app.post(func(*App) {})
	}()
	h.app.post(func(a *App) { a.stopDebug(p) })
	awaitStateWithin(t, h, 20*time.Second, "the run to learn that the session ended", func() bool {
		select {
		case <-ended:
			return true
		default:
			return false
		}
	})
}
