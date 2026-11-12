package pluginservice

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// runFixturePlugin is the contract's tool-reference fixture: it requires the
// tool "interpreter" and holds the run.start permission.
const runFixturePlugin = "dev.lithe.fixture.tool-reference-launch"

// runKernel answers the run and link decoding with the real Core, so a start is
// validated by the rules every host shares.
type runKernel struct {
	fakeKernel
	client *core.Client
}

func (k *runKernel) DecodeRunStart(ctx context.Context, manifest json.RawMessage, root, temporary string, params json.RawMessage) (core.RunStart, error) {
	return k.client.DecodeRunStart(ctx, manifest, root, temporary, params)
}

func (k *runKernel) DecodeDebugBackendConfiguration(ctx context.Context, manifest json.RawMessage, params json.RawMessage) (core.DebugBackendStart, error) {
	return k.client.DecodeDebugBackendConfiguration(ctx, manifest, params)
}

func (k *runKernel) DecodeOutputLinkResolution(ctx context.Context, reply json.RawMessage) (*core.OutputLocation, error) {
	return k.client.DecodeOutputLinkResolution(ctx, reply)
}

// TestRunHelperProcess is the program a run starts: the test binary itself. It
// does nothing unless the run asks for a mode, so a normal test run skips it.
func TestRunHelperProcess(t *testing.T) {
	switch os.Getenv("LITHE_RUN_HELPER") {
	case "":
		return
	case "print":
		fmt.Println("hello from the run")
		fmt.Fprintln(os.Stderr, "warning line")
		os.Exit(3)
	case "sleep":
		time.Sleep(time.Minute)
		os.Exit(0)
	case "listen":
		listener, err := net.Listen("tcp", "127.0.0.1:"+os.Getenv("LITHE_RUN_PORT"))
		if err != nil {
			os.Exit(2)
		}
		defer listener.Close()
		time.Sleep(time.Minute)
		os.Exit(0)
	}
}

type runHarness struct {
	service *Service
	root    string
	mu      sync.Mutex
	events  []RunEvent
}

func newRunHarness(t *testing.T) *runHarness {
	t.Helper()
	preferences := store.At(t.TempDir())
	pluginRoot := t.TempDir()
	installed := filepath.Join(pluginRoot, runFixturePlugin, "0.1.0")
	if err := os.MkdirAll(installed, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/run/tool-reference-launch.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled(runFixturePlugin, true); err != nil {
		t.Fatal(err)
	}
	service, err := Open(&runKernel{client: core.NewClient()}, preferences, pluginRoot)
	if err != nil {
		t.Fatal(err)
	}
	h := &runHarness{service: service, root: t.TempDir()}
	service.Runs.SetObserver(func(event RunEvent) {
		h.mu.Lock()
		h.events = append(h.events, event)
		h.mu.Unlock()
	})
	service.Runs.Tools = func(_ context.Context, _, tool string) (RunExecutable, error) {
		if tool != "interpreter" {
			return RunExecutable{}, fmt.Errorf("no tool %s", tool)
		}
		return RunExecutable{Path: os.Args[0]}, nil
	}
	service.Contexts.Open(h.root)
	t.Cleanup(func() {
		service.Runs.StopAll()
		service.Contexts.CloseAll()
	})
	return h
}

func (h *runHarness) params(t *testing.T, mode string, extra map[string]any) string {
	t.Helper()
	workspace, ok := h.service.Contexts.ByPath(h.root)
	if !ok {
		t.Fatal("the workspace context is not open")
	}
	params := map[string]any{
		"context": workspace.ContextRef,
		"label":   "Run " + mode,
		"process": map[string]any{
			"executable":       map[string]any{"kind": "tool", "tool": "interpreter"},
			"arguments":        []string{"-test.run=^TestRunHelperProcess$"},
			"workingDirectory": ".",
			"environment":      map[string]string{"LITHE_RUN_HELPER": mode, "LITHE_RUN_PORT": fmt.Sprint(extra["port"])},
		},
	}
	for key, value := range extra {
		if key != "port" {
			params[key] = value
		}
	}
	data, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func (h *runHarness) await(t *testing.T, description string, done func(events []RunEvent) bool) []RunEvent {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		events := append([]RunEvent(nil), h.events...)
		h.mu.Unlock()
		if done(events) {
			return events
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", description)
	return nil
}

func startedRunID(t *testing.T, result json.RawMessage, refusal *pluginhost.Failure) string {
	t.Helper()
	if refusal != nil {
		t.Fatalf("run/start refused: %+v", refusal)
	}
	var reply struct {
		RunID string `json:"runID"`
	}
	if err := json.Unmarshal(result, &reply); err != nil || reply.RunID == "" {
		t.Fatalf("run/start = %s (%v)", result, err)
	}
	return reply.RunID
}

func exitedEvent(events []RunEvent) *RunEvent {
	for index := range events {
		if events[index].Type == RunExited {
			return &events[index]
		}
	}
	return nil
}

func TestRunStartReportsOutputAndTheExitCode(t *testing.T) {
	h := newRunHarness(t)
	result, refusal := respond(t, h.service, runFixturePlugin, "run/start", h.params(t, "print", nil))
	id := startedRunID(t, result, refusal)
	events := h.await(t, "the run to exit", func(events []RunEvent) bool { return exitedEvent(events) != nil })
	if events[0].Type != RunStarted || events[0].RunID != id || events[0].Label != "Run print" {
		t.Fatalf("the first event = %+v, want the started run", events[0])
	}
	var output strings.Builder
	for _, event := range events {
		if event.Type == RunOutput {
			output.WriteString(event.Text)
		}
	}
	if !strings.Contains(output.String(), "hello from the run") || !strings.Contains(output.String(), "warning line") {
		t.Fatalf("output = %q, want both streams", output.String())
	}
	exited := exitedEvent(events)
	if exited.ExitCode == nil || *exited.ExitCode != 3 {
		t.Fatalf("exit = %+v, want code 3", exited)
	}
	if active := h.service.Runs.Active(); len(active) != 0 {
		t.Fatalf("active runs after exit = %v", active)
	}
}

func TestRunStopEndsTheRunAndOnlyForItsOwner(t *testing.T) {
	h := newRunHarness(t)
	result, refusal := respond(t, h.service, runFixturePlugin, "run/start", h.params(t, "sleep", nil))
	id := startedRunID(t, result, refusal)
	body := `{"runID":"` + id + `"}`

	// Another plugin cannot stop the run: the answer is the same null, and the run goes on.
	if _, refusal := respond(t, h.service, "other.plugin", "run/stop", body); refusal != nil {
		t.Fatalf("a foreign stop was refused instead of ignored: %+v", refusal)
	}
	if active := h.service.Runs.Active(); len(active) != 1 {
		t.Fatalf("a foreign plugin stopped the run: %v", active)
	}

	if _, refusal := respond(t, h.service, runFixturePlugin, "run/stop", body); refusal != nil {
		t.Fatalf("run/stop: %+v", refusal)
	}
	h.await(t, "the stopped run to exit", func(events []RunEvent) bool { return exitedEvent(events) != nil })
	if active := h.service.Runs.Active(); len(active) != 0 {
		t.Fatalf("active runs after stop = %v", active)
	}
	// Stopping a run that ended is still null.
	if _, refusal := respond(t, h.service, runFixturePlugin, "run/stop", body); refusal != nil {
		t.Fatalf("stopping an ended run: %+v", refusal)
	}
	// Exactly one of runID and sessionID is named.
	if _, refusal := respond(t, h.service, runFixturePlugin, "run/stop", `{}`); refusal == nil || refusal.Code != "plugin.host.invalidParams" {
		t.Fatalf("an empty stop = %+v, want invalidParams", refusal)
	}
}

func TestRunStartRefusals(t *testing.T) {
	h := newRunHarness(t)

	_, refusal := respond(t, h.service, runFixturePlugin, "run/start", `{"context":{"contextID":"gone","generation":1}}`)
	if refusal == nil || refusal.Code != "plugin.host.contextExpired" {
		t.Fatalf("a closed context = %+v", refusal)
	}

	// Core's own code and field travel in details.
	bad := h.params(t, "print", map[string]any{"label": "bad\nlabel"})
	_, refusal = respond(t, h.service, runFixturePlugin, "run/start", bad)
	if refusal == nil || refusal.Code != "plugin.host.invalidParams" {
		t.Fatalf("a label with a line break = %+v", refusal)
	}
	var details struct{ Code, Field string }
	if err := json.Unmarshal(refusal.Details, &details); err != nil || details.Code != "plugin.run.invalidStart" || details.Field != "label" {
		t.Fatalf("details = %s (%v), want Core's code and field", refusal.Details, err)
	}

	h.service.Runs.Tools = func(context.Context, string, string) (RunExecutable, error) {
		return RunExecutable{}, fmt.Errorf("no interpreter installed")
	}
	_, refusal = respond(t, h.service, runFixturePlugin, "run/start", h.params(t, "print", nil))
	if refusal == nil || refusal.Code != "plugin.host.toolUnresolved" {
		t.Fatalf("an unresolved tool = %+v", refusal)
	}
	if active := h.service.Runs.Active(); len(active) != 0 {
		t.Fatalf("a refused start left runs behind: %v", active)
	}
}

func TestRunStartRefusesALaunchDebugTargetItCannotServe(t *testing.T) {
	h := newRunHarness(t)
	params := h.params(t, "print", map[string]any{"debug": map[string]any{"configurationType": "script", "target": map[string]any{"kind": "launch"}}})
	if _, refusal := respond(t, h.service, runFixturePlugin, "run/start", params); refusal == nil || refusal.Code != "plugin.host.unavailable" {
		t.Fatalf("a launch debug target without a launcher = %+v, want unavailable", refusal)
	}
}

// A launch debug target hands the run's process to the adapter: the host starts no
// process, the run stands for the debug session, stopping the run stops the session,
// and the run ends with the debuggee's exit code when the session ends.
func TestRunStartLaunchesTheProcessUnderTheDebugger(t *testing.T) {
	h := newRunHarness(t)
	launched := make(chan RunDebugLaunchRequest, 1)
	stopped := make(chan string, 1)
	ended := make(chan *int, 1)
	h.service.Runs.LaunchDebug = func(_ context.Context, request RunDebugLaunchRequest) (RunDebugSession, error) {
		launched <- request
		return RunDebugSession{ID: "debug-session-7", Ended: ended}, nil
	}
	// Stopping the session ends it, as the window's release does, with the debuggee's code.
	h.service.Runs.StopDebugSession = func(id string) {
		stopped <- id
		code := 3
		ended <- &code
	}
	params := h.params(t, "print", map[string]any{"debug": map[string]any{"configurationType": "script", "target": map[string]any{"kind": "launch"}}})
	result, refusal := respond(t, h.service, runFixturePlugin, "run/start", params)
	runID := startedRunID(t, result, refusal)
	request := <-launched
	if request.PluginID != runFixturePlugin || request.ConfigurationType != "script" || request.Executable == "" ||
		!filepath.IsAbs(request.WorkingDirectory) || len(request.Arguments) != 1 || request.Environment["LITHE_RUN_HELPER"] != "print" {
		t.Fatalf("launch request = %+v", request)
	}
	body, err := json.Marshal(map[string]string{"runID": runID})
	if err != nil {
		t.Fatal(err)
	}
	if _, refusal := respond(t, h.service, runFixturePlugin, "run/stop", string(body)); refusal != nil {
		t.Fatalf("run/stop = %+v", refusal)
	}
	select {
	case id := <-stopped:
		if id != "debug-session-7" {
			t.Fatalf("stopped session %q", id)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("stopping the run did not stop the debug session")
	}
	events := h.await(t, "the run to end with the session", func(events []RunEvent) bool { return exitedEvent(events) != nil })
	exited := exitedEvent(events)
	if exited.RunID != runID || exited.ExitCode == nil || *exited.ExitCode != 3 {
		t.Fatalf("exit = %+v", exited)
	}
	for _, event := range events {
		if event.Type == RunOutput {
			t.Fatalf("a launch run printed process output itself: %q", event.Text)
		}
	}
}

func TestRunStartAttachesTheDebuggerOnceThePortOpens(t *testing.T) {
	h := newRunHarness(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	attached := make(chan RunDebugRequest, 1)
	h.service.Runs.Debug = func(_ context.Context, request RunDebugRequest) (string, error) {
		attached <- request
		return "debug-session-1", nil
	}
	params := h.params(t, "listen", map[string]any{
		"port":  port,
		"debug": map[string]any{"configurationType": "script", "target": map[string]any{"kind": "connection", "port": port}},
	})
	result, refusal := respond(t, h.service, runFixturePlugin, "run/start", params)
	startedRunID(t, result, refusal)
	select {
	case request := <-attached:
		if request.Port != port || request.Host != "127.0.0.1" || request.ConfigurationType != "script" || request.PluginID != runFixturePlugin {
			t.Fatalf("attach request = %+v", request)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the debugger was never attached")
	}
}

func TestRunDebugStopsTheRunWhenTheAdapterCannotAttach(t *testing.T) {
	h := newRunHarness(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	h.service.Runs.Debug = func(context.Context, RunDebugRequest) (string, error) {
		return "", fmt.Errorf("no adapter")
	}
	params := h.params(t, "listen", map[string]any{
		"port":  port,
		"debug": map[string]any{"configurationType": "script", "target": map[string]any{"kind": "connection", "port": port}},
	})
	result, refusal := respond(t, h.service, runFixturePlugin, "run/start", params)
	startedRunID(t, result, refusal)
	events := h.await(t, "the run to be stopped", func(events []RunEvent) bool { return exitedEvent(events) != nil })
	var output strings.Builder
	for _, event := range events {
		output.WriteString(event.Text)
	}
	if !strings.Contains(output.String(), "no adapter") {
		t.Fatalf("the failure was not shown in the run's output: %q", output.String())
	}
}

func TestWaitForPortGivesUpWhenTheProcessEnds(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	ended := make(chan struct{})
	close(ended)
	err = waitForPort(context.Background(), port, ended, time.Minute)
	if err == nil || !strings.Contains(err.Error(), "ended") {
		t.Fatalf("err = %v, want the process-ended failure", err)
	}
	if err := waitForPort(context.Background(), port, make(chan struct{}), 150*time.Millisecond); err == nil || !strings.Contains(err.Error(), "did not open") {
		t.Fatalf("err = %v, want the timeout", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := waitForPort(ctx, port, make(chan struct{}), time.Minute); err == nil {
		t.Fatal("a cancelled wait succeeded")
	}
}
