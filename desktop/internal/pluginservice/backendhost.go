package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

const (
	// backendStartTimeout bounds resolving and launching one plugin backend.
	backendStartTimeout = 2 * time.Minute
	// backendReadyTimeout bounds waiting for a started backend to finish
	// initialize and register the function a call needs.
	backendReadyTimeout = 60 * time.Second
	// backendStopTimeout bounds one shutdown. Core keeps the session until it is
	// disposed, so it covers both the graceful stop and the disposal.
	backendStopTimeout = 30 * time.Second
	// backendFunctionTimeout is a call's deadline when the caller gives none.
	backendFunctionTimeout = 60 * time.Second
)

// Errors a backend call reports.
var (
	// ErrBackendUnavailable reports a plugin that declares no backend, is not
	// installed or enabled, or whose backend stopped.
	ErrBackendUnavailable = errors.New("plugin backend is not available")
)

// FunctionError is a plugin function that ended with an error.
type FunctionError struct {
	// Code is Core's code, such as plugin.function.failed.
	Code string
	// Message is the backend's message.
	Message string
	// PluginCode is the plugin's own error code, when it supplied one.
	PluginCode string
}

func (e *FunctionError) Error() string { return e.Code + ": " + e.Message }

// BackendHost keeps at most one backend process per plugin and starts it on
// demand: when a workspace opens for a plugin that asks for it, when its
// language server needs a launch answer, or when another plugin calls it.
//
// It owns the serve loop of each session, so a call can wait for its completion
// event without the caller owning an event loop.
type BackendHost struct {
	service *Service
	mu      sync.Mutex
	// sessions are the running backends by plugin ID.
	sessions map[string]*BackendSession
	// starting makes concurrent EnsureBackend calls for one plugin share a start.
	starting map[string]chan struct{}
	nextOp   atomic.Uint64
}

func newBackendHost(service *Service) *BackendHost {
	return &BackendHost{service: service, sessions: make(map[string]*BackendSession), starting: make(map[string]chan struct{})}
}

// BackendSession is one running plugin backend and its serve loop.
type BackendSession struct {
	host     *BackendHost
	PluginID string
	Version  string
	Session  pluginbackend.Session
	cancel   context.CancelFunc
	done     chan struct{}

	mu        sync.Mutex
	ready     bool
	ended     bool
	functions map[string]bool
	waiters   map[string]chan core.BackendEvent
	// changed is closed and replaced whenever ready, functions or ended change.
	changed chan struct{}
}

// Running returns the running backend of a plugin, or nil.
func (h *BackendHost) Running(pluginID string) *BackendSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[pluginID]
	if session != nil && session.isEnded() {
		return nil
	}
	return session
}

// RunningPlugins lists the plugins whose backend is running, sorted.
func (h *BackendHost) RunningPlugins() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	ids := make([]string, 0, len(h.sessions))
	for id, session := range h.sessions {
		if !session.isEnded() {
			ids = append(ids, id)
		}
	}
	return ids
}

// EnsureBackend starts the plugin's backend when it is not running and returns
// its session. It does not wait for the backend to finish initialize; Call does.
func (h *BackendHost) EnsureBackend(ctx context.Context, pluginID string) (*BackendSession, error) {
	for {
		h.mu.Lock()
		if session := h.sessions[pluginID]; session != nil && !session.isEnded() {
			h.mu.Unlock()
			return session, nil
		}
		if wait, busy := h.starting[pluginID]; busy {
			h.mu.Unlock()
			select {
			case <-wait:
				continue
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		done := make(chan struct{})
		h.starting[pluginID] = done
		h.mu.Unlock()
		session, err := h.start(ctx, pluginID)
		h.mu.Lock()
		delete(h.starting, pluginID)
		if err == nil {
			h.sessions[pluginID] = session
		}
		h.mu.Unlock()
		close(done)
		return session, err
	}
}

func (h *BackendHost) start(ctx context.Context, pluginID string) (*BackendSession, error) {
	s := h.service
	entries, err := s.Manager.Installed()
	if err != nil {
		return nil, err
	}
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	var entry pluginmanager.Entry
	found := false
	for _, candidate := range selected {
		if candidate.Installed.ID == pluginID {
			entry, found = candidate, true
			break
		}
	}
	if !found {
		return nil, errors.Join(ErrBackendUnavailable, selectionErr)
	}
	manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
	if err != nil {
		return nil, err
	}
	if !declaresBackend(manifest) {
		return nil, fmt.Errorf("%w: %s declares no backend", ErrBackendUnavailable, pluginID)
	}
	settings, err := s.Settings.Load(ctx, manifest, "")
	if err != nil {
		return nil, err
	}
	directories := s.backendDirectories(entry.Installed.ID, entry.Installed.Version)
	if err := directories.create(); err != nil {
		return nil, err
	}
	startCtx, cancelStart := context.WithTimeout(ctx, backendStartTimeout)
	defer cancelStart()
	started, err := s.Backend.Start(startCtx, pluginbackend.StartRequest{
		Manifest:         manifest,
		PackageDirectory: entry.Installed.Path,
		PluginID:         entry.Installed.ID,
		ProviderID:       entry.Installed.ID + "/backend",
		StateDirectory:   directories.state,
		LogDirectory:     directories.log,
		Architecture:     core.PluginArchitecture(),
		Settings:         settings.State.Settings,
		ProjectSettings:  settings.State.ProjectSettings,
		// A backend belongs to no workspace: it starts with its plugin-wide state
		// directory as root and working directory.
		RootURI:          fileURI(directories.state),
		WorkingDirectory: directories.state,
	})
	if err != nil {
		return nil, err
	}
	serveCtx, cancel := context.WithCancel(context.Background())
	session := &BackendSession{
		host: h, PluginID: pluginID, Version: entry.Installed.Version, Session: started,
		cancel: cancel, done: make(chan struct{}),
		functions: make(map[string]bool), waiters: make(map[string]chan core.BackendEvent),
		changed: make(chan struct{}),
	}
	go session.serve(serveCtx)
	return session, nil
}

// Stop ends one plugin's backend, bounded. A missing backend is not an error.
func (h *BackendHost) Stop(pluginID string) { h.Detach(pluginID)() }

// Detach removes one plugin's backend from the host at once, so a later start
// begins a new session, and returns the function that stops the detached process
// (bounded). Detaching synchronously and stopping later keeps a stop that runs on
// a background goroutine from killing a backend started after it.
func (h *BackendHost) Detach(pluginID string) func() {
	h.mu.Lock()
	session := h.sessions[pluginID]
	delete(h.sessions, pluginID)
	h.mu.Unlock()
	return func() {
		if session != nil {
			session.stop()
		}
	}
}

// StopAll ends every backend, bounded. It runs when the project closes, the
// plugin set changes and the client quits.
func (h *BackendHost) StopAll() { h.DetachAll()() }

// DetachAll is Detach for every backend.
func (h *BackendHost) DetachAll() func() {
	h.mu.Lock()
	sessions := make([]*BackendSession, 0, len(h.sessions))
	for _, session := range h.sessions {
		sessions = append(sessions, session)
	}
	h.sessions = make(map[string]*BackendSession)
	h.mu.Unlock()
	return func() {
		var group sync.WaitGroup
		for _, session := range sessions {
			group.Add(1)
			go func() { defer group.Done(); session.stop() }()
		}
		group.Wait()
	}
}

// Notify sends a host notification to a running backend that holds the grant.
// A backend that is not running or not granted never sees it.
func (h *BackendHost) Notify(ctx context.Context, pluginID, grant, method string, params json.RawMessage) {
	session := h.Running(pluginID)
	if session == nil || !session.granted(grant) {
		return
	}
	// A notification may arrive before initialize completes; it is dropped then,
	// because a backend that starts later reads the state itself.
	if !session.isReady() {
		return
	}
	_, _ = h.service.kernel.SendPluginHostNotification(ctx, session.Session.ID, method, params)
}

// NotifyAll sends a host notification to every running backend that holds the grant.
func (h *BackendHost) NotifyAll(ctx context.Context, grant, method string, params json.RawMessage) {
	for _, id := range h.RunningPlugins() {
		h.Notify(ctx, id, grant, method, params)
	}
}

// Call invokes one function of the plugin's backend, starting it first, and
// waits for the answer. workspaceContext may be nil for a call that names none.
func (h *BackendHost) Call(ctx context.Context, pluginID, function string, params, workspaceContext json.RawMessage, timeout time.Duration) (json.RawMessage, error) {
	session, err := h.EnsureBackend(ctx, pluginID)
	if err != nil {
		return nil, err
	}
	return session.Call(ctx, function, params, workspaceContext, timeout)
}

// Call invokes one function and waits for its completion event.
func (b *BackendSession) Call(ctx context.Context, function string, params, workspaceContext json.RawMessage, timeout time.Duration) (json.RawMessage, error) {
	if timeout <= 0 {
		timeout = backendFunctionTimeout
	}
	waitCtx, cancel := context.WithTimeout(ctx, backendReadyTimeout)
	defer cancel()
	if err := b.waitFor(waitCtx, func() bool { return b.ready && b.functions[function] }); err != nil {
		return nil, fmt.Errorf("plugin function %s is not available: %w", function, err)
	}
	operation := fmt.Sprintf("host-call-%d", b.host.nextOp.Add(1))
	completed := make(chan core.BackendEvent, 1)
	b.mu.Lock()
	if b.ended {
		b.mu.Unlock()
		return nil, ErrBackendUnavailable
	}
	b.waiters[operation] = completed
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.waiters, operation)
		b.mu.Unlock()
	}()
	if _, err := b.host.service.kernel.InvokePluginFunctionInContext(ctx, b.Session.ID, operation, b.PluginID, function, params, workspaceContext, int(timeout/time.Millisecond)); err != nil {
		return nil, err
	}
	select {
	case event := <-completed:
		return decodeCompletion(event)
	case <-ctx.Done():
		cancelCtx, cancelDone := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelDone()
		_ = b.host.service.kernel.CancelPluginOperation(cancelCtx, b.Session.ID, operation)
		return nil, ctx.Err()
	}
}

// decodeCompletion turns a requestCompleted event into a value or an error.
func decodeCompletion(event core.BackendEvent) (json.RawMessage, error) {
	if event.Type == "" && len(event.Error) == 0 && len(event.Result) == 0 {
		return nil, ErrBackendUnavailable
	}
	if len(event.Error) != 0 && string(event.Error) != "null" {
		failure := decodeEventError(event.Error)
		return nil, failure
	}
	var result struct {
		Value json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(event.Result, &result); err != nil {
		return nil, fmt.Errorf("decode function result: %w", err)
	}
	if len(result.Value) == 0 {
		return json.RawMessage("null"), nil
	}
	return result.Value, nil
}

// eventFailure is a completed request that failed, with Core's code and details.
type eventFailure struct {
	FunctionError
	Details json.RawMessage
}

func decodeEventError(raw json.RawMessage) *eventFailure {
	var decoded struct {
		Code       string          `json:"code"`
		Message    string          `json:"message"`
		PluginCode string          `json:"pluginErrorCode"`
		Details    json.RawMessage `json:"details"`
	}
	_ = json.Unmarshal(raw, &decoded)
	if decoded.Code == "" {
		decoded.Code = "plugin.host.failed"
	}
	return &eventFailure{FunctionError: FunctionError{Code: decoded.Code, Message: decoded.Message, PluginCode: decoded.PluginCode}, Details: decoded.Details}
}

// waitFor blocks until check (called with the session lock held) is true, the
// session ended or ctx is done.
func (b *BackendSession) waitFor(ctx context.Context, check func() bool) error {
	for {
		b.mu.Lock()
		if check() {
			b.mu.Unlock()
			return nil
		}
		if b.ended {
			b.mu.Unlock()
			return ErrBackendUnavailable
		}
		changed := b.changed
		b.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (b *BackendSession) signal() {
	close(b.changed)
	b.changed = make(chan struct{})
}

// hasFunction reports whether the backend registered a function.
func (b *BackendSession) hasFunction(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.functions[id]
}

func (b *BackendSession) isEnded() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.ended
}

func (b *BackendSession) isReady() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.ready && !b.ended
}

func (b *BackendSession) granted(grant string) bool {
	for _, name := range b.Session.Granted {
		if name == grant {
			return true
		}
	}
	return false
}

// serve runs the session's event loop until it ends.
func (b *BackendSession) serve(ctx context.Context) {
	defer close(b.done)
	err := b.host.service.Backend.Serve(ctx, b.Session, b.observe)
	b.mu.Lock()
	b.ended = true
	for _, waiter := range b.waiters {
		select {
		case waiter <- core.BackendEvent{}:
		default:
		}
	}
	b.signal()
	b.mu.Unlock()
	_ = err
	// Everything the session created in the host goes with it.
	b.host.service.resources.releaseSession(b.Session.ID)
	// A backend that exited on its own leaves the Core session to dispose.
	b.host.mu.Lock()
	if b.host.sessions[b.PluginID] == b {
		delete(b.host.sessions, b.PluginID)
	}
	b.host.mu.Unlock()
	stopCtx, cancel := context.WithTimeout(context.Background(), backendStopTimeout)
	defer cancel()
	_ = b.host.service.Backend.Stop(stopCtx, b.Session)
}

// observe records the lifecycle facts calls depend on and routes completions.
func (b *BackendSession) observe(event core.BackendEvent) {
	switch event.Type {
	case "stateChanged":
		if event.State == "ready" {
			b.mu.Lock()
			b.ready = true
			b.signal()
			b.mu.Unlock()
		}
	case "functionsChanged":
		var change struct {
			Functions []string `json:"functions"`
			Removed   []string `json:"removed"`
		}
		if json.Unmarshal(event.Result, &change) == nil {
			b.mu.Lock()
			for _, id := range change.Functions {
				b.functions[id] = true
			}
			for _, id := range change.Removed {
				delete(b.functions, id)
			}
			b.signal()
			b.mu.Unlock()
		}
	case "requestCompleted":
		b.mu.Lock()
		waiter := b.waiters[event.OperationID]
		b.mu.Unlock()
		if waiter != nil {
			select {
			case waiter <- event:
			default:
			}
		}
	case "functionProviderStartRequired":
		// Core holds a cross-plugin call until the callee's backend registers the
		// function; starting it is plain I/O the host owes.
		var request struct {
			PluginID string `json:"pluginID"`
		}
		if json.Unmarshal(event.Result, &request) == nil && request.PluginID != "" {
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), backendStartTimeout)
				defer cancel()
				_, _ = b.host.EnsureBackend(ctx, request.PluginID)
			}()
		}
	}
}

// stop ends the serve loop and the Core session, bounded.
func (b *BackendSession) stop() {
	b.cancel()
	select {
	case <-b.done:
	case <-time.After(backendStopTimeout):
	}
}

// declaresBackend reports whether a manifest has a plugin backend.
func declaresBackend(manifest json.RawMessage) bool {
	var declaration struct {
		Backend json.RawMessage `json:"backend"`
	}
	return json.Unmarshal(manifest, &declaration) == nil && len(declaration.Backend) > 0 && string(declaration.Backend) != "null"
}

// declaredActivation reports whether a manifest lists an activation event.
func declaredActivation(manifest json.RawMessage, event string) bool {
	var declaration struct {
		Events []string `json:"activationEvents"`
	}
	if json.Unmarshal(manifest, &declaration) != nil {
		return false
	}
	for _, candidate := range declaration.Events {
		if candidate == event {
			return true
		}
	}
	return false
}

// pluginDirectories are the writable locations of one start.
type pluginDirectories struct {
	state, workspaceState, log, temporary string
}

func (d pluginDirectories) create() error {
	for _, directory := range []string{d.state, d.workspaceState, d.log} {
		if directory == "" {
			continue
		}
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// backendDirectories places the plugin-wide state beside the installed versions,
// never inside one: an installed package is read-only for the host, and a
// version directory that changed would no longer match the digest the user
// approved. The plugin root is the platform's plugin storage, not the app bundle.
func (s *Service) backendDirectories(pluginID, version string) pluginDirectories {
	base := filepath.Join(s.Root, pluginStateDirectory, pluginID)
	return pluginDirectories{
		state: filepath.Join(base, version),
		log:   filepath.Join(base, "logs"),
	}
}

// fileURI is the file URL of an absolute native path.
func fileURI(path string) string {
	slashed := filepath.ToSlash(path)
	if runtime.GOOS == "windows" && !strings.HasPrefix(slashed, "/") {
		slashed = "/" + slashed
	}
	return (&url.URL{Scheme: "file", Path: slashed}).String()
}
