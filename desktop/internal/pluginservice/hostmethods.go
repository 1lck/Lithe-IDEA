package pluginservice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// Host service grants and methods this client answers. A launch plan lists
// service-level grants ("workspace", "functions") next to method-level ones, and
// Core narrows the session to the intersection with what Register/GrantService
// declared here, so a method is only advertised when a handler exists.
const (
	grantWorkspace = "workspace"
	// grantFunctions is the cross-plugin relay. Core finds the provider, checks the
	// declarations and dispatches the call itself; the host only supplies the
	// plugin and context snapshot (SyncFunctionRelay) and starts a callee's backend.
	grantFunctions = "functions"

	methodListContexts   = pluginhost.MethodPrefix + "workspace/listContexts"
	methodGetContext     = pluginhost.MethodPrefix + "workspace/getContext"
	methodGetFolders     = pluginhost.MethodPrefix + "workspace/getFolders"
	methodDisposeSub     = pluginhost.MethodPrefix + "subscriptions/dispose"
	methodLSRequest      = pluginhost.MethodPrefix + "languageServer/request"
	methodLSNotify       = pluginhost.MethodPrefix + "languageServer/notify"
	methodLSSetStatus    = pluginhost.MethodPrefix + "languageServer/setStatus"
	notifyDidChangeCtxs  = pluginhost.MethodPrefix + "workspace/didChangeContexts"
	notifyLSState        = pluginhost.MethodPrefix + "languageServer/didChangeState"
	notifyLSNotification = pluginhost.MethodPrefix + "languageServer/didReceiveNotification"
)

// registerHostServices wires the handlers of every host service this client
// serves. A later service (run, debug, terminal, editor, documents, credentials)
// adds one more register call here: a handler gets the caller from
// pluginhost.CallerFrom, so per-plugin scoping never needs a second registry.
func (s *Service) registerHostServices() error {
	machine := []struct {
		method  string
		handler pluginhost.Handler
	}{
		{methodListContexts, s.handleListContexts},
		{methodGetContext, s.handleGetContext},
		{methodGetFolders, s.handleGetFolders},
		{methodDisposeSub, s.handleDisposeSubscription},
		{methodLSNotify, s.handleLanguageServerNotify},
		{methodLSSetStatus, s.handleLanguageServerSetStatus},
	}
	for _, entry := range machine {
		if err := s.HostServices.Register(entry.method, entry.handler); err != nil {
			return err
		}
	}
	// A language-server request waits for the server, up to the request's own
	// timeout (at most 300 s), so the machine deadline of 30 s must not cut it.
	if err := s.HostServices.RegisterUserChoice(methodLSRequest, s.handleLanguageServerRequest); err != nil {
		return err
	}
	if err := s.registerCredentials(); err != nil {
		return err
	}
	// run/start answers after the process started and returns at once, so the
	// machine deadline is enough; the run itself outlives the request.
	if err := s.HostServices.Register(methodRunStart, s.Runs.handleStart); err != nil {
		return err
	}
	if err := s.HostServices.Register(methodRunStop, s.Runs.handleStop); err != nil {
		return err
	}
	for _, grant := range []string{grantWorkspace, grantFunctions} {
		if err := s.HostServices.GrantService(grant); err != nil {
			return err
		}
	}
	return nil
}

func failure(code, message string) *pluginhost.Failure {
	return &pluginhost.Failure{Code: code, Message: message}
}

func invalidParams(err error) *pluginhost.Failure {
	return failure("plugin.host.invalidParams", err.Error())
}

func contextFailure(err error) *pluginhost.Failure {
	if errors.Is(err, ErrContextExpired) {
		return failure("plugin.host.contextExpired", "The workspace context is closed or replaced.")
	}
	return failure(pluginhost.CodeHostFailure, err.Error())
}

type contextJSON struct {
	ContextID      string         `json:"contextID"`
	Generation     uint64         `json:"generation"`
	Name           string         `json:"name"`
	Authority      map[string]any `json:"authority"`
	Folders        []folderJSON   `json:"folders"`
	StateDirectory string         `json:"stateDirectory,omitempty"`
}

type folderJSON struct {
	RootID string `json:"rootID"`
	Name   string `json:"name"`
	Path   string `json:"path"`
}

func (s *Service) contextJSON(pluginID string, workspace WorkspaceContext) contextJSON {
	return contextJSON{
		ContextID:  workspace.ContextID,
		Generation: workspace.Generation,
		Name:       workspace.Name,
		Authority:  map[string]any{"kind": "local"},
		Folders:    []folderJSON{{RootID: s.Contexts.RootID(pluginID, workspace.Path), Name: workspace.Name, Path: workspace.Path}},
	}
}

// contextState is the plugin's private directory of one workspace, outside the
// plugin package and the application bundle. It is created on first use here and
// nowhere else, so listing contexts leaves no directories behind.
func (s *Service) contextState(pluginID string, workspace WorkspaceContext) (string, error) {
	directory := filepath.Join(s.Root, pluginStateDirectory, pluginID, "backend", "workspaces", WorkspaceKey(workspace.Path))
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", err
	}
	return directory, nil
}

func (s *Service) handleListContexts(ctx context.Context, _ json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	revision, workspaces := s.Contexts.List()
	contexts := make([]contextJSON, 0, len(workspaces))
	for _, workspace := range workspaces {
		contexts = append(contexts, s.contextJSON(caller.PluginID, workspace))
	}
	return marshalResult(map[string]any{"revision": revision, "contexts": contexts})
}

type contextParams struct {
	Context ContextRef `json:"context"`
}

func (s *Service) handleGetContext(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request contextParams
	if err := json.Unmarshal(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	workspace, err := s.Contexts.Lookup(request.Context)
	if err != nil {
		return nil, contextFailure(err)
	}
	value := s.contextJSON(caller.PluginID, workspace)
	state, err := s.contextState(caller.PluginID, workspace)
	if err != nil {
		return nil, failure(pluginhost.CodeHostFailure, "the workspace state directory cannot be created")
	}
	value.StateDirectory = state
	return marshalResult(value)
}

func (s *Service) handleGetFolders(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request contextParams
	if err := json.Unmarshal(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	workspace, err := s.Contexts.Lookup(request.Context)
	if err != nil {
		return nil, contextFailure(err)
	}
	return marshalResult(map[string]any{"folders": s.contextJSON(caller.PluginID, workspace).Folders})
}

func marshalResult(value any) (json.RawMessage, *pluginhost.Failure) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, failure(pluginhost.CodeHostFailure, err.Error())
	}
	return data, nil
}

type languageServerParams struct {
	Context             ContextRef      `json:"context"`
	ServerID            string          `json:"serverID"`
	Method              string          `json:"method"`
	Params              json.RawMessage `json:"params"`
	TimeoutMilliseconds int             `json:"timeoutMilliseconds"`
	State               string          `json:"state"`
	Message             string          `json:"message"`
	Percentage          *int            `json:"percentage"`
}

// resolveLanguageSession finds the caller's own running server for a context.
func (s *Service) resolveLanguageSession(ctx context.Context, params json.RawMessage) (languageServerParams, *LanguageSession, string, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return languageServerParams{}, nil, "", failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request languageServerParams
	if err := json.Unmarshal(params, &request); err != nil {
		return request, nil, "", invalidParams(err)
	}
	if _, err := s.Contexts.Lookup(request.Context); err != nil {
		return request, nil, "", contextFailure(err)
	}
	session, foreign := s.languageSession(caller.PluginID, request.ServerID, request.Context.ContextID)
	if session == nil {
		if foreign {
			return request, nil, "", failure("plugin.host.foreignContribution", "The language server belongs to another plugin.")
		}
		return request, nil, "", failure("plugin.host.languageServerUnavailable", "The language server is not running for this context.")
	}
	return request, session, caller.PluginID, nil
}

func (s *Service) handleLanguageServerRequest(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, session, pluginID, refusal := s.resolveLanguageSession(ctx, params)
	if refusal != nil {
		return nil, refusal
	}
	if request.Params == nil {
		request.Params = json.RawMessage("{}")
	}
	value, err := session.request(ctx, s.kernel, pluginID, request.ServerID, request.Method, request.Params, request.TimeoutMilliseconds)
	if err != nil {
		var event *eventFailure
		switch {
		case errors.As(err, &event):
			return nil, &pluginhost.Failure{Code: event.Code, Message: event.Message, Details: event.Details}
		case errors.Is(err, context.Canceled):
			return nil, failure(pluginhost.CodeCancelled, "The request was cancelled.")
		case errors.Is(err, ErrBackendUnavailable):
			return nil, failure("plugin.host.languageServerUnavailable", "The language server stopped.")
		}
		return nil, failure(pluginhost.CodeHostFailure, err.Error())
	}
	return marshalResult(map[string]json.RawMessage{"value": value})
}

func (s *Service) handleLanguageServerNotify(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, session, pluginID, refusal := s.resolveLanguageSession(ctx, params)
	if refusal != nil {
		return nil, refusal
	}
	delivered, err := s.kernel.PluginServerNotify(ctx, session.Session.ID, pluginID, request.ServerID, request.Method, request.Params)
	if err != nil {
		return nil, coreFailure(err)
	}
	return marshalResult(map[string]bool{"delivered": delivered})
}

func (s *Service) handleLanguageServerSetStatus(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, session, _, refusal := s.resolveLanguageSession(ctx, params)
	if refusal != nil {
		return nil, refusal
	}
	session.setStatus(LanguageStatus{State: request.State, Message: request.Message, Percentage: request.Percentage})
	return json.RawMessage("{}"), nil
}

// coreFailure maps a Core refusal to a host failure, keeping a plugin.host.* code
// Core put in the details.
func coreFailure(err error) *pluginhost.Failure {
	var coreErr *core.Error
	if errors.As(err, &coreErr) && len(coreErr.Details) > 0 && len(coreErr.Details) < 128 && len(coreErr.Details) > len("plugin.host.") && coreErr.Details[:len("plugin.host.")] == "plugin.host." {
		return &pluginhost.Failure{Code: coreErr.Details, Message: coreErr.Message}
	}
	return failure(pluginhost.CodeHostFailure, fmt.Sprint(err))
}

// decodeStrict decodes params and refuses a field the method does not define, as
// the contract asks of a host that sees params Core did not type.
func decodeStrict(params json.RawMessage, into any) error {
	if len(bytes.TrimSpace(params)) == 0 {
		params = json.RawMessage("{}")
	}
	decoder := json.NewDecoder(bytes.NewReader(params))
	decoder.DisallowUnknownFields()
	return decoder.Decode(into)
}

// decodeStrictEmbedded is decodeStrict for a request type that embeds a struct:
// encoding/json flattens the embedded fields, but DisallowUnknownFields cannot
// see through a name list, so the allowed members are checked here.
func decodeStrictEmbedded(params json.RawMessage, into any, allowed ...string) error {
	var members map[string]json.RawMessage
	if err := json.Unmarshal(params, &members); err != nil {
		return err
	}
	known := make(map[string]struct{}, len(allowed))
	for _, name := range allowed {
		known[name] = struct{}{}
	}
	for name := range members {
		if _, ok := known[name]; !ok {
			return fmt.Errorf("unknown field %q", name)
		}
	}
	return json.Unmarshal(params, into)
}
