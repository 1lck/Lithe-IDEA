package pluginservice

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// Plugin-owned native terminals (function protocol 3). The plugin chooses the
// program and its argv; the host asks the user before it runs anything, starts the
// program in a terminal tab beside the user's own, and keeps a bounded plain-text
// snapshot so a closed terminal can be reopened with its output above the new
// process. Handles, snapshots and exit outcomes live in memory only.
const (
	methodTerminalCreate  = pluginhost.MethodPrefix + "terminal/create"
	methodTerminalShow    = pluginhost.MethodPrefix + "terminal/show"
	methodTerminalClose   = pluginhost.MethodPrefix + "terminal/close"
	methodTerminalReopen  = pluginhost.MethodPrefix + "terminal/reopen"
	methodTerminalDispose = pluginhost.MethodPrefix + "terminal/dispose"
	methodTerminalOnExit  = pluginhost.MethodPrefix + "terminal/onExit"

	notifySubscription = pluginhost.MethodPrefix + "subscriptions/notify"

	maxTerminalsPerPlugin    = 8
	maxTerminalArguments     = 256
	maxTerminalValueBytes    = 16 * 1024
	maxTerminalEnvironment   = 64
	maxTerminalLaunchBytes   = 64 * 1024
	maxTerminalTitleBytes    = 128
	defaultRetainedBytes     = 16384
	maximumRetainedBytes     = 262144
	terminalReservedVariable = "LITHE_"
)

// TerminalSpec is what a terminal runs.
type TerminalSpec struct {
	PluginID   string
	Executable string
	Arguments  []string
	// Title is empty for the program's name.
	Title string
	// Directory is the absolute working directory inside the workspace.
	Directory string
	// Environment overrides variables; a nil value removes one.
	Environment map[string]*string
	// Show selects the terminal and reveals the terminal panel.
	Show bool
	// Prefill is the retained text of an earlier run, drawn before the new process
	// starts. It never reaches the process's input.
	Prefill string
	// RetainedBytes is the budget of the snapshot taken when the process ends.
	RetainedBytes int
}

// TerminalExit is one run's outcome.
type TerminalExit struct {
	// Code is the exit status, or nil when there is none.
	Code *int
	// Reason is "exited" for the process ending on its own and "closed" when the
	// tab was closed.
	Reason string
	// Retained is the snapshot, already cut to the budget.
	Retained string
}

// TerminalSession is one running terminal tab.
type TerminalSession interface {
	// Show selects the tab.
	Show(ctx context.Context) error
	// Close ends the process tree and removes the tab. The outcome is delivered on
	// Done. retainedBytes replaces the snapshot budget.
	Close(ctx context.Context, retainedBytes int) error
	// Done delivers the outcome once, after native cleanup.
	Done() <-chan TerminalExit
}

// TerminalHost starts terminals. The window implements it next to Workbench; a
// host without it never advertises the terminal methods.
type TerminalHost interface {
	// StartTerminal asks the user for consent, then starts the program. It waits
	// for the user without a deadline and returns when ctx ends.
	StartTerminal(ctx context.Context, root string, spec TerminalSpec) (TerminalSession, error)
}

// terminalHandle is one terminal a backend holds.
type terminalHandle struct {
	id        string
	caller    pluginhost.Caller
	contextID string
	workspace WorkspaceContext
	spec      TerminalSpec

	mu         sync.Mutex
	generation int
	// busy is set while close, reopen or dispose runs on the handle.
	busy      bool
	session   TerminalSession
	retained  string
	budget    int
	exit      *TerminalExit
	ended     chan struct{}
	exitSub   string
	sequence  int
	delivered bool
	disposed  bool
	resource  string
}

type terminalRegistry struct {
	mu   sync.Mutex
	next int
	byID map[string]*terminalHandle
}

func (s *Service) registerTerminals(host TerminalHost) error {
	s.terminalHost = host
	s.terminals = &terminalRegistry{byID: make(map[string]*terminalHandle)}
	for _, entry := range []struct {
		method  string
		handler pluginhost.Handler
		choice  bool
	}{
		// Creating and reopening wait for the user's consent.
		{methodTerminalCreate, s.handleTerminalCreate, true},
		{methodTerminalReopen, s.handleTerminalReopen, true},
		{methodTerminalShow, s.handleTerminalShow, false},
		{methodTerminalClose, s.handleTerminalClose, false},
		{methodTerminalDispose, s.handleTerminalDispose, false},
		{methodTerminalOnExit, s.handleTerminalOnExit, false},
	} {
		var err error
		if entry.choice {
			err = s.HostServices.RegisterUserChoice(entry.method, entry.handler)
		} else {
			err = s.HostServices.Register(entry.method, entry.handler)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

type terminalCreateParams struct {
	Context       ContextRef         `json:"context"`
	Executable    string             `json:"executable"`
	Arguments     []string           `json:"arguments"`
	Title         string             `json:"title"`
	Cwd           *Resource          `json:"cwd"`
	Environment   map[string]*string `json:"environment"`
	Show          *bool              `json:"show"`
	RetainedBytes *int               `json:"retainedContextBytes"`
}

// retainedBudget applies the contract's default and maximum.
func retainedBudget(value *int) (int, *pluginhost.Failure) {
	if value == nil {
		return defaultRetainedBytes, nil
	}
	if *value < 0 || *value > maximumRetainedBytes {
		return 0, failure(codeInvalidParams, "retainedContextBytes is 0 to 262144.")
	}
	return *value, nil
}

func validExecutable(name string) bool {
	if name == "" || len(name) > maxTerminalValueBytes || strings.ContainsRune(name, 0) {
		return false
	}
	if filepath.IsAbs(name) {
		return true
	}
	// A bare command is resolved by PATH; a relative path with a separator is not.
	return !strings.ContainsAny(name, `/\`)
}

// validateTerminal checks the launch data against the contract's limits.
func validateTerminal(request terminalCreateParams) *pluginhost.Failure {
	if !validExecutable(request.Executable) {
		return failure(codeInvalidParams, "executable is an absolute path or a bare command.")
	}
	if len(request.Arguments) > maxTerminalArguments {
		return failure(CodeLimitExceeded, "A terminal takes at most 256 arguments.")
	}
	total := len(request.Executable)
	for _, argument := range request.Arguments {
		if len(argument) > maxTerminalValueBytes || strings.ContainsRune(argument, 0) || !utf8.ValidString(argument) {
			return failure(CodeLimitExceeded, "An argument is at most 16 KiB of text.")
		}
		total += len(argument)
	}
	if len(request.Environment) > maxTerminalEnvironment {
		return failure(CodeLimitExceeded, "A terminal takes at most 64 environment entries.")
	}
	for name, value := range request.Environment {
		if name == "" || strings.ContainsAny(name, "=\x00") || strings.HasPrefix(strings.ToUpper(name), terminalReservedVariable) {
			return failure(codeInvalidParams, "An environment name is empty, has = or is reserved.")
		}
		total += len(name)
		if value != nil {
			if len(*value) > maxTerminalValueBytes || strings.ContainsRune(*value, 0) {
				return failure(CodeLimitExceeded, "An environment value is at most 16 KiB.")
			}
			total += len(*value)
		}
	}
	if total > maxTerminalLaunchBytes {
		return failure(CodeLimitExceeded, "The launch data is at most 64 KiB.")
	}
	if request.Title != "" && (len(request.Title) > maxTerminalTitleBytes || strings.ContainsAny(request.Title, "\r\n\x00") || !utf8.ValidString(request.Title)) {
		return failure(codeInvalidParams, "title is one line of at most 128 bytes.")
	}
	return nil
}

func (s *Service) handleTerminalCreate(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request terminalCreateParams
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if refusal := validateTerminal(request); refusal != nil {
		return nil, refusal
	}
	budget, refusal := retainedBudget(request.RetainedBytes)
	if refusal != nil {
		return nil, refusal
	}
	directory := workspace.Path
	if request.Cwd != nil {
		resolved, err := s.resolveResource(caller.PluginID, workspace, *request.Cwd)
		if err != nil {
			return nil, failure(codeInvalidParams, "cwd is not a directory inside the workspace.")
		}
		directory = resolved
	}
	spec := TerminalSpec{
		PluginID: caller.PluginID, Executable: request.Executable, Arguments: request.Arguments,
		Title: request.Title, Directory: directory, Environment: request.Environment,
		Show: request.Show == nil || *request.Show, RetainedBytes: budget,
	}
	handle, refusal := s.reserveTerminal(caller, workspace, spec)
	if refusal != nil {
		return nil, refusal
	}
	if refusal := s.launchTerminal(ctx, handle, 1, ""); refusal != nil {
		s.forgetTerminal(handle)
		return nil, refusal
	}
	return marshalResult(map[string]any{"terminalID": handle.id, "generation": 1})
}

// reserveTerminal makes a handle, refusing the ninth of a plugin.
func (s *Service) reserveTerminal(caller pluginhost.Caller, workspace WorkspaceContext, spec TerminalSpec) (*terminalHandle, *pluginhost.Failure) {
	registry := s.terminals
	registry.mu.Lock()
	defer registry.mu.Unlock()
	owned := 0
	for _, handle := range registry.byID {
		if handle.caller.PluginID == caller.PluginID {
			owned++
		}
	}
	if owned >= maxTerminalsPerPlugin {
		return nil, failure(CodeLimitExceeded, "A plugin keeps at most 8 terminal handles; dispose one first.")
	}
	registry.next++
	handle := &terminalHandle{
		id: "t-" + strconv.Itoa(registry.next), caller: caller, contextID: workspace.ContextID,
		workspace: workspace, spec: spec, budget: spec.RetainedBytes,
	}
	// The handle counts against the limit from the start, so concurrent creates
	// cannot pass it together.
	handle.busy = true
	registry.byID[handle.id] = handle
	handle.resource = s.resources.add(caller, workspace.ContextID, func() { s.disposeTerminal(handle) })
	return handle, nil
}

func (s *Service) forgetTerminal(handle *terminalHandle) {
	s.terminals.mu.Lock()
	delete(s.terminals.byID, handle.id)
	s.terminals.mu.Unlock()
	s.resources.dispose(handle.caller, handle.resource)
}

// launchTerminal starts one generation after the user consented. On failure the
// handle is left as it was.
func (s *Service) launchTerminal(ctx context.Context, handle *terminalHandle, generation int, prefill string) *pluginhost.Failure {
	spec := handle.spec
	spec.Prefill = prefill
	handle.mu.Lock()
	spec.RetainedBytes = handle.budget
	handle.mu.Unlock()
	session, err := s.terminalHost.StartTerminal(ctx, handle.workspace.Path, spec)
	if err != nil {
		handle.mu.Lock()
		handle.busy = false
		handle.mu.Unlock()
		return hostFailureOf(err)
	}
	if ctx.Err() != nil {
		// Cancelled or the context was lost while launching: nothing may keep running.
		closeCtx, cancel := context.WithTimeout(context.Background(), terminalCleanupTimeout)
		_ = session.Close(closeCtx, 0)
		cancel()
		handle.mu.Lock()
		handle.busy = false
		handle.mu.Unlock()
		return failure(pluginhost.CodeCancelled, "The request was cancelled.")
	}
	handle.mu.Lock()
	handle.generation = generation
	handle.session = session
	handle.exit = nil
	handle.delivered = false
	handle.ended = make(chan struct{})
	handle.busy = false
	ended := handle.ended
	handle.mu.Unlock()
	go s.watchTerminal(handle, session, generation, ended)
	return nil
}

// watchTerminal records one generation's outcome and tells the subscriber.
func (s *Service) watchTerminal(handle *terminalHandle, session TerminalSession, generation int, ended chan struct{}) {
	exit := <-session.Done()
	handle.mu.Lock()
	if handle.generation != generation || handle.disposed {
		handle.mu.Unlock()
		close(ended)
		return
	}
	handle.session = nil
	handle.retained = exit.Retained
	handle.exit = &exit
	close(ended)
	s.deliverTerminalExit(handle)
	handle.mu.Unlock()
}

// deliverTerminalExit sends the recorded outcome to the subscriber once. The
// handle's lock is held.
func (s *Service) deliverTerminalExit(handle *terminalHandle) {
	if handle.exitSub == "" || handle.exit == nil || handle.delivered {
		return
	}
	handle.delivered = true
	handle.sequence++
	event := map[string]any{"type": "exit", "terminalID": handle.id, "generation": handle.generation, "exitCode": handle.exit.Code, "reason": handle.exit.Reason}
	params, err := json.Marshal(map[string]any{"subscriptionID": handle.exitSub, "sequence": handle.sequence, "event": event})
	if err != nil {
		return
	}
	sessionID := handle.caller.SessionID
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), terminalCleanupTimeout)
		defer cancel()
		_, _ = s.kernel.SendPluginHostNotification(ctx, sessionID, notifySubscription, params)
	}()
}

// lookupTerminal finds a handle the caller owns. A handle of another plugin,
// session or context generation is not found.
func (s *Service) lookupTerminal(ctx context.Context, ref ContextRef, id string) (*terminalHandle, pluginhost.Caller, *pluginhost.Failure) {
	caller, workspace, refusal := s.workspaceRequest(ctx, ref)
	if refusal != nil {
		return nil, caller, refusal
	}
	s.terminals.mu.Lock()
	handle := s.terminals.byID[id]
	s.terminals.mu.Unlock()
	if handle == nil || handle.caller != caller || handle.contextID != workspace.ContextID {
		return nil, caller, failure(CodeNotFound, "No such terminal.")
	}
	return handle, caller, nil
}

type terminalRefParams struct {
	Context       ContextRef `json:"context"`
	TerminalID    string     `json:"terminalID"`
	RetainedBytes *int       `json:"retainedContextBytes"`
	Show          *bool      `json:"show"`
}

func decodeTerminalRef(params json.RawMessage) (terminalRefParams, *pluginhost.Failure) {
	var request terminalRefParams
	if err := decodeStrict(params, &request); err != nil {
		return request, invalidParams(err)
	}
	return request, nil
}

func (s *Service) handleTerminalShow(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeTerminalRef(params)
	if refusal != nil {
		return nil, refusal
	}
	handle, _, refusal := s.lookupTerminal(ctx, request.Context, request.TerminalID)
	if refusal != nil {
		return nil, refusal
	}
	handle.mu.Lock()
	session := handle.session
	handle.mu.Unlock()
	if session == nil {
		return nil, failure(CodePreconditionFailed, "The terminal is closed; ask the plugin to reopen it.")
	}
	if err := session.Show(ctx); err != nil {
		return nil, hostFailureOf(err)
	}
	return nil, nil
}

// enter marks a handle busy for close, reopen or dispose.
func (handle *terminalHandle) enter() bool {
	handle.mu.Lock()
	defer handle.mu.Unlock()
	if handle.busy || handle.disposed {
		return false
	}
	handle.busy = true
	return true
}

func (handle *terminalHandle) leave() {
	handle.mu.Lock()
	handle.busy = false
	handle.mu.Unlock()
}

const (
	// terminalCleanupTimeout bounds native cleanup of one terminal.
	terminalCleanupTimeout = 10 * time.Second
	// terminalSubscribeDelay orders a recorded outcome after the onExit response.
	terminalSubscribeDelay = 100 * time.Millisecond
)

// closeTerminal ends the live process, if any, and waits for its outcome.
func (s *Service) closeTerminal(ctx context.Context, handle *terminalHandle, budget *int) *pluginhost.Failure {
	handle.mu.Lock()
	session, ended := handle.session, handle.ended
	if budget != nil {
		handle.budget = *budget
	}
	effective := handle.budget
	handle.mu.Unlock()
	if session == nil {
		return nil
	}
	if err := session.Close(ctx, effective); err != nil {
		return hostFailureOf(err)
	}
	select {
	case <-ended:
	case <-ctx.Done():
		return failure(pluginhost.CodeCancelled, "The request was cancelled.")
	}
	return nil
}

func (s *Service) handleTerminalClose(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeTerminalRef(params)
	if refusal != nil {
		return nil, refusal
	}
	budget, refusal := optionalBudget(request.RetainedBytes)
	if refusal != nil {
		return nil, refusal
	}
	handle, _, refusal := s.lookupTerminal(ctx, request.Context, request.TerminalID)
	if refusal != nil {
		return nil, refusal
	}
	if !handle.enter() {
		return nil, failure(CodeBusy, "The terminal is being closed, reopened or disposed.")
	}
	defer handle.leave()
	if refusal := s.closeTerminal(ctx, handle, budget); refusal != nil {
		return nil, refusal
	}
	handle.mu.Lock()
	if budget != nil && len(handle.retained) > *budget {
		handle.retained = trimRetained(handle.retained, *budget)
	}
	retained := len(handle.retained)
	handle.mu.Unlock()
	return marshalResult(map[string]int{"retainedContextBytes": retained})
}

func optionalBudget(value *int) (*int, *pluginhost.Failure) {
	if value == nil {
		return nil, nil
	}
	budget, refusal := retainedBudget(value)
	if refusal != nil {
		return nil, refusal
	}
	return &budget, nil
}

// trimRetained keeps the last budget bytes without splitting a character.
func trimRetained(text string, budget int) string {
	if budget <= 0 {
		return ""
	}
	if len(text) <= budget {
		return text
	}
	text = text[len(text)-budget:]
	for len(text) > 0 && !utf8.RuneStart(text[0]) {
		text = text[1:]
	}
	return text
}

func (s *Service) handleTerminalReopen(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeTerminalRef(params)
	if refusal != nil {
		return nil, refusal
	}
	handle, _, refusal := s.lookupTerminal(ctx, request.Context, request.TerminalID)
	if refusal != nil {
		return nil, refusal
	}
	if !handle.enter() {
		return nil, failure(CodeBusy, "The terminal is being closed, reopened or disposed.")
	}
	handle.mu.Lock()
	running := handle.session != nil
	prefill := handle.retained
	generation := handle.generation + 1
	if request.Show != nil {
		handle.spec.Show = *request.Show
	} else {
		handle.spec.Show = true
	}
	handle.mu.Unlock()
	if running {
		handle.leave()
		return nil, failure(CodePreconditionFailed, "The terminal is still running.")
	}
	// launchTerminal clears busy itself on every path.
	if refusal := s.launchTerminal(ctx, handle, generation, prefill); refusal != nil {
		return nil, refusal
	}
	return marshalResult(map[string]any{"terminalID": handle.id, "generation": generation, "restoredContextBytes": len(prefill)})
}

func (s *Service) handleTerminalDispose(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeTerminalRef(params)
	if refusal != nil {
		return nil, refusal
	}
	handle, _, refusal := s.lookupTerminal(ctx, request.Context, request.TerminalID)
	if refusal != nil {
		return nil, refusal
	}
	if !handle.enter() {
		return nil, failure(CodeBusy, "The terminal is being closed, reopened or disposed.")
	}
	s.disposeTerminal(handle)
	return nil, nil
}

// disposeTerminal closes a live process and forgets the handle for good. It is
// also what ending the session, disabling the plugin or closing the context runs.
func (s *Service) disposeTerminal(handle *terminalHandle) {
	handle.mu.Lock()
	if handle.disposed {
		handle.mu.Unlock()
		return
	}
	handle.disposed = true
	session := handle.session
	handle.session = nil
	handle.retained = ""
	sub := handle.exitSub
	handle.exitSub = ""
	handle.mu.Unlock()
	s.terminals.mu.Lock()
	delete(s.terminals.byID, handle.id)
	s.terminals.mu.Unlock()
	if session != nil {
		ctx, cancel := context.WithTimeout(context.Background(), terminalCleanupTimeout)
		_ = session.Close(ctx, 0)
		cancel()
	}
	if sub != "" {
		s.resources.dispose(handle.caller, sub)
	}
	s.resources.dispose(handle.caller, handle.resource)
}

func (s *Service) handleTerminalOnExit(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeTerminalRef(params)
	if refusal != nil {
		return nil, refusal
	}
	handle, caller, refusal := s.lookupTerminal(ctx, request.Context, request.TerminalID)
	if refusal != nil {
		return nil, refusal
	}
	handle.mu.Lock()
	defer handle.mu.Unlock()
	if handle.exitSub != "" {
		return nil, failure(CodePreconditionFailed, "The terminal already has an exit subscription.")
	}
	id := s.resources.add(caller, handle.contextID, func() {
		handle.mu.Lock()
		handle.exitSub = ""
		handle.mu.Unlock()
	})
	handle.exitSub = id
	// An outcome recorded before the subscription is delivered once, after the
	// subscriber has its ID.
	if handle.exit != nil {
		handle.delivered = false
		defer func() { s.deliverTerminalExitLocked(handle) }()
	}
	return marshalResult(map[string]string{"subscriptionID": id})
}

// deliverTerminalExitLocked is deliverTerminalExit for a caller that holds the
// handle's lock and wants the notification after the response is queued.
func (s *Service) deliverTerminalExitLocked(handle *terminalHandle) {
	go func() {
		// The subscriber learns its subscription ID from the response, so the
		// notification of an outcome that was already recorded follows it after a
		// short pause instead of racing it.
		time.Sleep(terminalSubscribeDelay)
		handle.mu.Lock()
		defer handle.mu.Unlock()
		s.deliverTerminalExit(handle)
	}()
}
