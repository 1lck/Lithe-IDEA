package pluginhost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

// MethodPrefix is the namespace every host service method lives in. Grants in a
// start request use full method names rather than service names.
const MethodPrefix = "lithe/host/"

// RequestTimeout is the deadline a machine host request gets. User-choice
// messages are exempt: they wait for the user, cancellation or session close.
const RequestTimeout = 30 * time.Second

// Failure codes the contract defines for a refused host request.
const (
	// CodeMethodNotDeclared reports a method this host never registered.
	CodeMethodNotDeclared = "plugin.host.methodNotDeclared"
	// CodePermissionDenied reports a method the plugin's permissions do not grant.
	CodePermissionDenied = "plugin.host.permissionDenied"
	// CodeCancelled reports a request the backend cancelled or the host stopped.
	CodeCancelled = "plugin.host.cancelled"
	// CodeUnsupportedOption reports an option the method does not define.
	CodeUnsupportedOption = "plugin.host.unsupportedOption"
	// CodeHostFailure reports a failure in this host's own handler rather than in
	// the request. The contract has no code for it because the plugin is not at
	// fault; reporting it as an undeclared method would make the plugin drop the
	// capability for good.
	CodeHostFailure = "plugin.host.failure"
)

// ErrServiceRegistration reports a handler that cannot be registered.
var ErrServiceRegistration = errors.New("plugin host service cannot be registered")

// Failure is a structured host refusal Core relays back to the plugin. A nil
// Failure means the handler succeeded.
type Failure struct {
	// Code is one of the contract's plugin.host.* codes.
	Code string
	// Message is a short English explanation for the log.
	Message string
	// Details carries the option name or other structured context.
	Details json.RawMessage
}

// Caller identifies the plugin session a host request came from. Core checks the
// grant before it forwards a request, but only the host knows which plugin the
// session belongs to, so a handler that must scope its answer to the caller
// (state directories, ownership of a language server) reads it here.
type Caller struct {
	// PluginID is the plugin that owns the backend session.
	PluginID string
	// SessionID is Core's session identifier.
	SessionID string
}

type callerKey struct{}

// WithCaller returns a context that carries the request's caller.
func WithCaller(ctx context.Context, caller Caller) context.Context {
	return context.WithValue(ctx, callerKey{}, caller)
}

// CallerFrom returns the caller of the request being answered.
func CallerFrom(ctx context.Context) (Caller, bool) {
	caller, ok := ctx.Value(callerKey{}).(Caller)
	return caller, ok && caller.PluginID != ""
}

// Handler answers one host request. It returns either a result or a failure,
// never both.
type Handler func(ctx context.Context, params json.RawMessage) (json.RawMessage, *Failure)

// serviceHandler is one registered method and how its requests are bounded.
type serviceHandler struct {
	handler Handler
	// userChoice says the request waits for the user, so the machine deadline
	// does not apply to it.
	userChoice bool
}

// Services dispatches the host requests Core forwards from a plugin backend.
//
// It is the caller of Core's host response path: nothing else in the client may
// answer a forwarded request, so every answer goes through the same registration
// and deadline rules.
type Services struct {
	mu       sync.RWMutex
	handlers map[string]serviceHandler
	// serviceGrants are service-level grant names a launch plan lists next to
	// method names, such as "workspace" or "functions".
	serviceGrants map[string]struct{}
}

// NewServices returns an empty registry.
func NewServices() *Services {
	return &Services{handlers: make(map[string]serviceHandler), serviceGrants: make(map[string]struct{})}
}

// GrantService makes a service-level grant name available, for a service whose
// requests this host answers through registered handlers or Core itself (the
// cross-plugin "functions" relay). A grant name is not a method name, so it is
// kept apart from the handlers: Respond never dispatches on it.
func (s *Services) GrantService(name string) error {
	if name == "" || len(name) > 64 {
		return fmt.Errorf("%w: %q is not a service grant", ErrServiceRegistration, name)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.serviceGrants[name] = struct{}{}
	return nil
}

// Register adds one machine handler under its full method name.
//
// A method may be registered once: the contract says a later registration cannot
// replace an earlier one, so a second call is an error rather than a silent
// override that would change what a running backend is talking to.
func (s *Services) Register(method string, handler Handler) error {
	return s.register(method, handler, false)
}

// RegisterUserChoice adds a handler whose requests wait for the user.
//
// The contract bounds machine requests at RequestTimeout but lets a user-choice
// message wait until the user answers, the request is cancelled or the session
// closes. Registering such a method as a machine handler would answer it with
// "cancelled" after thirty seconds.
func (s *Services) RegisterUserChoice(method string, handler Handler) error {
	return s.register(method, handler, true)
}

func (s *Services) register(method string, handler Handler, userChoice bool) error {
	if !validMethod(method) {
		return fmt.Errorf("%w: %q is not a host method name", ErrServiceRegistration, method)
	}
	if handler == nil {
		return fmt.Errorf("%w: %q has no handler", ErrServiceRegistration, method)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.handlers[method]; exists {
		return fmt.Errorf("%w: %q is already registered", ErrServiceRegistration, method)
	}
	s.handlers[method] = serviceHandler{handler: handler, userChoice: userChoice}
	return nil
}

// Grant reports the sorted method names this host can answer. It is what a start
// request may advertise; advertising a method that is not registered would let a
// backend call into a hole.
func (s *Services) Grant() []string {
	if s == nil {
		return nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	methods := make([]string, 0, len(s.handlers)+len(s.serviceGrants))
	for method := range s.handlers {
		methods = append(methods, method)
	}
	for name := range s.serviceGrants {
		methods = append(methods, name)
	}
	sort.Strings(methods)
	return methods
}

// Respond answers one forwarded request.
//
// A method that was never registered is reported as methodNotDeclared rather than
// panicking, because the request comes from a plugin process. A request whose
// context ends is reported as cancelled. A machine request is bounded by
// RequestTimeout unless the caller already set a deadline.
func (s *Services) Respond(ctx context.Context, method string, params json.RawMessage) (json.RawMessage, *Failure) {
	if s == nil {
		return nil, &Failure{Code: CodeMethodNotDeclared, Message: "no handler is registered for " + method}
	}
	s.mu.RLock()
	entry, ok := s.handlers[method]
	s.mu.RUnlock()
	if !ok {
		return nil, &Failure{Code: CodeMethodNotDeclared, Message: "no handler is registered for " + method}
	}
	if ctx == nil {
		ctx = context.Background()
	}
	// A user-choice request waits for the user; only a machine request gets the
	// contract's deadline.
	if !entry.userChoice {
		if _, bounded := ctx.Deadline(); !bounded {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, RequestTimeout)
			defer cancel()
		}
	}
	result, failure := entry.handler(ctx, params)
	if failure != nil {
		return nil, failure
	}
	if err := ctx.Err(); err != nil {
		// The handler may have finished after the deadline or after the session
		// closed; the plugin must not receive a result it can no longer use.
		return nil, &Failure{Code: CodeCancelled, Message: err.Error()}
	}
	if len(result) != 0 && !json.Valid(result) {
		// The handler, not the plugin, is at fault. Reporting this as an undeclared
		// method would make the plugin drop the capability for good.
		return nil, &Failure{Code: CodeHostFailure, Message: "the handler for " + method + " returned invalid JSON"}
	}
	return result, nil
}

// validMethod reports whether a name is a full host method name.
func validMethod(method string) bool {
	if len(method) <= len(MethodPrefix) || method[:len(MethodPrefix)] != MethodPrefix {
		return false
	}
	for i := len(MethodPrefix); i < len(method); i++ {
		c := method[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == '/' || c == '.' || c == '_' || c == '-':
		default:
			return false
		}
	}
	return true
}
