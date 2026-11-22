package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const (
	remoteRunRoot = "/home/dev/project"
	remoteScratch = "/home/dev/.lithe-server/plugin-runs/fixture"
	remotePayload = "AP8="
)

type remoteRunFixture struct {
	runKernel
	notifications chan string
	start         core.RunStart
	spawn         func(context.Context, core.RemoteProcessOpen, core.RemoteProcessEvents) (core.RemoteProcessExit, error)
	write         func(string, []byte) error
	scratch       string
	released      chan string
}

func (k *remoteRunFixture) SendPluginHostNotification(ctx context.Context, session, method string, params json.RawMessage) (bool, error) {
	if k.notifications == nil {
		return false, nil
	}
	select {
	case k.notifications <- session + " " + method + " " + string(params):
		return true, nil
	case <-ctx.Done():
		return false, ctx.Err()
	}
}

func (k *remoteRunFixture) DecodeRunStart(ctx context.Context, _ json.RawMessage, root, temporary string, _ json.RawMessage) (core.RunStart, error) {
	binding := core.RemoteWorkspaceOf(ctx)
	if binding == nil || binding.LocalRoot() != root || binding.RemoteRoot() != remoteRunRoot {
		return core.RunStart{}, errors.New("run decoder did not receive the remote workspace")
	}
	if k.scratch != "" && temporary != remoteScratch {
		return core.RunStart{}, fmt.Errorf("run decoder received scratch %q", temporary)
	}
	return k.start, ctx.Err()
}

func (k *remoteRunFixture) CreateRemoteRunDirectory(ctx context.Context, id string) (string, error) {
	k.scratch = id
	return remoteScratch, ctx.Err()
}

func (k *remoteRunFixture) ReleaseRemoteRunDirectory(ctx context.Context, id string) error {
	binding := core.RemoteWorkspaceOf(ctx)
	if binding == nil || binding.RemoteRoot() != remoteRunRoot || id != k.scratch || ctx.Err() != nil {
		return errors.New("scratch release lost its original workspace, identity or deadline")
	}
	k.released <- id
	return nil
}

func (k *remoteRunFixture) WriteRemoteRunFile(_ context.Context, path string, data []byte) error {
	return k.write(path, data)
}

func (k *remoteRunFixture) RunRemoteProcess(ctx context.Context, spec core.RemoteProcessOpen, events core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
	return k.spawn(ctx, spec, events)
}

func openRemoteRunFixture(t *testing.T, k *remoteRunFixture) (*runHarness, *core.RemoteWorkspace, *atomic.Bool, chan RunEvent) {
	t.Helper()
	k.runKernel.client = core.NewClient()
	k.released = make(chan string, 2)
	k.start.Label = "Remote fixture"
	k.start.Executable = core.RunStartExecutable{Kind: "toolchain", Value: "interpreter"}
	k.start.WorkingDirectory = "module"
	h := newRunHarnessWithKernel(t, k)
	binding := core.NewRemoteWorkspace(h.root, remoteRunRoot, nil)
	binding.Attach("session-1")
	trusted := &atomic.Bool{}
	trusted.Store(true)
	h.service.Contexts.OpenRemote(binding, "fixture", "connection-1", core.RemotePlatform{OS: "linux", Arch: "x86_64"}, trusted.Load)
	events := make(chan RunEvent, 8)
	h.service.Runs.SetObserver(func(event RunEvent) { events <- event })
	h.service.Runs.Tools = func(ctx context.Context, root, directory, tool string) (RunExecutable, error) {
		if core.RemoteWorkspaceOf(ctx) != binding || root != h.root || directory != "module" || tool != "interpreter" {
			return RunExecutable{}, fmt.Errorf("unexpected remote tool request for %q in %q (%q)", tool, root, directory)
		}
		return RunExecutable{
			Path: "/opt/tool/bin/interpreter", Environment: map[string]string{"TOOL_ROOT": "/opt/tool", "MODE": "default"},
			PathPrepend: []string{"/opt/tool/bin"},
		}, nil
	}
	return h, binding, trusted, events
}

func waitRemoteRunEvent[T any](t *testing.T, events <-chan T) T {
	t.Helper()
	select {
	case event := <-events:
		return event
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the remote run")
		var zero T
		return zero
	}
}

func TestRemoteRunStartPreservesScopeEnvironmentAndScratch(t *testing.T) {
	for _, explicitPath := range []bool{false, true} {
		t.Run(fmt.Sprintf("explicitPath=%t", explicitPath), func(t *testing.T) {
			k := &remoteRunFixture{}
			h, binding, _, events := openRemoteRunFixture(t, k)
			k.start.Environment = map[string]string{"MODE": "plugin"}
			if explicitPath {
				k.start.Environment["PATH"] = "/other/bin"
			}
			file := remoteScratch + "/argument-file"
			k.start.Arguments = []string{"@" + file}
			k.start.TemporaryFiles = []core.RunStartFile{{Path: file, Base64: remotePayload}}
			k.write = func(name string, data []byte) error {
				if name != file || !reflect.DeepEqual(data, []byte{0, 255}) {
					return fmt.Errorf("write %q = %x", name, data)
				}
				return nil
			}
			specs := make(chan core.RemoteProcessOpen, 1)
			k.spawn = func(ctx context.Context, spec core.RemoteProcessOpen, sink core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
				if core.RemoteWorkspaceOf(ctx) != binding {
					return core.RemoteProcessExit{}, errors.New("spawn lost its workspace")
				}
				specs <- spec
				sink.Started(1, 42)
				sink.Output("stderr", []byte("remote output\n"))
				code := 7
				return core.RemoteProcessExit{ExitCode: &code}, nil
			}

			response, refusal := respond(t, h.service, runFixturePlugin, "run/start", h.params(t, "remote", map[string]any{
				"temporaryFiles": []map[string]string{{"name": "argument-file", "base64": remotePayload}},
			}))
			id := startedRunID(t, response, refusal)
			spec := waitRemoteRunEvent(t, specs)
			if !reflect.DeepEqual(spec.Argv, []string{"/opt/tool/bin/interpreter", "@" + file}) ||
				spec.Cwd != "" || spec.ScopedCwd == nil || *spec.ScopedCwd != (core.RemoteScopedDirectory{Root: remoteRunRoot, Path: "module"}) ||
				spec.Environment != "login" || spec.Env["MODE"] != "plugin" || spec.Env["TOOL_ROOT"] != "/opt/tool" {
				t.Fatalf("remote spawn = %+v", spec)
			}
			if explicitPath {
				if spec.Env["PATH"] != "/other/bin" || len(spec.PathPrepend) != 0 {
					t.Fatalf("explicit path was changed in %+v", spec)
				}
			} else if _, set := spec.Env["PATH"]; set || !reflect.DeepEqual(spec.PathPrepend, []string{"/opt/tool/bin"}) {
				t.Fatalf("remote login PATH was replaced in %+v", spec)
			}
			started, output, ended := waitRemoteRunEvent(t, events), waitRemoteRunEvent(t, events), waitRemoteRunEvent(t, events)
			if started.Type != RunStarted || started.RunID != id || !started.Remote || started.PID != 0 ||
				output.Type != RunOutput || output.RunID != id || output.Text != "remote output\n" ||
				ended.Type != RunExited || ended.RunID != id || ended.ExitCode == nil || *ended.ExitCode != 7 {
				t.Fatalf("run events out of order or incomplete: %+v %+v %+v", started, output, ended)
			}
			waitRemoteRunEvent(t, k.released)
		})
	}
}

func TestRemoteRunRefusesUntrustedWorkspaceAndReleasesFailedSetup(t *testing.T) {
	k := &remoteRunFixture{}
	h, _, trusted, events := openRemoteRunFixture(t, k)
	params := h.params(t, "remote", map[string]any{
		"temporaryFiles": []map[string]string{{"name": "argument-file", "base64": remotePayload}},
	})
	trusted.Store(false)
	_, refusal := respond(t, h.service, runFixturePlugin, "run/start", params)
	if refusal == nil || refusal.Code != CodePermissionDenied || k.scratch != "" {
		t.Fatalf("untrusted start = %+v, scratch = %q", refusal, k.scratch)
	}
	trusted.Store(true)
	k.start.TemporaryFiles = []core.RunStartFile{{Path: remoteScratch + "/argument-file", Base64: remotePayload}}
	k.write = func(string, []byte) error { return errors.New("scratch write failed") }
	_, refusal = respond(t, h.service, runFixturePlugin, "run/start", params)
	if refusal == nil || refusal.Code != pluginhost.CodeHostFailure || len(events) != 0 {
		t.Fatalf("failed scratch write = %+v, events = %d", refusal, len(events))
	}
	waitRemoteRunEvent(t, k.released)
}

func TestRemoteRunStopsOnRequestContextCloseOrAttachmentReplacement(t *testing.T) {
	for _, action := range []string{"stop", "close", "reattach", "replace during launch"} {
		t.Run(action, func(t *testing.T) {
			k := &remoteRunFixture{}
			h, binding, _, events := openRemoteRunFixture(t, k)
			k.spawn = func(ctx context.Context, _ core.RemoteProcessOpen, sink core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
				if action == "replace during launch" {
					binding.Attach("session-1")
				}
				sink.Started(1, 42)
				sink.Output("stdout", []byte("started\n"))
				select {
				case <-ctx.Done():
					return core.RemoteProcessExit{}, ctx.Err()
				case <-time.After(5 * time.Second):
					return core.RemoteProcessExit{}, errors.New("owner did not cancel the remote process")
				}
			}
			ctx, cancel := context.WithCancel(callerContext(runFixturePlugin))
			defer cancel()
			result, refusal := h.service.HostServices.Respond(ctx, methodRunStart, json.RawMessage(h.params(t, "remote", nil)))
			if action == "replace during launch" {
				if refusal == nil || refusal.Code != CodeRemoteDisconnected || len(events) != 0 {
					t.Fatalf("stale start = %+v, events = %d", refusal, len(events))
				}
				return
			}
			id := startedRunID(t, result, refusal)
			// The request ends after acknowledgement. A different owner ends
			// the actual process below.
			cancel()
			switch action {
			case "stop":
				if _, refusal := respond(t, h.service, runFixturePlugin, "run/stop", `{"runID":"`+id+`"}`); refusal != nil {
					t.Fatalf("stop: %+v", refusal)
				}
			case "close":
				h.service.Contexts.Close(h.root)
			case "reattach":
				binding.Attach("session-1")
			}
			if started, output := waitRemoteRunEvent(t, events), waitRemoteRunEvent(t, events); started.Type != RunStarted || output.Type != RunOutput {
				t.Fatalf("run events out of order: %+v %+v", started, output)
			}
			ended := waitRemoteRunEvent(t, events)
			if ended.Type != RunExited || ended.ExitCode != nil || ended.Signal != "" ||
				ended.Disconnected != (action == "reattach") || len(h.service.Runs.Active()) != 0 {
				t.Fatalf("end = %+v, active = %v", ended, h.service.Runs.Active())
			}
		})
	}
}

func TestRemoteRunReportsSignalWithoutExitCode(t *testing.T) {
	k := &remoteRunFixture{notifications: make(chan string, 1)}
	h, _, _, events := openRemoteRunFixture(t, k)
	backend := &BackendSession{
		host: h.service.Host, PluginID: runFixturePlugin, ready: true,
		Session: pluginbackend.Session{ID: "session-" + runFixturePlugin, Granted: []string{methodRunStart}},
	}
	h.service.Host.sessions[runFixturePlugin] = backend
	k.spawn = func(_ context.Context, _ core.RemoteProcessOpen, sink core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
		sink.Started(1, 42)
		signal := 15
		return core.RemoteProcessExit{Signal: &signal}, nil
	}
	response, refusal := respond(t, h.service, runFixturePlugin, "run/start", h.params(t, "remote", nil))
	id := startedRunID(t, response, refusal)
	started, ended := waitRemoteRunEvent(t, events), waitRemoteRunEvent(t, events)
	if started.Type != RunStarted || started.RunID != id || ended.Type != RunExited ||
		ended.RunID != id || ended.ExitCode != nil || ended.Signal != "15" || ended.Disconnected {
		t.Fatalf("remote signal events = %+v %+v", started, ended)
	}
	select {
	case notice := <-k.notifications:
		want := fmt.Sprintf("%s %s {\"runID\":%q,\"signal\":15}", backend.Session.ID, notifyRunDidExit, id)
		if notice != want {
			t.Fatalf("run exit notification = %s, want %s", notice, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the backend did not receive the run exit notification")
	}
}
