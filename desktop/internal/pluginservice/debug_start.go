package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const methodDebugStart = pluginhost.MethodPrefix + "debug/start"

// DebugSessionRequest asks the host to start a debug session on one of a
// plugin's own adapters. Core already validated every field: the adapter is the
// plugin's own (AdapterID is qualified), Request is "launch" or "attach" and the
// adapter serves it, and Configuration holds no key the host reserves.
type DebugSessionRequest struct {
	PluginID      string
	WorkspaceRoot string
	Label         string
	AdapterID     string
	Request       string
	// Configuration is the plugin's DAP launch or attach arguments, applied on
	// top of the adapter's declared defaults.
	Configuration map[string]any
}

// DebugSessionStarter starts the session and returns its ID. It is the window's:
// the debug engine, the adapter process or stream and the panel belong to it.
type DebugSessionStarter func(ctx context.Context, request DebugSessionRequest) (sessionID string, err error)

// DebugSessionStopper ends a session the plugin started.
type DebugSessionStopper func(sessionID string)

// handleDebugStart answers lithe/host/debug/start. The backend names its own
// adapter and the host starts the session; the session then belongs to the
// window like one the user started, and run/stop with its sessionID ends it.
func (r *Runs) handleDebugStart(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request struct {
		Context ContextRef `json:"context"`
	}
	if err := json.Unmarshal(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	workspace, err := r.service.Contexts.Lookup(request.Context)
	if err != nil {
		return nil, contextFailure(err)
	}
	_, manifest, err := r.service.installedPlugin(ctx, caller.PluginID)
	if err != nil {
		return nil, failure(pluginhost.CodeHostFailure, err.Error())
	}
	start, err := r.service.kernel.DecodeDebugBackendConfiguration(ctx, manifest, params)
	if err != nil {
		return nil, runStartFailure(err)
	}
	// Core answers with the qualified adapter ID of the plugin's own adapter; a
	// foreign one was refused above, so the prefix is the caller's own.
	if !strings.HasPrefix(start.AdapterID, caller.PluginID+"/") {
		return nil, failure("plugin.host.foreignContribution", "The adapter belongs to another plugin.")
	}
	r.mu.Lock()
	starter := r.StartDebugSession
	r.mu.Unlock()
	if starter == nil {
		return nil, failure("plugin.host.unavailable", "This host starts no debug sessions.")
	}
	sessionID, err := starter(ctx, DebugSessionRequest{
		PluginID: caller.PluginID, WorkspaceRoot: workspace.Path, Label: start.Label,
		AdapterID: start.AdapterID, Request: start.Request, Configuration: start.Configuration,
	})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil, failure("plugin.host.cancelled", "The request was cancelled.")
		}
		return nil, failure(pluginhost.CodeHostFailure, err.Error())
	}
	r.mu.Lock()
	r.debugSessions[sessionID] = caller.PluginID
	r.mu.Unlock()
	return marshalResult(map[string]string{"sessionID": sessionID})
}

// stopDebugSession ends a session the calling plugin started. An unknown or
// foreign one is the same null answer as one that already ended.
func (r *Runs) stopDebugSession(pluginID, sessionID string) {
	r.mu.Lock()
	owner, known := r.debugSessions[sessionID]
	stop := r.StopDebugSession
	if known && owner == pluginID {
		delete(r.debugSessions, sessionID)
	} else {
		stop = nil
	}
	r.mu.Unlock()
	if stop != nil {
		stop(sessionID)
	}
}
