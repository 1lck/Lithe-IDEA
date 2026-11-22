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
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
)

const (
	methodRunStart   = pluginhost.MethodPrefix + "run/start"
	methodRunStop    = pluginhost.MethodPrefix + "run/stop"
	notifyRunDidExit = pluginhost.MethodPrefix + "run/didExit"

	// RunDebugConnectTimeout bounds waiting for a debuggee to open the port its
	// run listens on. A runtime that never listens must not hold the run forever.
	RunDebugConnectTimeout = 30 * time.Second
	// runDebugPollInterval is how often the port is probed while waiting.
	runDebugPollInterval = 100 * time.Millisecond
	// runStopTimeout bounds waiting, beyond the stop time, for a stopped run's process tree to be reaped.
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
	Remote    bool
	Text      string
	// OutputEncoding is the process's declaration, set on RunStarted before any output.
	OutputEncoding string
	ExitCode       *int
	Signal         string
	Disconnected   bool
	// Rerun is set on RunStarted when the plugin supplied a rerun function.
	Rerun *RunRerun
	// PID is the run's root process on RunStarted, 0 when it has none (a debug launch).
	PID int
	// DebugPort is the loopback debugger port when started for connection debugging, 0 otherwise.
	DebugPort int
}

// RunExecutable is a tool the host resolved for a run.
type RunExecutable struct {
	Path        string
	Environment map[string]string
	PathPrepend []string
}

// RunToolResolver resolves a tool definition the manifest requires, through the
// host's toolchain layers, for the workspace the run belongs to.
type RunToolResolver func(ctx context.Context, workspaceRoot, directory, tool string) (RunExecutable, error)

// RunDebugRequest asks the host to attach a debug adapter to a running debuggee.
type RunDebugRequest struct {
	PluginID          string
	WorkspaceRoot     string
	Label             string
	ConfigurationType string
	Host              string
	Port              int
	Connection        *core.RemoteWorkspaceConnection
	// StopRun ends the host-owned process when its attached debug session is
	// released. It requests bounded cleanup off the UI thread; another owner
	// already stopping the run keeps its grace and remains responsible for waiting.
	StopRun func()
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
	Connection        *core.RemoteWorkspaceConnection
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
// debug session whose adapter started it. Stop asks it to end within the stop time and
// Kill ends it at once.
type runProcess interface {
	Wait() error
	Stop()
	Kill()
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

// Kill ends the debug session as Stop does: the session owns how its adapter ends.
func (d *debugRunProcess) Kill() { d.stop() }

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
	pid        int
	id         string
	pluginID   string
	backend    string
	workspace  WorkspaceContext
	connection *core.RemoteWorkspaceConnection
	start      core.RunStart
	process    runProcess
	cancel     context.CancelFunc
	detach     func()
	cleanup    func()
	debug      atomic.Pointer[string]
	stopped    atomic.Bool
	done       chan struct{}
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
	r.stopRun(run, true)
}

// stopRun stops a run and waits, bounded, for its process tree. The tree first gets the
// stop time to end on its own (buildprocess.StopGrace). Stopping a run that is already
// stopping kills it only for a repeated explicit request; automatic cleanup is
// idempotent, so closing a workspace and its debug session preserve the grace.
func (r *Runs) stopRun(run *hostRun, forceIfStopping bool) {
	if run.stopped.Swap(true) {
		if forceIfStopping {
			run.process.Kill()
		}
		return
	}
	run.cancel()
	run.process.Stop()
	select {
	case <-run.done:
	case <-time.After(buildprocess.StopGrace() + runStopTimeout):
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
		r.stopRun(run, false)
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
		r.stopRun(run, false)
	}
	r.wait.Wait()
}

type runStartParams struct {
	Context        ContextRef        `json:"context"`
	TemporaryFiles []json.RawMessage `json:"temporaryFiles"`
	Process        struct {
		Placement json.RawMessage `json:"placement"`
	} `json:"process"`
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
	remote, refusal := r.captureRemoteRun(workspace)
	if refusal != nil {
		return nil, refusal
	}
	if remote != nil {
		if refusal := remote.refusal(ctx); refusal != nil {
			return nil, refusal
		}
	}

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil, runHostClosing()
	}
	r.wait.Add(1)
	r.mu.Unlock()
	defer r.wait.Done()

	entry, manifest, err := r.service.installedPlugin(ctx, caller.PluginID)
	if err != nil {
		return nil, failure(pluginhost.CodeHostFailure, err.Error())
	}
	runCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	run := &hostRun{
		id:        fmt.Sprintf("run-%d", r.sequence.Add(1)),
		pluginID:  caller.PluginID,
		backend:   caller.SessionID,
		workspace: workspace,
		cancel:    cancel,
		done:      make(chan struct{}),
	}
	if remote != nil {
		run.connection = remote.connection
		stopDetach := remote.connection.AfterDetach(run.cancel)
		stopClose := context.AfterFunc(workspace.lifetime, run.cancel)
		run.detach = func() {
			stopDetach()
			stopClose()
		}
	}
	accepted := false
	defer func() {
		if !accepted {
			run.release()
		}
	}()

	// Cancellation of the startup request ends a pending launch. Once admitted,
	// the workbench owns the run, including when the calling backend exits.
	started := make(chan struct{})
	output := func(_ buildprocess.Stream, text string) {
		<-started
		if accepted {
			r.emit(RunEvent{Type: RunOutput, RunID: run.id, PluginID: run.pluginID, Text: text})
		}
	}
	var process runProcess
	var launch bool
	// This only selects where to allocate scratch. Core validates the full
	// process declaration before either branch resolves or starts a program.
	var placement core.ProcessPlacement
	_ = json.Unmarshal(request.Process.Placement, &placement)
	if remote != nil && placement != core.ProcessPlacementUI {
		process, launch, refusal = r.startRemote(ctx, runCtx, run, remote, entry, manifest, request, params, output)
	} else {
		process, launch, refusal = r.startLocal(ctx, runCtx, run, remote, entry, manifest, request, params, output)
	}
	if refusal != nil {
		close(started)
		return nil, refusal
	}

	run.process = process
	if owned, ok := process.(interface{ Pid() int }); ok && owned.Pid() > 0 {
		run.pid = owned.Pid()
		r.recordRunIssue(ctx, r.service.ledger.Add(run.pid))
	}
	r.mu.Lock()
	switch {
	case r.closed:
		refusal = runHostClosing()
	case remote != nil:
		refusal = remote.refusal(ctx)
	}
	if refusal != nil {
		r.mu.Unlock()
		// Release the output readers before waiting for a refused process.
		close(started)
		process.Stop()
		err := process.Wait()
		if code, signal := exitStatus(err); err != nil && code == nil && signal == 0 && !errors.Is(err, context.Canceled) {
			r.recordRunIssue(ctx, err)
		}
		r.recordRunIssue(ctx, r.service.ledger.Remove(run.pid))
		return nil, refusal
	}
	r.runs[run.id] = run
	r.wait.Add(1)
	r.mu.Unlock()
	start := run.start
	event := RunEvent{Type: RunStarted, RunID: run.id, PluginID: run.pluginID, Label: start.Label, Workspace: workspace.Path, PID: run.pid, OutputEncoding: start.OutputEncoding, Remote: remote != nil && start.Placement != core.ProcessPlacementUI}
	if start.Debug != nil && start.Debug.Target.Kind == "connection" && start.Debug.Target.Port > 0 {
		event.DebugPort = start.Debug.Target.Port
	}
	if start.Rerun != nil {
		event.Rerun = &RunRerun{PluginID: run.pluginID, Function: start.Rerun.Function, Data: start.Rerun.Data, Workspace: workspace.Path}
	}
	r.emit(event)
	accepted = true
	close(started)
	go r.supervise(run)
	if start.Debug != nil && !launch {
		go r.attachDebugger(runCtx, run)
	}
	return marshalResult(map[string]string{"runID": run.id})
}

func runHostClosing() *pluginhost.Failure {
	return failure("plugin.host.unavailable", "The host is shutting down.")
}

func (r *Runs) startLocal(ctx, runCtx context.Context, run *hostRun, remote *remoteRun, entry pluginmanager.Entry, manifest json.RawMessage, request runStartParams, params json.RawMessage, output func(buildprocess.Stream, string)) (runProcess, bool, *pluginhost.Failure) {
	decodeCtx := ctx
	if remote != nil {
		setup, cancel := context.WithCancel(ctx)
		defer cancel()
		stop := context.AfterFunc(runCtx, cancel)
		defer stop()
		ctx = core.WithoutRemoteWorkspace(setup)
		decodeCtx = remote.connection.Context(setup)
	}
	temporary := ""
	var err error
	if len(request.TemporaryFiles) > 0 {
		temporary, err = os.MkdirTemp("", "lithe-run-")
		if err != nil {
			return nil, false, failure(pluginhost.CodeHostFailure, "the run's temporary directory cannot be created")
		}
		run.cleanup = func() { r.recordRunIssue(ctx, os.RemoveAll(temporary)) }
	}
	start, err := r.service.kernel.DecodeRunStart(decodeCtx, manifest, run.workspace.Path, temporary, params)
	if err != nil {
		if remote != nil {
			return nil, false, remote.startFailure(ctx, err)
		}
		return nil, false, runStartFailure(err)
	}
	run.start = start
	executionRoot := run.workspace.Path
	if remote != nil {
		if refusal := remote.refusal(ctx); refusal != nil {
			return nil, false, refusal
		}
		if start.Placement != core.ProcessPlacementUI || start.Debug != nil {
			return nil, false, unsupportedRemoteWorkspace()
		}
		executionRoot, err = r.service.contextState(run.pluginID, run.workspace)
		if err != nil {
			return nil, false, failure(pluginhost.CodeHostFailure, err.Error())
		}
	}
	launch := start.Debug != nil && start.Debug.Target.Kind == "launch"
	if start.Debug != nil && start.Debug.Target.Kind != "connection" && !launch {
		return nil, false, failure("plugin.host.unavailable", "This host does not serve the debug target.")
	}
	if launch && r.LaunchDebug == nil {
		return nil, false, failure("plugin.host.unavailable", "This host starts no debug sessions.")
	}
	executable, refusal := r.resolveExecutable(ctx, entry, executionRoot, start)
	if refusal != nil {
		return nil, false, refusal
	}
	for _, file := range start.TemporaryFiles {
		data, err := file.Bytes()
		if err == nil {
			err = os.WriteFile(file.Path, data, 0o600)
		}
		if err != nil {
			return nil, false, failure(pluginhost.CodeHostFailure, "a temporary file cannot be written")
		}
	}
	environment := runEnvironment(executable.Environment, start.Environment)
	// An app started from Finder has launchd's PATH. Give the local run the
	// user's shell PATH unless the plugin or the tool chose one.
	if _, set := environment["PATH"]; !set {
		if path := loginenv.Path(); path != "" {
			environment["PATH"] = path
		}
	}
	workingDirectory := filepath.Join(executionRoot, filepath.FromSlash(start.WorkingDirectory))
	if remote != nil {
		if refusal := remote.refusal(ctx); refusal != nil {
			return nil, false, refusal
		}
	}
	if launch {
		process, err := r.startDebugLaunch(ctx, run, executable.Path, workingDirectory, environment)
		if err != nil {
			return nil, false, failure(pluginhost.CodeHostFailure, err.Error())
		}
		return process, true, nil
	}
	spawned, err := buildprocess.Start(runCtx, buildprocess.Spec{
		Executable: executable.Path, Arguments: start.Arguments,
		WorkingDirectory: workingDirectory, Environment: environment,
	}, output)
	if err != nil {
		return nil, false, failure(pluginhost.CodeHostFailure, err.Error())
	}
	return spawned, false, nil
}

func (r *Runs) startDebugLaunch(ctx context.Context, run *hostRun, executable, directory string, environment map[string]string) (runProcess, error) {
	start := run.start
	session, err := r.LaunchDebug(ctx, RunDebugLaunchRequest{
		PluginID: run.pluginID, WorkspaceRoot: run.workspace.Path, Label: start.Label,
		ConfigurationType: start.Debug.ConfigurationType, Executable: executable,
		Arguments: start.Arguments, WorkingDirectory: directory, Environment: environment,
		Connection: run.connection,
	})
	if err != nil {
		return nil, err
	}
	run.debug.Store(&session.ID)
	stop := r.StopDebugSession
	return &debugRunProcess{ended: session.Ended, stop: func() {
		if stop != nil {
			stop(session.ID)
		}
	}}, nil
}

// resolveExecutable turns a local executable reference into a program. A
// packaged file is verified against the installed package.
func (r *Runs) resolveExecutable(ctx context.Context, entry pluginmanager.Entry, workspaceRoot string, start core.RunStart) (RunExecutable, *pluginhost.Failure) {
	switch start.Executable.Kind {
	case "packaged":
		path, err := pluginhost.ResolveExecutable(entry.Installed.Path, start.Executable.Value)
		if err != nil {
			return RunExecutable{}, failure("plugin.host.invalidParams", err.Error())
		}
		return RunExecutable{Path: path}, nil
	case "toolchain":
		return r.resolveTool(ctx, workspaceRoot, ".", start.Executable.Value)
	default:
		return RunExecutable{}, failure("plugin.host.invalidParams", "The executable kind is unknown.")
	}
}

func (r *Runs) resolveTool(ctx context.Context, workspaceRoot, directory, tool string) (RunExecutable, *pluginhost.Failure) {
	if r.Tools == nil {
		return RunExecutable{}, failure("plugin.host.toolUnresolved", "This host resolves no tools.")
	}
	resolved, err := r.Tools(ctx, workspaceRoot, directory, tool)
	if err != nil {
		return RunExecutable{}, failure("plugin.host.toolUnresolved", err.Error())
	}
	if resolved.Path == "" {
		return RunExecutable{}, failure("plugin.host.toolUnresolved", "The tool resolves to no executable.")
	}
	return resolved, nil
}

func runEnvironment(defaults, overrides map[string]string) map[string]string {
	environment := make(map[string]string, len(defaults)+len(overrides))
	for key, value := range defaults {
		environment[key] = value
	}
	for key, value := range overrides {
		environment[key] = value
	}
	return environment
}

func (run *hostRun) release() {
	run.cancel()
	if run.detach != nil {
		run.detach()
	}
	if run.cleanup != nil {
		run.cleanup()
	}
}

func (r *Runs) recordRunIssue(ctx context.Context, err error) {
	if err != nil && r.service.RuntimeIssue != nil {
		r.service.RuntimeIssue(ctx, err)
	}
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
	r.recordRunIssue(context.Background(), r.service.ledger.Remove(run.pid))
	run.release()
	code, signal := exitStatus(err)
	disconnected := run.connection != nil && code == nil && signal == 0 && err != nil && (remoteRunDisconnected(err) || !run.connection.IsCurrent())
	var debugExit *debugRunExit
	if run.connection != nil && code == nil && signal == 0 && err != nil && !disconnected &&
		!errors.Is(err, context.Canceled) && !errors.As(err, &debugExit) {
		r.recordRunIssue(context.Background(), err)
	}
	if run.connection == nil && run.stopped.Load() && code == nil && signal == 0 {
		// Stopping a run that was already gone ends it without a status of its own.
		zero := 0
		code = &zero
	}
	r.mu.Lock()
	delete(r.runs, run.id)
	r.mu.Unlock()
	close(run.done)
	signalLabel := ""
	if signal != 0 {
		if run.connection != nil && run.start.Placement != core.ProcessPlacementUI {
			// The same signal number can mean different things on the two hosts.
			signalLabel = strconv.Itoa(signal)
		} else {
			signalLabel = syscall.Signal(signal).String()
		}
	}
	r.emit(RunEvent{Type: RunExited, RunID: run.id, PluginID: run.pluginID, ExitCode: code, Signal: signalLabel, Disconnected: disconnected})
	r.notifyExit(run, code, signal)
}

func (r *Runs) notifyExit(run *hostRun, code *int, signal int) {
	session := r.service.Host.Running(run.pluginID)
	if session == nil || session.Session.ID != run.backend {
		return
	}
	body := map[string]any{"runID": run.id}
	if code != nil {
		body["exitCode"] = *code
	}
	if signal > 0 && signal <= 127 {
		body["signal"] = signal
	}
	params, err := json.Marshal(body)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	session.notify(ctx, methodRunStart, notifyRunDidExit, params)
}

// exitStatus separates a normal exit code from a terminating signal. A process
// that could not report either has neither.
func exitStatus(err error) (*int, int) {
	if err == nil {
		code := 0
		return &code, 0
	}
	var debugEnd *debugRunExit
	if errors.As(err, &debugEnd) {
		return debugEnd.code, 0
	}
	var remoteEnd *buildprocess.RemoteExit
	if errors.As(err, &remoteEnd) {
		if remoteEnd.Status.Signal != nil {
			return nil, *remoteEnd.Status.Signal
		}
		return remoteEnd.Status.ExitCode, 0
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if code := exit.ExitCode(); code >= 0 {
			return &code, 0
		}
		if state := exit.ProcessState; state != nil {
			if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
				return nil, int(status.Signal())
			}
		}
	}
	return nil, 0
}

// attachDebugger waits for the debuggee's port, then asks the host to attach the
// adapter. A debuggee that never listens, or an adapter that cannot attach, ends
// the run instead of leaving a process nobody can debug.
func (r *Runs) attachDebugger(ctx context.Context, run *hostRun) {
	port := run.start.Debug.Target.Port
	fail := func(err error) {
		if ctx.Err() == nil {
			r.emit(RunEvent{Type: RunOutput, RunID: run.id, PluginID: run.pluginID, Text: err.Error() + "\n"})
			r.stopRun(run, false)
		}
	}
	reader, _ := r.service.kernel.(remoteDebugPortReader)
	err := WaitForOwnedDebugPort(attachedRunContext(ctx, run.connection), reader, run.process, port, run.done)
	if err != nil {
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
		Connection: run.connection,
		StopRun:    func() { r.stopRun(run, false) },
	})
	if err != nil {
		fail(err)
		return
	}
	run.debug.Store(&session)
	<-ctx.Done()
	if r.StopDebugSession != nil {
		r.StopDebugSession(session)
	}
}

func attachedRunContext(ctx context.Context, connection *core.RemoteWorkspaceConnection) context.Context {
	if connection != nil {
		return connection.Context(ctx)
	}
	return ctx
}

type remoteDebugPortReader interface {
	RemoteProcessDebugPortReady(context.Context, uint64, int) (bool, error)
}

// WaitForOwnedDebugPort observes a Run-owned process's listener on its host.
func WaitForOwnedDebugPort(ctx context.Context, reader remoteDebugPortReader, process interface{ Wait() error }, port int, ended <-chan struct{}) error {
	if remote, ok := process.(*buildprocess.RemoteProcess); ok {
		if reader == nil {
			return errors.New("this host cannot inspect remote debug ports")
		}
		return waitForDebugPort(ctx, port, ended, RunDebugConnectTimeout, func(ctx context.Context) (bool, error) {
			return reader.RemoteProcessDebugPortReady(ctx, remote.ID, port)
		})
	}
	local, ok := process.(interface{ Pid() int })
	if !ok || local.Pid() <= 0 {
		return errors.New("the debuggee has no local process")
	}
	return waitForDebugPort(ctx, port, ended, RunDebugConnectTimeout, func(context.Context) (bool, error) {
		return debuggeeListening(local.Pid(), uint16(port))
	})
}

// ErrDebuggeeEnded and ErrDebugPortTimeout are why WaitForDebugPort gave up: the
// debuggee's process ended, or its port did not open within the timeout.
var (
	ErrDebuggeeEnded    = errors.New("the process ended before its debug port opened")
	ErrDebugPortTimeout = errors.New("the debug port did not open in time")
)

// WaitForDebugPort polls a debuggee's loopback port until something accepts, ended
// is closed, or the timeout passes. The probe connects and closes without a
// handshake; a runtime suspended for a debugger keeps listening after it.
func WaitForDebugPort(ctx context.Context, port int, ended <-chan struct{}, timeout time.Duration) error {
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	return waitForDebugPort(ctx, port, ended, timeout, func(ctx context.Context) (bool, error) {
		dialer := net.Dialer{Timeout: time.Second}
		connection, err := dialer.DialContext(ctx, "tcp", address)
		if err != nil {
			// log-exempt: 预期的缺失：目标还没监听时继续等待，超时由调用方处理。
			return false, nil
		}
		// log-exempt: best-effort 清理：探测连接没有要送达的数据。
		_ = connection.Close()
		return true, nil
	})
}

// A connection probe can consume a debuggee's first handshake. For host-owned
// runs, observe the listener through the OS and leave the first connection to DAP.
func debuggeeListening(pid int, port uint16) (bool, error) {
	processes, err := sysinfo.Processes(sysinfo.Options{})
	if err != nil {
		return false, err
	}
	sockets, err := sysinfo.ListeningSockets(sysinfo.ProcessTreeIDs(pid, processes))
	if err != nil {
		return false, err
	}
	for _, socket := range sockets {
		if socket.Port == port {
			return true, nil
		}
	}
	return false, nil
}

func waitForDebugPort(ctx context.Context, port int, ended <-chan struct{}, timeout time.Duration, ready func(context.Context) (bool, error)) error {
	probeContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ticker := time.NewTicker(runDebugPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ended:
			return ErrDebuggeeEnded
		case <-probeContext.Done():
			return fmt.Errorf("%w (port %d)", ErrDebugPortTimeout, port)
		default:
		}
		listening, err := ready(probeContext)
		if err != nil {
			return err
		}
		if listening {
			return nil
		}
		select {
		case <-probeContext.Done():
		case <-ended:
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
		r.stopRun(target, true)
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
