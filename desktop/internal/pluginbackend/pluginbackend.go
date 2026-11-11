// Package pluginbackend runs a plugin backend process through Core.
//
// Core owns the process, the protocol and the event stream; this package decides
// what may be started and answers what the process asks the host for. Both halves
// are refusals: a launch plan is verified against the installed package before a
// single byte is executed, and a forwarded host request is answered only through
// a handler that was registered for exactly that method.
//
// The package imports the Core bridge because it is the bridge's caller. Its
// tests therefore need the Core static library, which scripts/desktop/desktop-go.sh
// builds and links.
package pluginbackend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const (
	// EventHostRequest is the runtime event carrying one forwarded host request.
	EventHostRequest = "hostRequest"
	// EventExit is the runtime event that ends a session.
	EventExit = "exit"
	// eventWaitMilliseconds bounds one event wait. Core returns as soon as an
	// event arrives, so this is an idle bound rather than a delay.
	eventWaitMilliseconds = 5000
)

var (
	// ErrNoSession reports work asked of a session that was never opened.
	ErrNoSession = errors.New("plugin backend session is not open")
	// ErrRequest reports a start request this host will not run.
	ErrRequest = errors.New("plugin backend start request is not usable")
)

// SharedProviderError reports a provider that reuses a language-server session.
// The caller that owns that session must attach the build request to it rather
// than let this runner start a second process.
type SharedProviderError struct {
	BuildSystemID string
	LanguageID    string
}

func (e *SharedProviderError) Error() string {
	return fmt.Sprintf("build provider %s shares the %s language-server session", e.BuildSystemID, e.LanguageID)
}

// Kernel is the part of the Core client this package uses. *core.Client
// satisfies it.
type Kernel interface {
	PlanPluginBackend(ctx context.Context, manifest json.RawMessage, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error)
	PlanPluginLanguageServer(ctx context.Context, manifest json.RawMessage, languageID string, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error)
	PlanPluginBuildProvider(ctx context.Context, manifest json.RawMessage, buildSystemID string, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error)
	StartPluginBackend(ctx context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error)
	StartPluginLanguageServer(ctx context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error)
	WaitBackendEvents(ctx context.Context, session string, timeoutMilliseconds int) ([]core.BackendEvent, error)
	StopPluginBackend(ctx context.Context, session string) error
	DestroyPluginBackend(ctx context.Context, session string) error
	RespondPluginHostRequest(ctx context.Context, session, requestID string, result json.RawMessage, failure *core.PluginHostFailure) error
	RequestPluginSemantics(ctx context.Context, request core.PluginSemanticRequest) (string, error)
	RequestPluginBuild(ctx context.Context, request core.PluginBuildProviderRequest) (string, error)
	InvokePluginFunction(ctx context.Context, session, operation, plugin, function string, params json.RawMessage) (string, error)
	InvokePluginFunctionInContext(ctx context.Context, session, operation, plugin, function string, params, workspaceContext json.RawMessage, timeoutMilliseconds int) (string, error)
	SendPluginHostNotification(ctx context.Context, session, method string, params json.RawMessage) (bool, error)
	PluginServerRequest(ctx context.Context, session, operation, plugin, server, method string, params json.RawMessage, timeoutMilliseconds int) (string, error)
	PluginServerNotify(ctx context.Context, session, plugin, server, method string, params json.RawMessage) (bool, error)
	CancelPluginOperation(ctx context.Context, session, operation string) error
}

// StartRequest is everything the host must supply before a backend can run.
type StartRequest struct {
	// Manifest is Core's normalised manifest, not the bytes read from disk.
	Manifest json.RawMessage
	// PackageDirectory is the installed package root.
	PackageDirectory string
	// PluginID and ProviderID identify what will run.
	PluginID   string
	ProviderID string
	// LanguageID selects a language server declaration. Empty starts the
	// plugin's backend instead.
	LanguageID string
	// BuildSystemID selects a build-system provider instead of a language
	// server or generic backend. It is empty for those roles.
	BuildSystemID string
	// Role is the Core session role. Empty keeps the historical backend role;
	// a build provider names "build".
	Role string
	// StateDirectory and the other directories are writable locations the host
	// created before starting.
	StateDirectory          string
	WorkspaceStateDirectory string
	LogDirectory            string
	TemporaryDirectory      string
	// Architecture is the platform Core plans for.
	Architecture string
	// Settings are the plugin's own settings, opaque to this package.
	Settings map[string]json.RawMessage
	// ProjectSettings is the separately captured project override layer.
	ProjectSettings map[string]json.RawMessage
	// Environment is added to the provider process environment. It is for host
	// integration tests and host-owned facts, never plugin-controlled secrets.
	Environment map[string]string
	// RootURI and WorkingDirectory are the workspace the backend serves.
	RootURI          any
	WorkingDirectory string
	// Plan is an already decoded launch plan, such as the one Core returns for
	// the answer of a backend-resolved language-server launch (serverProcess 3).
	// When set the runner does not plan again; the plan is still verified
	// against the installed package exactly like a planned one.
	Plan *core.PluginBackendPlan
	// InitializeTimeoutMilliseconds bounds the provider's startup handshake.
	// Zero keeps Core's default. A host test whose fixture is a large
	// instrumented binary raises it so scheduler load cannot masquerade as a
	// provider failure.
	InitializeTimeoutMilliseconds int
}

// Session is one running plugin backend.
type Session struct {
	// ID is Core's session identifier.
	ID string
	// PluginID and ProviderID identify what is running.
	PluginID   string
	ProviderID string
	// Version comes from Core's validated launch plan, not a pathname or UI draft.
	Version string
	// ProcessID is the operating system process, when Core reports one.
	ProcessID int
	// Granted is the host-service grant list the session started with: the
	// plan's list narrowed to what this host answers. A host notification is
	// only sent for a service in it.
	Granted []string
}

// Runner plans, starts, serves and stops plugin backends.
type Runner struct {
	kernel   Kernel
	services *pluginhost.Services
	// lookup resolves a bare command name for a system-command launch. It is
	// exec.LookPath in production and a test replaces it to describe a machine.
	lookup func(name string) (string, error)
	// tools resolves a plan's {kind: "tool"} launch to an executable. Nil refuses
	// such a launch rather than guessing a program.
	tools ToolResolver
	// initializeTimeout is the startup-handshake deadline applied to a request
	// that does not carry its own. Zero keeps Core's default.
	initializeTimeout time.Duration
}

// SetInitializeTimeout sets the startup-handshake deadline of every backend
// whose request does not name one. A host test whose fixture is a large
// instrumented binary raises it so scheduler load cannot masquerade as a
// provider failure. It must be called before the first Start; zero keeps
// Core's default.
func (r *Runner) SetInitializeTimeout(timeout time.Duration) { r.initializeTimeout = timeout }

// ToolResolver resolves the tool definition a plugin launch names to the
// executable the host runs, using the host's toolchain discovery.
type ToolResolver func(ctx context.Context, pluginID, tool string) (string, error)

// SetToolResolver installs the resolver for tool launches. It must be called
// before the first Start.
func (r *Runner) SetToolResolver(resolver ToolResolver) { r.tools = resolver }

// New returns a runner that answers host requests with services.
func New(kernel Kernel, services *pluginhost.Services) *Runner {
	if services == nil {
		// A runner always holds a registry: a nil one would panic the first time a
		// backend asked the host for anything.
		services = pluginhost.NewServices()
	}
	return &Runner{kernel: kernel, services: services, lookup: exec.LookPath}
}

// Start resolves Core's launch plan, verifies every path it names against the
// installed package, narrows the host services to what this host can answer and
// then starts the process.
func (r *Runner) Start(ctx context.Context, request StartRequest) (Session, error) {
	if r == nil || r.kernel == nil {
		return Session{}, errors.New("pluginbackend: no kernel")
	}
	if err := checkStartRequest(request); err != nil {
		return Session{}, err
	}
	directories := core.PluginBackendDirectories{
		PluginDirectory:         request.PackageDirectory,
		StateDirectory:          request.StateDirectory,
		WorkspaceStateDirectory: request.WorkspaceStateDirectory,
		LogDirectory:            request.LogDirectory,
		TemporaryDirectory:      request.TemporaryDirectory,
		Architecture:            request.Architecture,
		Settings:                request.Settings,
		ProjectSettings:         request.ProjectSettings,
	}
	var plan core.PluginBackendPlan
	var err error
	if request.Plan != nil {
		plan = *request.Plan
	} else if request.BuildSystemID != "" {
		plan, err = r.kernel.PlanPluginBuildProvider(ctx, request.Manifest, request.BuildSystemID, directories)
	} else if request.LanguageID != "" {
		plan, err = r.kernel.PlanPluginLanguageServer(ctx, request.Manifest, request.LanguageID, directories)
	} else {
		plan, err = r.kernel.PlanPluginBackend(ctx, request.Manifest, directories)
	}
	if err != nil {
		return Session{}, err
	}
	if request.BuildSystemID != "" {
		if plan.BuildProvider == nil {
			return Session{}, fmt.Errorf("%w: the plan names no build provider", ErrRequest)
		}
		if plan.BuildProvider.LanguageServer != "" {
			// A shared provider keeps one process per language. Returning the
			// session it already uses is the caller's job; starting a second
			// process would violate the contract.
			return Session{}, &SharedProviderError{
				BuildSystemID: request.BuildSystemID,
				LanguageID:    plan.BuildProvider.LanguageServer,
			}
		}
	}
	if plan.Owner != nil && plan.Owner.PluginID != request.PluginID {
		return Session{}, fmt.Errorf("%w: launch plan belongs to another plugin", ErrRequest)
	}
	resolved, err := pluginhost.VerifyLaunch(request.PackageDirectory, LaunchFromPlan(plan))
	if err != nil {
		return Session{}, err
	}
	granted := pluginhost.GrantServices(plan.Backend.HostServices, r.services)
	// A packaged launch runs the program the package ships; a runtime launch runs the
	// packaged runtime, which VerifyLaunch put in Runtime; a system-command launch
	// names a bare command the host resolves itself.
	executable := resolved.Executable
	if executable == "" {
		executable = resolved.Runtime
	}
	if executable == "" && plan.Launch.Kind == pluginhost.LaunchSystemCommand {
		executable, err = pluginhost.ResolveCommand(plan.Launch.Commands, r.lookup)
		if err != nil {
			return Session{}, err
		}
	}
	if executable == "" && plan.Launch.Kind == pluginhost.LaunchRuntime && plan.Launch.Tool != "" {
		// A runtime launch without a packaged runtime names the host runtime
		// that loads the package's entry. The host resolves the tool; the entry
		// was already verified above.
		executable, err = pluginhost.ResolveCommand([]string{plan.Launch.Tool}, r.lookup)
		if err != nil {
			return Session{}, err
		}
	}
	if executable == "" && plan.Launch.Kind == pluginhost.LaunchTool {
		if r.tools == nil {
			return Session{}, fmt.Errorf("%w: this host cannot resolve tool launches", ErrRequest)
		}
		executable, err = r.tools(ctx, request.PluginID, plan.Launch.Tool)
		if err != nil {
			return Session{}, err
		}
	}
	if executable == "" {
		return Session{}, fmt.Errorf("%w: the plan names no program", ErrRequest)
	}
	role := request.Role
	if role == "" {
		role = "backend"
	}
	start := core.PluginBackendStart{
		ProviderID:             request.ProviderID,
		PluginID:               request.PluginID,
		Role:                   role,
		ExecutablePath:         executable,
		Arguments:              Arguments(plan, resolved.Entry),
		Environment:            mergeEnvironment(plan.Environment, request.Environment),
		SessionPolicy:          plan.SessionPolicy,
		RootURI:                request.RootURI,
		WorkingDirectory:       request.WorkingDirectory,
		HostServices:           granted,
		HostOptions:            hostOptions(granted),
		InitializationOptions:  plan.InitializationOptions,
		WorkspaceConfiguration: plan.WorkspaceConfiguration,

		InitializeTimeoutMilliseconds: request.InitializeTimeoutMilliseconds,
	}
	if start.InitializeTimeoutMilliseconds == 0 && r.initializeTimeout > 0 {
		start.InitializeTimeoutMilliseconds = int(r.initializeTimeout / time.Millisecond)
	}
	var started core.PluginBackendStarted
	if request.LanguageID != "" {
		started, err = r.kernel.StartPluginLanguageServer(ctx, start)
	} else {
		started, err = r.kernel.StartPluginBackend(ctx, start)
	}
	if err != nil {
		return Session{}, err
	}
	session := Session{
		ID:         started.SessionID,
		PluginID:   request.PluginID,
		ProviderID: request.ProviderID,
		Granted:    granted,
	}
	if plan.Owner != nil {
		session.Version = plan.Owner.Version
	}
	if started.ProcessID != nil {
		session.ProcessID = *started.ProcessID
	}
	return session, nil
}

// mergeEnvironment layers the host's variables over a launch answer's.
func mergeEnvironment(plan, host map[string]string) map[string]string {
	if len(plan) == 0 {
		return host
	}
	merged := make(map[string]string, len(plan)+len(host))
	for name, value := range plan {
		merged[name] = value
	}
	for name, value := range host {
		merged[name] = value
	}
	return merged
}

// Stop shuts a session down and disposes it. Stopping is attempted even when the
// shutdown request fails, because Core keeps owning the session until it is
// disposed.
func (r *Runner) Stop(ctx context.Context, session Session) error {
	if r == nil || r.kernel == nil {
		return errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" {
		return ErrNoSession
	}
	stopErr := r.kernel.StopPluginBackend(ctx, session.ID)
	// Core keeps the session until its shutdown reaches a terminal state, so a
	// destroy immediately after stop is normally refused. Wait for queued
	// lifecycle events instead of treating that refusal as a cleanup failure.
	var destroyErr error
	for {
		destroyErr = r.kernel.DestroyPluginBackend(ctx, session.ID)
		if destroyErr == nil || ctx.Err() != nil {
			break
		}
		if _, waitErr := r.kernel.WaitBackendEvents(ctx, session.ID, 250); waitErr != nil {
			break
		}
	}
	return errors.Join(stopErr, destroyErr)
}

// EventDiagnostics is the runtime event carrying a language server's diagnostics
// for one document.
const EventDiagnostics = "diagnostics"

// EventObserver sees the events the runner does not act on itself, such as
// diagnostics and completed requests. It runs on the serve goroutine, so it must
// hand the event to its owner rather than block or touch the owner's state.
type EventObserver func(event core.BackendEvent)

// Serve answers forwarded host requests until the session ends or ctx is done.
//
// Every answer goes through pluginhost.Services, so a method the host never
// registered is refused with the contract's methodNotDeclared code rather than
// leaving the plugin waiting. Every event the runner does not act on is passed to
// observe, which may be nil.
//
// Returning nil means Core reported the session's exit event, not that the Core
// session is gone: Core keeps it until it is disposed, so the caller must still
// call Stop. Serve does not dispose it itself, because a caller that stops the
// session concurrently would then dispose it twice.
func (r *Runner) Serve(ctx context.Context, session Session, observe EventObserver) error {
	if r == nil || r.kernel == nil {
		return errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" {
		return ErrNoSession
	}
	// A host request can wait much longer than the event loop may be blocked: a
	// language-server request waits for the server, and the backend's own call
	// completions arrive through this same loop. Each request is therefore
	// answered on its own goroutine, bounded by Core's per-session limit of
	// pending requests, and cancelled when the backend cancels it.
	answers := newAnswerGroup(ctx)
	defer answers.wait()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := answers.failure(); err != nil {
			return err
		}
		events, err := r.kernel.WaitBackendEvents(ctx, session.ID, eventWaitMilliseconds)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		for _, event := range events {
			switch event.Type {
			case EventExit:
				return nil
			case EventHostRequest:
				id := hostRequestID(event)
				if id == "" {
					return errors.New("pluginbackend: a host request carries no identifier")
				}
				answers.start(id, func(answerCtx context.Context) error {
					return r.answer(answerCtx, session, event)
				})
			case EventHostRequestCancelled:
				answers.cancel(hostRequestID(event))
			default:
				if observe != nil {
					observe(event)
				}
			}
		}
	}
}

// EventHostRequestCancelled reports a host request the backend cancelled; the host
// stops the work, and Core has already answered the backend.
const EventHostRequestCancelled = "hostRequestCancelled"

// hostRequestID reads the identifier a hostRequest or hostRequestCancelled event
// carries.
func hostRequestID(event core.BackendEvent) string {
	var payload struct {
		HostRequestID string `json:"hostRequestID"`
	}
	_ = json.Unmarshal(event.Result, &payload)
	return payload.HostRequestID
}

// answerGroup runs the answers of one Serve call.
type answerGroup struct {
	ctx     context.Context
	cancels sync.Map
	group   sync.WaitGroup
	mu      sync.Mutex
	err     error
}

func newAnswerGroup(ctx context.Context) *answerGroup { return &answerGroup{ctx: ctx} }

func (g *answerGroup) start(id string, run func(context.Context) error) {
	ctx, cancel := context.WithCancel(g.ctx)
	if id != "" {
		g.cancels.Store(id, cancel)
	}
	g.group.Add(1)
	go func() {
		defer g.group.Done()
		defer cancel()
		if id != "" {
			defer g.cancels.Delete(id)
		}
		if err := run(ctx); err != nil && g.ctx.Err() == nil {
			g.mu.Lock()
			if g.err == nil {
				g.err = err
			}
			g.mu.Unlock()
		}
	}()
}

func (g *answerGroup) cancel(id string) {
	if cancel, ok := g.cancels.Load(id); ok {
		cancel.(context.CancelFunc)()
	}
}

func (g *answerGroup) failure() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.err
}

// answerGrace is how long Serve lets answers in flight finish after the session
// ended before it cancels them.
const answerGrace = 500 * time.Millisecond

// wait gives the answers still running a short grace, cancels what is left and
// waits for it, so Serve never returns while a goroutine of it can still call
// Core.
func (g *answerGroup) wait() {
	finished := make(chan struct{})
	go func() { g.group.Wait(); close(finished) }()
	select {
	case <-finished:
		return
	case <-time.After(answerGrace):
	}
	g.cancels.Range(func(_, cancel any) bool {
		cancel.(context.CancelFunc)()
		return true
	})
	g.group.Wait()
}

// answer relays one forwarded host request through the registered handlers.
func (r *Runner) answer(ctx context.Context, session Session, event core.BackendEvent) error {
	var payload struct {
		HostRequestID string          `json:"hostRequestID"`
		Service       string          `json:"service"`
		Params        json.RawMessage `json:"params"`
	}
	if len(event.Result) != 0 {
		if err := json.Unmarshal(event.Result, &payload); err != nil {
			return fmt.Errorf("decode host request: %w", err)
		}
	}
	if payload.HostRequestID == "" {
		return errors.New("pluginbackend: a host request carries no identifier")
	}
	method := event.Method
	if method == "" {
		method = payload.Service
	}
	result, failure := r.services.Respond(pluginhost.WithCaller(ctx, pluginhost.Caller{PluginID: session.PluginID, SessionID: session.ID}), method, payload.Params)
	var hostFailure *core.PluginHostFailure
	if failure != nil {
		hostFailure = &core.PluginHostFailure{
			Code:    failure.Code,
			Message: failure.Message,
			Details: failure.Details,
		}
	}
	return r.kernel.RespondPluginHostRequest(ctx, session.ID, payload.HostRequestID, result, hostFailure)
}

// Request submits one semantic request to a session and returns Core's operation
// ID.
//
// The request is asynchronous: the operation ID is what a later requestCompleted
// event carries, so the caller keeps it to match the answer. A request that names
// no operation is refused here rather than sent, because Core would answer with a
// protocol error that reads like a server problem.
func (r *Runner) Request(ctx context.Context, session Session, request core.PluginSemanticRequest) (string, error) {
	if r == nil || r.kernel == nil {
		return "", errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" {
		return "", ErrNoSession
	}
	if request.Operation == "" {
		return "", fmt.Errorf("%w: the request names no operation", ErrRequest)
	}
	request.SessionID = session.ID
	return r.kernel.RequestPluginSemantics(ctx, request)
}

// RequestBuild submits one typed build-provider request to a session that
// negotiated the protocol and returns Core's operation ID.
func (r *Runner) RequestBuild(ctx context.Context, session Session, request core.PluginBuildProviderRequest) (string, error) {
	if r == nil || r.kernel == nil {
		return "", errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" {
		return "", ErrNoSession
	}
	request.SessionID = session.ID
	return r.kernel.RequestPluginBuild(ctx, request)
}

// RequestFunction uses the owner of the running session. Core validates the
// function declaration, negotiated protocol and request payload; the adapter
// cannot retarget a settings action to another plugin. Completion and progress
// share Serve's existing ordered event stream and Cancel's operation identity.
func (r *Runner) RequestFunction(ctx context.Context, session Session, operation, function string, params json.RawMessage) (string, error) {
	if r == nil || r.kernel == nil {
		return "", errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" || session.PluginID == "" {
		return "", ErrNoSession
	}
	return r.kernel.InvokePluginFunction(ctx, session.ID, operation, session.PluginID, function, params)
}

// Cancel asks Core to cancel one outstanding build operation.
func (r *Runner) Cancel(ctx context.Context, session Session, operation string) error {
	if r == nil || r.kernel == nil {
		return errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" {
		return ErrNoSession
	}
	if operation == "" {
		return fmt.Errorf("%w: the operation is empty", ErrRequest)
	}
	return r.kernel.CancelPluginOperation(ctx, session.ID, operation)
}

// LaunchFromPlan extracts the fields pluginhost verifies from a Core plan.
func LaunchFromPlan(plan core.PluginBackendPlan) pluginhost.Launch {
	return pluginhost.Launch{
		Kind:            plan.Launch.Kind,
		Path:            plan.Launch.Path,
		Entry:           plan.Launch.Entry,
		PackagedRuntime: plan.Launch.PackagedRuntime,
		Tool:            plan.Launch.Tool,
		Commands:        plan.Launch.Commands,
		Required:        plan.RequiredPackagePaths,
	}
}

// Arguments composes the process arguments a plan describes.
//
// Core reports a packaged runtime's own arguments and the entry file separately, so
// the order is: runtime arguments, the entry file, then the plan's arguments. entry
// must be the path VerifyLaunch resolved, not the plan's package-relative one: the
// runtime resolves a relative path against its working directory, so the file that
// was verified and the file that is loaded would differ.
func Arguments(plan core.PluginBackendPlan, entry string) []string {
	arguments := make([]string, 0, len(plan.Launch.RuntimeArguments)+1+len(plan.Arguments))
	arguments = append(arguments, plan.Launch.RuntimeArguments...)
	if plan.Launch.Kind == pluginhost.LaunchRuntime && entry != "" {
		arguments = append(arguments, entry)
	}
	arguments = append(arguments, plan.Arguments...)
	return arguments
}

func checkStartRequest(request StartRequest) error {
	if len(request.Manifest) == 0 {
		return fmt.Errorf("%w: no manifest", ErrRequest)
	}
	if request.PackageDirectory == "" || !filepath.IsAbs(request.PackageDirectory) {
		return fmt.Errorf("%w: the package directory must be absolute", ErrRequest)
	}
	if request.PluginID == "" || request.ProviderID == "" {
		return fmt.Errorf("%w: no plugin or provider identity", ErrRequest)
	}
	if request.StateDirectory == "" || !filepath.IsAbs(request.StateDirectory) {
		return fmt.Errorf("%w: the state directory must be absolute", ErrRequest)
	}
	return nil
}

// hostOptions declares the editor service's options when the session is granted one of
// its registration methods; Core reports them only for granted methods.
func hostOptions(granted []string) *core.PluginHostOptions {
	for _, method := range granted {
		if strings.HasSuffix(method, "editor/registerActions") || strings.HasSuffix(method, "editor/registerProviders") {
			editor := core.EditorHost
			return &core.PluginHostOptions{Editor: &editor}
		}
	}
	return nil
}
