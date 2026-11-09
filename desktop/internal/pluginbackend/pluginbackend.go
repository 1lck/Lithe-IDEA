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
	"path/filepath"

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

// Kernel is the part of the Core client this package uses. *core.Client
// satisfies it.
type Kernel interface {
	PlanPluginBackend(ctx context.Context, manifest json.RawMessage, directories core.PluginBackendDirectories) (core.PluginBackendPlan, error)
	StartPluginBackend(ctx context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error)
	WaitBackendEvents(ctx context.Context, session string, timeoutMilliseconds int) ([]core.BackendEvent, error)
	StopPluginBackend(ctx context.Context, session string) error
	DestroyPluginBackend(ctx context.Context, session string) error
	RespondPluginHostRequest(ctx context.Context, session, requestID string, result json.RawMessage, failure *core.PluginHostFailure) error
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
	// RootURI and WorkingDirectory are the workspace the backend serves.
	RootURI          any
	WorkingDirectory string
}

// Session is one running plugin backend.
type Session struct {
	// ID is Core's session identifier.
	ID string
	// PluginID and ProviderID identify what is running.
	PluginID   string
	ProviderID string
	// ProcessID is the operating system process, when Core reports one.
	ProcessID int
}

// Runner plans, starts, serves and stops plugin backends.
type Runner struct {
	kernel   Kernel
	services *pluginhost.Services
}

// New returns a runner that answers host requests with services.
func New(kernel Kernel, services *pluginhost.Services) *Runner {
	return &Runner{kernel: kernel, services: services}
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
	}
	plan, err := r.kernel.PlanPluginBackend(ctx, request.Manifest, directories)
	if err != nil {
		return Session{}, err
	}
	resolved, err := pluginhost.VerifyLaunch(request.PackageDirectory, LaunchFromPlan(plan))
	if err != nil {
		return Session{}, err
	}
	granted := pluginhost.GrantServices(plan.Backend.HostServices, r.services)
	// A packaged launch runs the program the package ships; a runtime launch runs the
	// packaged runtime, which VerifyLaunch put in Runtime.
	executable := resolved.Executable
	if executable == "" {
		executable = resolved.Runtime
	}
	started, err := r.kernel.StartPluginBackend(ctx, core.PluginBackendStart{
		ProviderID:            request.ProviderID,
		PluginID:              request.PluginID,
		ExecutablePath:        executable,
		Arguments:             Arguments(plan, resolved.Entry),
		RootURI:               request.RootURI,
		WorkingDirectory:      request.WorkingDirectory,
		HostServices:          granted,
		InitializationOptions: plan.InitializationOptions,
	})
	if err != nil {
		return Session{}, err
	}
	session := Session{
		ID:         started.SessionID,
		PluginID:   request.PluginID,
		ProviderID: request.ProviderID,
	}
	if started.ProcessID != nil {
		session.ProcessID = *started.ProcessID
	}
	return session, nil
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
	destroyErr := r.kernel.DestroyPluginBackend(ctx, session.ID)
	return errors.Join(stopErr, destroyErr)
}

// Serve answers forwarded host requests until the session ends or ctx is done.
//
// Every answer goes through pluginhost.Services, so a method the host never
// registered is refused with the contract's methodNotDeclared code rather than
// leaving the plugin waiting.
func (r *Runner) Serve(ctx context.Context, session Session) error {
	if r == nil || r.kernel == nil {
		return errors.New("pluginbackend: no kernel")
	}
	if session.ID == "" {
		return ErrNoSession
	}
	for {
		if err := ctx.Err(); err != nil {
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
				if err := r.answer(ctx, session, event); err != nil {
					return err
				}
			}
		}
	}
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
	result, failure := r.services.Respond(ctx, method, payload.Params)
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

// LaunchFromPlan extracts the fields pluginhost verifies from a Core plan.
func LaunchFromPlan(plan core.PluginBackendPlan) pluginhost.Launch {
	return pluginhost.Launch{
		Kind:            plan.Launch.Kind,
		Path:            plan.Launch.Path,
		Entry:           plan.Launch.Entry,
		PackagedRuntime: plan.Launch.PackagedRuntime,
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
