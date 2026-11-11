package workbench

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// debugHostedManifest declares an adapter that lives inside the plugin's
// language server: it has no process, and the host connects to the loopback port
// the server hands out. It also declares the debugAdapters 3 features and
// defaults the engine has to receive.
const debugHostedManifest = `{
  "schemaVersion": 2,
  "id": "dev.lithe.test.debug-hosted",
  "displayName": "Hosted Debug Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 4,
  "requires": {"debugAdapters": 3, "languageServers": 1, "languages": 1, "serverProcess": 1},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["debug.launch", "languageServer.launch"],
  "activationEvents": ["onDebug:hosted", "onLanguage:hosted"],
  "languages": [{"id": "hosted", "displayName": "Hosted", "fileExtensions": ["hosted"]}],
  "languageServers": [{"languageID": "hosted", "launch": {"kind": "systemCommand", "commands": ["hosted-ls"]}, "arguments": ["--stdio"]}],
  "debugAdapters": [{
    "id": "hosted",
    "displayName": "Hosted DAP",
    "adapterID": "hosted-dap",
    "requests": ["launch"],
    "configurations": {"launch": {"arguments": {"stopOnEntry": true}}},
    "features": {"stepFilters": {"argument": "stepFilters"}},
    "defaults": {"stepFilters": {"classNameFilters": ["_vendor.*"], "skipSynthetics": true}},
    "launch": {"transport": "tcpLanguageServer", "endpoint": {"languageID": "hosted", "command": "hosted.startDebugSession"}}
  }]
}`

// debugAttachManifest is a stdio adapter that only attaches, to a host and port
// the adapter's own arguments name.
const debugAttachManifest = `{
  "schemaVersion": 2,
  "id": "dev.lithe.test.debug-attach",
  "displayName": "Attach Debug Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 4,
  "requires": {"debugAdapters": 1, "serverProcess": 1},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["debug.launch", "debug.attach"],
  "activationEvents": ["onDebug:attach"],
  "languages": [],
  "debugAdapters": [{
    "id": "attach",
    "displayName": "Attach DAP",
    "adapterID": "attach-dap",
    "requests": ["attach"],
    "configurations": {"attach": {"targetBindings": {"connection": {"host": "hostName", "port": "port"}}}},
    "launch": {
      "process": {"launch": {"kind": "packaged", "path": "adapter"}, "arguments": ["-test.run=^TestDebugAdapterRunner$"]},
      "transport": "stdio"
    }
  }]
}`

// debugPluginHarness installs one fixture plugin (and the copied test binary when
// it has a stdio process) and opens a window over it.
func debugPluginHarness(t *testing.T, id, manifest string, withBinary bool) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences := store.At(dir)
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, id, "1.0.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	if withBinary {
		copyTestBinary(t, filepath.Join(installed, debugFixtureProgramName()))
	}
	if err := pluginstate.New(preferences).SetEnabled(id, true); err != nil {
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

// fixtureWorkspace is a project the fixture adapter accepts.
func fixtureWorkspace(t *testing.T) (root, source string) {
	t.Helper()
	root = t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "debug.marker"), []byte("debug\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	source = filepath.Join(root, "tests", "debug_source.go")
	if err := os.WriteFile(source, []byte("package tests\n\nfunc main() {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return root, source
}

// adapterServer is a TCP debug server running the fixture adapter, the way a
// language server hosts one. It records each connection so a test can see who
// closed it.
type adapterServer struct {
	listener net.Listener
	root     string
	mu       sync.Mutex
	conns    []net.Conn
	closed   chan struct{}
	silent   bool
}

func serveHostedAdapter(t *testing.T, root string, silent bool) *adapterServer {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &adapterServer{listener: listener, root: root, closed: make(chan struct{}, 4), silent: silent}
	t.Cleanup(func() {
		_ = listener.Close()
		server.mu.Lock()
		for _, conn := range server.conns {
			_ = conn.Close()
		}
		server.mu.Unlock()
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			server.mu.Lock()
			server.conns = append(server.conns, conn)
			server.mu.Unlock()
			go func() {
				defer func() { server.closed <- struct{}{} }()
				defer conn.Close()
				if server.silent {
					// Accepts and says nothing: the adapter that never answers initialize.
					buffer := make([]byte, 4096)
					for {
						if _, err := conn.Read(buffer); err != nil {
							return
						}
					}
				}
				serveFixtureAdapter(conn, conn, root)
			}()
		}
	}()
	return server
}

func (s *adapterServer) port() int { return s.listener.Addr().(*net.TCPAddr).Port }

func (s *adapterServer) dropConnections() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, conn := range s.conns {
		_ = conn.Close()
	}
}

func openHostedPanel(t *testing.T, h *harness, root string) *project {
	t.Helper()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	for range 4 {
		h.settle()
	}
	p := h.app.project
	if p == nil || len(p.debug.adapters) != 1 {
		t.Fatalf("adapters = %+v, want the hosted fixture adapter", p.debug.adapters)
	}
	return p
}

func TestDebugTCPLanguageServerAdapterBreakpointPauseContinueStop(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, source := fixtureWorkspace(t)
	server := serveHostedAdapter(t, root, false)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return server.port(), nil }
	gate := &captureDebugSession{Kernel: h.app.kernel, requests: make(chan core.DebugCreateSessionRequest, 1)}
	h.app.kernel = gate
	p := openHostedPanel(t, h, root)
	if declaration := p.debug.adapters[0].Declaration; declaration.Transport != "tcpLanguageServer" || declaration.Endpoint.Command != "hosted.startDebugSession" {
		t.Fatalf("declaration = %+v, want the hosted adapter's endpoint", declaration)
	}
	h.app.openFileAtPosition(p, source, 2, 0)
	h.settle()
	h.clickNamed(h.app.text.Debug.ToggleBreakpoint)

	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused hosted session", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
	// The declared features and defaults reach the engine with the session.
	request := <-gate.requests
	if !strings.Contains(string(request.Features), "stepFilters") || !strings.Contains(string(request.Defaults), "_vendor") {
		t.Fatalf("session request dropped the declaration: features=%s defaults=%s", request.Features, request.Defaults)
	}

	h.clickNamed(h.app.text.Debug.Continue)
	awaitStateWithin(t, h, 20*time.Second, "the continued session", func() bool {
		return p.debug.state == "running" && len(p.debug.frames) == 0
	})
	h.clickNamed(h.app.text.Debug.Pause)
	awaitStateWithin(t, h, 20*time.Second, "the paused session", func() bool {
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})

	h.clickNamed(h.app.text.Debug.Stop)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool {
		return p.debug.session == nil && p.debug.state == "idle"
	})
	// Closing the stream is how the host lets go of a shared server's session.
	select {
	case <-server.closed:
	case <-time.After(10 * time.Second):
		t.Fatal("the adapter connection stayed open after Stop")
	}
}

// captureDebugSession records the session request the engine receives.
type captureDebugSession struct {
	Kernel
	requests chan core.DebugCreateSessionRequest
}

func (k *captureDebugSession) CreateDebugSession(ctx context.Context, request core.DebugCreateSessionRequest) (core.DebugUpdate, error) {
	select {
	case k.requests <- request:
	default:
	}
	return k.Kernel.CreateDebugSession(ctx, request)
}

func TestDebugTCPCloseProjectDropsTheConnection(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, _ := fixtureWorkspace(t)
	server := serveHostedAdapter(t, root, false)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return server.port(), nil }
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused session", func() bool { return p.debug.state == "paused" })
	h.app.closeProject()
	awaitStateWithin(t, h, 20*time.Second, "the project to close", func() bool { return h.app.project == nil })
	select {
	case <-server.closed:
	case <-time.After(10 * time.Second):
		t.Fatal("closing the project left the adapter connection open")
	}
	h.settle()
}

func TestDebugTCPPeerClosingEndsTheSession(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, _ := fixtureWorkspace(t)
	server := serveHostedAdapter(t, root, false)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return server.port(), nil }
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused session", func() bool { return p.debug.state == "paused" })
	server.dropConnections()
	awaitStateWithin(t, h, 20*time.Second, "the session to end", func() bool { return p.debug.session == nil })
	// A peer that drops the connection ends the session: a clean close is
	// terminated, a reset is reported and released.
	if state := p.debug.state; state != "terminated" && state != "idle" {
		t.Fatalf("state = %q, want the session ended", state)
	}
}

func TestDebugTCPUnreachableEndpointFailsWithAMessage(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, _ := fixtureWorkspace(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closedPort := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return closedPort, nil }
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 20*time.Second, "the failure", func() bool { return p.debug.failure != "" })
	if !strings.Contains(p.debug.failure, "127.0.0.1") || p.debug.session != nil {
		t.Fatalf("failure = %q, session = %v", p.debug.failure, p.debug.session)
	}
}

func TestDebugTCPEndpointFailureIsShownAndStartsNothing(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, _ := fixtureWorkspace(t)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) {
		return 0, errors.New("the server has no debug command")
	}
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 20*time.Second, "the failure", func() bool { return p.debug.failure != "" })
	if !strings.Contains(p.debug.failure, "no debug command") || p.debug.session != nil {
		t.Fatalf("failure = %q, session = %v", p.debug.failure, p.debug.session)
	}
}

func TestDebugTCPAdapterThatNeverInitializesTimesOut(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, _ := fixtureWorkspace(t)
	server := serveHostedAdapter(t, root, true)
	h.app.debugHostedPort = func(context.Context, *project, debugAdapter) (int, error) { return server.port(), nil }
	h.app.debugInitializeWindow = 300 * time.Millisecond
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 20*time.Second, "the timeout", func() bool { return p.debug.failure != "" })
	if p.debug.failure != h.app.text.Debug.TimedOut || p.debug.session != nil {
		t.Fatalf("failure = %q, want the timeout message", p.debug.failure)
	}
	select {
	case <-server.closed:
	case <-time.After(10 * time.Second):
		t.Fatal("the timed-out connection stayed open")
	}
}

func TestDebugTCPStopWhileWaitingForTheEndpointCancels(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	root, _ := fixtureWorkspace(t)
	entered := make(chan struct{})
	finished := make(chan error, 1)
	h.app.debugHostedPort = func(ctx context.Context, _ *project, _ debugAdapter) (int, error) {
		close(entered)
		<-ctx.Done()
		finished <- ctx.Err()
		return 0, ctx.Err()
	}
	p := openHostedPanel(t, h, root)
	h.app.startDebug(p)
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("the endpoint was never asked for")
	}
	h.app.stopDebug(p)
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("the wait ended with %v, want cancellation", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Stop did not cancel the wait for the endpoint")
	}
	awaitStateWithin(t, h, 20*time.Second, "the session to be released", func() bool { return p.debug.session == nil })
	if p.debug.failure != "" {
		t.Fatalf("a user cancel was reported as a failure: %q", p.debug.failure)
	}
}

func TestParseDebugPort(t *testing.T) {
	for input, want := range map[string]int{`5005`: 5005, `"5005"`: 5005, `" 8000 "`: 8000, `65535`: 65535, `1`: 1} {
		got, err := parseDebugPort([]byte(input))
		if err != nil || got != want {
			t.Errorf("parseDebugPort(%s) = %d, %v; want %d", input, got, err, want)
		}
	}
	for _, input := range []string{`0`, `65536`, `-1`, `"abc"`, `""`, `null`, `true`, `{}`, `[]`, `5005.5`} {
		if port, err := parseDebugPort([]byte(input)); err == nil {
			t.Errorf("parseDebugPort(%s) = %d, want a refusal", input, port)
		}
	}
}

func TestDebugRemoteAttachAsksBeforeConnectingAndLoopbackDoesNot(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-attach", debugAttachManifest, true)
	root, _ := fixtureWorkspace(t)
	gate := &captureDebugLaunch{Kernel: h.app.kernel, configurations: make(chan core.DebugLaunchConfiguration, 2)}
	h.app.kernel = gate
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	for range 4 {
		h.settle()
	}
	p := h.app.project
	if len(p.debug.adapters) != 1 || !debugAttachOnly(p.debug.adapters[0]) {
		t.Fatalf("adapters = %+v, want the attach-only adapter", p.debug.adapters)
	}

	// A remote endpoint is not connected to until the user confirms it.
	h.app.debugAttach.host.SetText("debug.example.test")
	h.app.debugAttach.port.SetText("5005")
	h.app.startDebug(p)
	awaitStateWithin(t, h, 20*time.Second, "the confirmation", func() bool { return p.debug.remote != nil })
	if p.debug.session != nil || p.debug.failure != "" || len(gate.configurations) != 0 {
		t.Fatalf("a remote attach started before confirmation: session=%v failure=%q", p.debug.session, p.debug.failure)
	}
	if p.debug.remote.endpoint != "debug.example.test:5005" {
		t.Fatalf("endpoint = %q", p.debug.remote.endpoint)
	}
	h.settle()
	if !h.shows("debug.example.test:5005") {
		t.Fatal("the panel does not name the remote endpoint it asks about")
	}
	h.clickNamed(h.app.text.Debug.RemoteAttach)
	awaitStateWithin(t, h, 30*time.Second, "the confirmed attach", func() bool { return len(gate.configurations) == 1 })
	configuration := <-gate.configurations
	if configuration.Request != "attach" || configuration.Arguments["hostName"] != "debug.example.test" || configuration.Arguments["port"] != float64(5005) && configuration.Arguments["port"] != uint64(5005) && configuration.Arguments["port"] != int64(5005) {
		t.Fatalf("attach configuration = %+v", configuration)
	}
	h.app.stopDebug(p)
	awaitStateWithin(t, h, 20*time.Second, "the session to stop", func() bool { return p.debug.session == nil })

	// A cancelled prompt starts nothing.
	h.app.debugAttach.host.SetText("debug.example.test")
	h.app.startDebug(p)
	awaitStateWithin(t, h, 20*time.Second, "the second confirmation", func() bool { return p.debug.remote != nil })
	h.clickNamed(h.app.text.Debug.RemoteCancel)
	if p.debug.remote != nil || p.debug.session != nil {
		t.Fatal("cancelling the prompt did not drop the attach")
	}

	// A loopback endpoint needs no confirmation.
	h.app.debugAttach.host.SetText("localhost")
	h.app.startDebug(p)
	awaitStateWithin(t, h, 30*time.Second, "the loopback attach", func() bool { return len(gate.configurations) == 1 })
	if p.debug.remote != nil {
		t.Fatal("a loopback endpoint asked for confirmation")
	}
	h.app.stopDebug(p)
	awaitStateWithin(t, h, 20*time.Second, "the session to stop", func() bool { return p.debug.session == nil })
}

func TestDebugAttachFormRejectsABadPort(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-attach", debugAttachManifest, true)
	root, _ := fixtureWorkspace(t)
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	for range 4 {
		h.settle()
	}
	p := h.app.project
	h.app.debugAttach.port.SetText("not a port")
	h.app.startDebug(p)
	if p.debug.session != nil || p.debug.failure != h.app.text.Debug.AttachInvalid {
		t.Fatalf("session = %v, failure = %q, want the form message", p.debug.session, p.debug.failure)
	}
}

// The settings window lists an installed adapter that declares stepping filters, with the
// defaults its plugin declares.
func TestSteppingAdaptersListsDeclaredDefaults(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-hosted", debugHostedManifest, false)
	adapters, err := h.app.steppingAdapters(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(adapters) != 1 || adapters[0].ID != "hosted-dap" || adapters[0].Name != "Hosted DAP" ||
		!adapters[0].Defaults.SkipSynthetics || len(adapters[0].Defaults.ClassNameFilters) != 1 {
		t.Fatalf("adapters = %+v", adapters)
	}
}
