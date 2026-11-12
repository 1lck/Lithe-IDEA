package pluginservice

import (
	"context"
	"encoding/json"
	"strconv"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// hostResource is something a backend holds in the host: a subscription, a
// content provider, a terminal handle. The session that created it owns it, and
// so does the workspace context it was made for, so ending either one releases it.
type hostResource struct {
	id        string
	pluginID  string
	sessionID string
	contextID string
	// dispose releases the resource. It runs once, without the registry lock.
	dispose func()
}

// hostResources is the registry of backend-owned resources.
//
// A subscription ID must stay in the key alphabet and be unguessable across
// plugins only in the sense that another plugin cannot dispose it: ownership is
// checked against the caller, not hidden in the ID.
type hostResources struct {
	mu   sync.Mutex
	next uint64
	byID map[string]*hostResource
}

func newHostResources() *hostResources {
	return &hostResources{byID: make(map[string]*hostResource)}
}

// add records a resource and returns its subscription ID.
func (r *hostResources) add(caller pluginhost.Caller, contextID string, dispose func()) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.next++
	id := "s-" + strconv.FormatUint(r.next, 10)
	r.byID[id] = &hostResource{id: id, pluginID: caller.PluginID, sessionID: caller.SessionID, contextID: contextID, dispose: dispose}
	return id
}

// dispose releases one resource the caller owns. Disposing an unknown, foreign or
// already disposed ID succeeds without effect, as the contract asks.
func (r *hostResources) dispose(caller pluginhost.Caller, id string) {
	r.mu.Lock()
	resource := r.byID[id]
	if resource == nil || resource.pluginID != caller.PluginID || resource.sessionID != caller.SessionID {
		r.mu.Unlock()
		return
	}
	delete(r.byID, id)
	r.mu.Unlock()
	if resource.dispose != nil {
		resource.dispose()
	}
}

func (r *hostResources) releaseWhere(match func(*hostResource) bool) {
	r.mu.Lock()
	var released []*hostResource
	for id, resource := range r.byID {
		if match(resource) {
			released = append(released, resource)
			delete(r.byID, id)
		}
	}
	r.mu.Unlock()
	for _, resource := range released {
		if resource.dispose != nil {
			resource.dispose()
		}
	}
}

// releaseSession releases everything a backend session created.
func (r *hostResources) releaseSession(sessionID string) {
	r.releaseWhere(func(resource *hostResource) bool { return resource.sessionID == sessionID })
}

// releaseContext releases everything made for a closed workspace context.
func (r *hostResources) releaseContext(contextID string) {
	r.releaseWhere(func(resource *hostResource) bool { return resource.contextID != "" && resource.contextID == contextID })
}

// releasePlugin releases everything one plugin holds, for disable and update.
func (r *hostResources) releasePlugin(pluginID string) {
	r.releaseWhere(func(resource *hostResource) bool { return resource.pluginID == pluginID })
}

type disposeParams struct {
	SubscriptionID string `json:"subscriptionID"`
}

// handleDisposeSubscription releases a subscription of the calling session.
func (s *Service) handleDisposeSubscription(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	var request disposeParams
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	s.resources.dispose(caller, request.SubscriptionID)
	return nil, nil
}
