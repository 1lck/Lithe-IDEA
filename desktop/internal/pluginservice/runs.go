package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

const (
	methodRunStart   = pluginhost.MethodPrefix + "run/start"
	methodRunStop    = pluginhost.MethodPrefix + "run/stop"
	notifyRunDidExit = pluginhost.MethodPrefix + "run/didExit"

	// runDebugConnectTimeout bounds waiting for a debuggee to open the port the
	// backend named. A runtime that never listens must not hold the run forever.
	runDebugConnectTimeout = 30 * time.Second
	// runDebugPollInterval is how often the port is probed while waiting.
	runDebugPollInterval = 100 * time.Millisecond
	// runStopTimeout bounds waiting for a stopped run's process tree to be reaped.
	runStopTimeout = 10 * time.Second
	// runRerunTimeout bounds the backend function a rerun calls.
	runRerunTimeout = 60 * time.Second
)

// RunEventType names what happened to a run.
type RunEventType string

const (
	// RunStarted reports a run the host accepted; Label and Rerun are set.
	RunStarted RunEventType = "started"
	// RunOutput carries one chunk of the process's output in Text.
	RunOutput RunEventType = "output"
	// RunExited reports the end of the process; ExitCode or Signal is set.
	RunExited RunEventType = "exited"
)

// RunEvent is one change of a run the host presents. The observer receives it on
// a background goroutine and must hand it to its own thread.
type RunEvent struct {
	Type      RunEventType
	RunID     string
	PluginID  string
	Label     string
	Workspace string
	Text      string
	ExitCode  *int
	Signal    string
	// Rerun is set on RunStarted when the plugin supplied a rerun function.
	Rerun *RunRerun
}

// RunExecutable is a tool the host resolved for a run.
type RunExecutable struct {
	Path        string
	Environment map[string]string
}

// RunToolResolver resolves a tool definition the manifest requires, through the
// host's toolchain layers, for the workspace the run belongs to.
type RunToolResolver func(ctx context.Context, workspaceRoot, tool string) (RunExecutable, error)

// RunDebugRequest asks the host to attach a debug adapter to a running debuggee.
type RunDebugRequest struct {
	PluginID          string
	WorkspaceRoot     string
	Label             string
	ConfigurationType string
	Host              string
	Port              int
}

// RunDebugAttacher starts a debug session on the adapter a configuration type
// names. It returns the session's ID.
type RunDebugAttacher func(ctx context.Context, request RunDebugRequest) (string, error)

// RunDebugLaunchRequest asks the host to have the adapter a configuration type names
// start a run's process itself (`debug.target: {kind: "launch"}`). The process facts
// are the run's: the resolved program, its arguments, the absolute working directory
// and the environment the run declares.
type RunDebugLaunchRequest struct {
	PluginID          string
	WorkspaceRoot     string
	Label             string
	ConfigurationType string
	Executable        string
	Arguments         []string
	WorkingDirectory  string
	Environment       map[string]string
}

// RunDebugSession is a debug session that stands for a run: its ID, and a channel
// that receives the debuggee's exit code (nil when the adapter reported none) once
// the session has ended and been released.
type RunDebugSession struct {
	ID    string
	Ended <-chan *int
}

// RunDebugLauncher starts a launch debug session for a run.
type RunDebugLauncher func(ctx context.Context, request RunDebugLaunchRequest) (RunDebugSession, error)

// runProcess is what a run waits on and stops: the process the host started, or the
// debug session whose adapter started it.
type runProcess interface {
	Wait() error
	Stop()
}

// debugRunProcess is a launch-target run: stopping it ends the debug session, and it
// ends when the session does.
type debugRunProcess struct {
	ended <-chan *int
	stop  func()
}

// debugRunExit is a launch-target run's exit status.
type debugRunExit struct{ code *int }

func (e *debugRunExit) Error() string { return "the debug session ended" }

func (d *debugRunProcess) Wait() error {
	code := <-d.ended
	if code != nil && *code == 0 {
		return nil
	}
	return &debugRunExit{code: code}
}

func (d *debugRunProcess) Stop() { d.stop() }

// Runs owns the processes plugin backends start through run/start. The host owns
// the process, its output and its end; the backend only decides what to start.
type Runs struct {
	service *Service
	// Tools resolves {kind: "tool"} executables. A run that needs one fails with
	// plugin.host.toolUnresolved while it is nil.
	Tools RunToolResolver
	// Debug attaches the adapter of a run started with a connection debug target,
	// and LaunchDebug has the adapter start the process of one with a launch target.
	Debug       RunDebugAttacher
	LaunchDebug RunDebugLauncher
	// StartDebugSession and StopDebugSession serve lithe/host/debug/start and the
	// sessionID form of run/stop. Without a starter the method is unavailable.
	StartDebugSession DebugSessionStarter
	StopDebugSession  DebugSessionStopper
	// debugSessions maps a session a backend started to the plugin that owns it.
	debugSessions map[string]string

	mu       sync.Mutex
	observer func(RunEvent)
	runs     map[string]*hostRun
	closed   bool
	sequence atomic.Uint64
	wait     sync.WaitGroup
}

type hostRun struct {
	// pid is the root process of a started run, recorded in the ledger while it lives.
	pid       int
	id        string
	pluginID  string
	backend   string
	workspace WorkspaceContext
	start     core.RunStart
	process   runProcess
	cancel    context.CancelFunc
	temporary string
	debug     atomic.Pointer[string]
	stopped   atomic.Bool
	done      chan struct{}
}

func newRuns(service *Service) *Runs {
	return &Runs{service: service, runs: make(map[string]*hostRun), debugSessions: make(map[string]string)}
}

// SetObserver installs the function that receives run events. It replaces any
// earlier observer; nil stops delivery.
func (r *Runs) SetObserver(observer func(RunEvent)) {
	r.mu.Lock()
	r.observer = observer
	r.mu.Unlock()
}

func (r *Runs) emit(event RunEvent) {
	r.mu.Lock()
	observer := r.observer
	r.mu.Unlock()
	if observer != nil {
		observer(event)
	}
}

// Active lists the IDs of the runs still going, for tests and shutdown.
func (r *Runs) Active() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	ids := make([]string, 0, len(r.runs))
	for id := range r.runs {
		ids = append(ids, id)
	}
	return ids
}

// Stop ends one run and waits, bounded, for its process tree. An unknown or
// finished run is not an error.
func (r *Runs) Stop(runID string) {
	r.mu.Lock()
	run := r.runs[runID]
	r.mu.Unlock()
	if run == nil {
		return
	}
	r.stopRun(run)
}

func (r *Runs) stopRun(run *hostRun) {
	run.stopped.Store(true)
	run.cancel()
	run.process.Stop()
	select {
	case <-run.done:
	case <-time.After(runStopTimeout):
	}
}

// StopWorkspace ends every run of one workspace, as closing the project does.
func (r *Runs) StopWorkspace(path string) {
	r.mu.Lock()
	var stopping []*hostRun
	for _, run := range r.runs {
		if filepath.Clean(run.workspace.Path) == filepath.Clean(path) {
			stopping = append(stopping, run)
		}
	}
	r.mu.Unlock()
	for _, run := range stopping {
		r.stopRun(run)
	}
}

// StopAll ends every run and refuses new ones, for application shutdown.
func (r *Runs) StopAll() {
	r.mu.Lock()
	r.closed = true
	stopping := make([]*hostRun, 0, len(r.runs))
	for _, run := range r.runs {
		stopping = append(stopping, run)
	}
	r.mu.Unlock()
	for _, run := range stopping {
		r.stopRun(run)
	}
	r.wait.Wait()
}

type runStartParams struct {
	Context        ContextRef        `json:"context"`
	TemporaryFiles []json.RawMessage `json:"temporaryFiles"`
}

// handleStart answers lithe/host/run/start.
func (r *Runs) handleStart(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request runStartParams
	if err := json.Unmarshal(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	workspace, err := r.service.Contexts.Lookup(request.Context)
	if err != nil {
		return nil, contextFailure(err)
	}
	entry, manifest, err := r.service.installedPlugin(ctx, caller.PluginID)
	if err != nil {
		return nil, failure(pluginhost.CodeHostFailure, err.Error())
	}
	temporary := ""
	if len(request.TemporaryFiles) > 0 {
		// The host's own temporary directory: the plugin never learns where it is,
		// and it is removed when the run ends.
		temporary, err = os.MkdirTemp("", "lithe-run-")
		if err != nil {
			return nil, failure(pluginhost.CodeHostFailure, "the run's temporary directory cannot be created")
		}
	}
	cleanup := func() {
		if temporary != "" {
			_ = os.RemoveAll(temporary)
		}
	}
	start, err := r.service.kernel.DecodeRunStart(ctx, manifest, workspace.Path, temporary, params)
	if err != nil {
		cleanup()
		return nil, runStartFailure(err)
	}
	launch := start.Debug != nil && start.Debug.Target.Kind == "launch"
	if start.Debug != nil && start.Debug.Target.Kind != "connection" && !launch {
		cleanup()
		return nil, failure("plugin.host.unavailable", "This host does not serve the debug target.")
	}
	if launch && r.LaunchDebug == nil {
		cleanup()
		return nil, failure("plugin.host.unavailable", "This host starts no debug sessions.")
	}
	executable, environment, refusal := r.resolveExecutable(ctx, entry, workspace.Path, start)
	if refusal != nil {
		cleanup()
		return nil, refusal
	}
	for _, file := range start.TemporaryFiles {
		if err := os.WriteFile(file.Path, []byte(file.Contents), 0o600); err != nil {
			cleanup()
			return nil, failure(pluginhost.CodeHostFailure, "a temporary file cannot be written")
		}
	}
	for key, value := range start.Environment {
		environment[key] = value
	}
	// An app started from Finder has launchd's PATH; the run gets the user's shell PATH
	// unless the plugin or the tool chose one.
	if _, set := environment["PATH"]; !set {
		if path := loginenv.Path(); path != "" {
			environment["PATH"] = path
		}
	}
	runCtx, cancel := context.WithCancel(context.Background())
	run := &hostRun{
		id:        fmt.Sprintf("run-%d", r.sequence.Add(1)),
		pluginID:  caller.PluginID,
		backend:   caller.SessionID,
		workspace: workspace,
		start:     start,
		cancel:    cancel,
		temporary: temporary,
		done:      make(chan struct{}),
	}
	// Output is delivered only after the started event, so an observer never sees
	// a run's text before it knows the run.
	started := make(chan struct{})
	workingDirectory := filepath.Join(workspace.Path, filepath.FromSlash(start.WorkingDirectory))
	var process runProcess
	if launch {
		// The adapter starts the process: the run stands for the debug session, its
		// output is the Debug console's, and stopping the run stops the session.
		session, err := r.LaunchDebug(ctx, RunDebugLaunchRequest{
			PluginID: run.pluginID, WorkspaceRoot: workspace.Path, Label: start.Label,
			ConfigurationType: start.Debug.ConfigurationType, Executable: executable,
			Arguments: start.Arguments, WorkingDirectory: workingDirectory, Environment: environment,
		})
		if err != nil {
			cancel()
			cleanup()
			return nil, failure(pluginhost.CodeHostFailure, err.Error())
		}
		run.debug.Store(&session.ID)
		stop := r.StopDebugSession
		process = &debugRunProcess{ended: session.Ended, stop: func() {
			if stop != nil {
				stop(session.ID)
			}
		}}
	} else {
		// A JDK launch whose class path would overflow the command line starts with an
		// argument file in the run's temporary directory, removed when the run ends.
		arguments := start.Arguments
		if plan, ok := planJavaArgumentFile(executable, start.Arguments); ok {
			if temporary == "" {
				temporary, err = os.MkdirTemp("", "lithe-run-")
				if err != nil {
					cancel()
					cleanup()
					return nil, failure(pluginhost.CodeHostFailure, "the run's temporary directory cannot be created")
				}
			}
			path, err := writeArgumentFile(temporary, plan.contents)
			if err != nil {
				cancel()
				cleanup()
				return nil, failure(pluginhost.CodeHostFailure, "the run's argument file cannot be written")
			}
			arguments = plan.withFile(path)
		}
		spawned, err := buildprocess.Start(runCtx, buildprocess.Spec{
			Executable:       executable,
			Arguments:        arguments,
			WorkingDirectory: workingDirectory,
			Environment:      environment,
		}, func(_ buildprocess.Stream, text string) {
			<-started
			r.emit(RunEvent{Type: RunOutput, RunID: run.id, PluginID: run.pluginID, Text: text})
		})
		if err != nil {
			cancel()
			cleanup()
			return nil, failure(pluginhost.CodeHostFailure, err.Error())
		}
		process = spawned
	}
	run.process = process
	if owned, ok := process.(interface{ Pid() int }); ok {
		run.pid = owned.Pid()
		_ = r.service.ledger.Add(run.pid)
	}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		// The host is shutting down: end the process that just started.
		process.Stop()
		_ = process.Wait()
		close(started)
		cancel()
		cleanup()
		return nil, failure("plugin.host.unavailable", "The host is shutting down.")
	}
	r.runs[run.id] = run
	r.wait.Add(1)
	r.mu.Unlock()
	event := RunEvent{Type: RunStarted, RunID: run.id, PluginID: run.pluginID, Label: start.Label, Workspace: workspace.Path}
	if start.Rerun != nil {
		event.Rerun = &RunRerun{PluginID: run.pluginID, Function: start.Rerun.Function, Data: start.Rerun.Data, Workspace: workspace.Path}
	}
	r.emit(event)
	close(started)
	go r.supervise(run)
	if start.Debug != nil && !launch {
		go r.attachDebugger(runCtx, run)
	}
	return marshalResult(map[string]string{"runID": run.id})
}

// resolveExecutable turns the decoded executable reference into a program. A
// packaged file is verified against the installed package, never the workspace.
func (r *Runs) resolveExecutable(ctx context.Context, entry pluginmanager.Entry, workspaceRoot string, start core.RunStart) (string, map[string]string, *pluginhost.Failure) {
	environment := map[string]string{}
	switch start.Executable.Kind {
	case "packaged":
		path, err := pluginhost.ResolveExecutable(entry.Installed.Path, start.Executable.Value)
		if err != nil {
			return "", nil, failure("plugin.host.invalidParams", err.Error())
		}
		return path, environment, nil
	case "toolchain":
		if r.Tools == nil {
			return "", nil, failure("plugin.host.toolUnresolved", "This host resolves no tools.")
		}
		resolved, err := r.Tools(ctx, workspaceRoot, start.Executable.Value)
		if err != nil || resolved.Path == "" {
			message := "The tool resolves to no executable."
			if err != nil {
				message = err.Error()
			}
			return "", nil, failure("plugin.host.toolUnresolved", message)
		}
		for key, value := range resolved.Environment {
			environment[key] = value
		}
		return resolved.Path, environment, nil
	}
	return "", nil, failure("plugin.host.invalidParams", "The executable kind is unknown.")
}

// runStartFailure maps a Core refusal to the contract's failure: the code is
// plugin.host.invalidParams and Core's own code and field travel in details.
func runStartFailure(err error) *pluginhost.Failure {
	var rejection *core.MarketplaceRejection
	if errors.As(err, &rejection) {
		details, _ := json.Marshal(map[string]string{"code": rejection.Code, "field": rejection.Field})
		return &pluginhost.Failure{Code: "plugin.host.invalidParams", Message: rejection.Message, Details: details}
	}
	return failure(pluginhost.CodeHostFailure, err.Error())
}

// supervise waits for the process, reports its end and tells the backend that
// started it, when that same backend session is still running.
func (r *Runs) supervise(run *hostRun) {
	defer r.wait.Done()
	err := run.process.Wait()
	_ = r.service.ledger.Remove(run.pid)
	run.cancel()
	if run.temporary != "" {
		_ = os.RemoveAll(run.temporary)
	}
	code, signal := exitStatus(err)
	if run.stopped.Load() && code == nil && signal == "" {
		// Stopping a run that was already gone ends it without a status of its own.
		zero := 0
		code = &zero
	}
	r.mu.Lock()
	delete(r.runs, run.id)
	r.mu.Unlock()
	close(run.done)
	r.emit(RunEvent{Type: RunExited, RunID: run.id, PluginID: run.pluginID, ExitCode: code, Signal: signal})
	r.notifyExit(run, code, signal)
}

func (r *Runs) notifyExit(run *hostRun, code *int, signal string) {
	session := r.service.Host.Running(run.pluginID)
	if session == nil || session.Session.ID != run.backend {
		return
	}
	body := map[string]any{"runID": run.id}
	if code != nil {
		body["exitCode"] = *code
	}
	if signal != "" {
		body["signal"] = signal
	}
	params, err := json.Marshal(body)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r.service.Host.Notify(ctx, run.pluginID, methodRunStart, notifyRunDidExit, params)
}

// exitStatus separates a normal exit code from a terminating signal. A process
// that could not report either has neither.
func exitStatus(err error) (*int, string) {
	if err == nil {
		code := 0
		return &code, ""
	}
	var debugEnd *debugRunExit
	if errors.As(err, &debugEnd) {
		return debugEnd.code, ""
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if code := exit.ExitCode(); code >= 0 {
			return &code, ""
		}
		if state := exit.ProcessState; state != nil {
			if _, signal, found := strings.Cut(state.String(), "signal: "); found {
				return nil, strings.TrimSpace(signal)
			}
		}
	}
	return nil, ""
}

// attachDebugger waits for the debuggee's port, then asks the host to attach the
// adapter. A debuggee that never listens, or an adapter that cannot attach, ends
// the run instead of leaving a process nobody can debug.
func (r *Runs) attachDebugger(ctx context.Context, run *hostRun) {
	port := run.start.Debug.Target.Port
	fail := func(err error) {
		if ctx.Err() == nil {
			r.emit(RunEvent{Type: RunOutput, RunID: run.id, PluginID: run.pluginID, Text: err.Error() + "\n"})
			r.stopRun(run)
		}
	}
	if err := waitForPort(ctx, port, run.done, runDebugConnectTimeout); err != nil {
		fail(err)
		return
	}
	if r.Debug == nil {
		fail(errors.New("this host starts no debug sessions"))
		return
	}
	session, err := r.Debug(ctx, RunDebugRequest{
		PluginID: run.pluginID, WorkspaceRoot: run.workspace.Path, Label: run.start.Label,
		ConfigurationType: run.start.Debug.ConfigurationType, Host: "127.0.0.1", Port: port,
	})
	if err != nil {
		fail(err)
		return
	}
	run.debug.Store(&session)
}

// waitForPort polls a loopback port until something accepts, the run ends, or the
// timeout passes.
func waitForPort(ctx context.Context, port int, ended <-chan struct{}, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(runDebugPollInterval)
	defer ticker.Stop()
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	for {
		dialer := net.Dialer{Timeout: time.Second}
		connection, err := dialer.DialContext(ctx, "tcp", address)
		if err == nil {
			_ = connection.Close()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ended:
			return errors.New("the process ended before its debug port opened")
		case <-deadline.C:
			return fmt.Errorf("the debug port %d did not open in time", port)
		case <-ticker.C:
		}
	}
}

type runStopParams struct {
	RunID     string `json:"runID"`
	SessionID string `json:"sessionID"`
}

// handleStop answers lithe/host/run/stop. A backend stops only what it started,
// and a run that already ended is the same null answer.
func (r *Runs) handleStop(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request runStopParams
	if err := json.Unmarshal(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	if (request.RunID == "") == (request.SessionID == "") {
		return nil, invalidParams(errors.New("name either runID or sessionID"))
	}
	r.mu.Lock()
	var target *hostRun
	for id, run := range r.runs {
		if run.pluginID != caller.PluginID {
			continue
		}
		if id == request.RunID {
			target = run
		}
		if session := run.debug.Load(); session != nil && *session == request.SessionID && request.SessionID != "" {
			target = run
		}
	}
	r.mu.Unlock()
	if target != nil {
		r.stopRun(target)
	} else if request.SessionID != "" {
		r.stopDebugSession(caller.PluginID, request.SessionID)
	}
	return nil, nil
}

// Rerun asks the plugin to start the run again: the host calls the function the
// original start named, with the data it carried and the workspace's current
// context, and the backend answers with a new run/start.
func (r *Runs) Rerun(ctx context.Context, run RunRerun) error {
	workspace, ok := r.service.Contexts.ByPath(run.Workspace)
	if !ok {
		return ErrContextExpired
	}
	reference, err := json.Marshal(workspace.ContextRef)
	if err != nil {
		return err
	}
	_, err = r.service.Host.Call(ctx, run.PluginID, run.Function, run.Data, reference, runRerunTimeout)
	return err
}

// RunRerun names the function and data a rerun calls, as the start carried them.
type RunRerun struct {
	PluginID  string
	Function  string
	Data      json.RawMessage
	Workspace string
}

// installedPlugin finds an enabled plugin's directory entry and its manifest.
func (s *Service) installedPlugin(ctx context.Context, pluginID string) (pluginmanager.Entry, json.RawMessage, error) {
	entries, err := s.Manager.Installed()
	if err != nil {
		return pluginmanager.Entry{}, nil, err
	}
	selected, _ := s.selectInstalled(ctx, entries, false)
	for _, entry := range selected {
		if entry.Installed.ID != pluginID {
			continue
		}
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			return pluginmanager.Entry{}, nil, err
		}
		return entry, manifest, nil
	}
	return pluginmanager.Entry{}, nil, fmt.Errorf("%w: %s", ErrBackendUnavailable, pluginID)
}
