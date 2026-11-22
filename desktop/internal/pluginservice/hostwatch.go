package pluginservice

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const (
	maxWorkspaceWatches    = 16
	maxWorkspaceWatchPaths = 1024
	maxWorkspaceWatchBytes = 128 * 1024
)

type workspaceWatchBatch struct {
	connection *core.RemoteWorkspaceConnection
	paths      []string
	bytes      int
	rescan     bool
}

type workspaceWatch struct {
	workspace *core.RemoteWorkspace
	request   core.PluginWatchChangesRequest
	wake      chan struct{}

	mu      sync.Mutex
	pending workspaceWatchBatch
}

func (s *Service) handleWorkspaceWatch(ctx context.Context, raw json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context   ContextRef      `json:"context"`
		Resource  json.RawMessage `json:"resource"`
		Recursive bool            `json:"recursive"`
	}
	if err := decodeStrict(raw, &request); err != nil {
		return nil, invalidParams(err)
	}
	_, session, refusal := s.backendCaller(ctx)
	if refusal != nil {
		return nil, refusal
	}
	caller, workspace, resource, connection, refusal := s.remoteFileResource(ctx, request.Context, request.Resource)
	if refusal != nil {
		return nil, refusal
	}
	result, refusal := s.readRemotePluginFile(ctx, workspace, connection, resource, core.PluginFileOperation{Kind: "watch"})
	if refusal != nil {
		return nil, refusal
	}
	var target struct {
		Path      *string `json:"path"`
		Directory bool    `json:"directory"`
	}
	if err := json.Unmarshal(result, &target); err != nil || target.Path == nil {
		return nil, failure(pluginhost.CodeHostFailure, "The workspace watch target could not be resolved.")
	}
	watch := &workspaceWatch{
		workspace: workspace.remote.binding,
		request: core.PluginWatchChangesRequest{
			RootID: resource.RootID, HostRoot: workspace.remote.binding.RemoteRoot(), Path: *target.Path,
			Directory: target.Directory, Recursive: request.Recursive,
		},
		wake: make(chan struct{}, 1),
	}
	lifetime, stop := context.WithCancel(workspace.lifetime)
	s.workspaceWatchesMu.Lock()
	id := s.resources.addLimited(caller, workspace.ContextRef, func() {
		stop()
		s.workspaceWatchesMu.Lock()
		delete(s.workspaceWatches, watch)
		s.workspaceWatchesMu.Unlock()
	}, maxWorkspaceWatches)
	if id != "" {
		s.workspaceWatches[watch] = struct{}{}
	}
	s.workspaceWatchesMu.Unlock()
	if id == "" {
		stop()
		return nil, failure("plugin.host.limitExceeded", "The backend has reached its workspace watch limit.")
	}
	if lifetime.Err() != nil || session.isEnded() || ctx.Err() != nil || !connection.IsCurrent() {
		s.resources.dispose(caller, id)
		return nil, failure(pluginhost.CodeCancelled, "The workspace changed while opening the watch.")
	}
	go s.serveWorkspaceWatch(lifetime, caller, id, watch)
	return marshalResult(map[string]string{"subscriptionID": id})
}

// PublishRemoteWorkspaceChanges feeds the already-running workbench watch to
// subscriptions of the same workspace. The window never waits for a plugin.
func (s *Service) PublishRemoteWorkspaceChanges(workspace *core.RemoteWorkspace, connection *core.RemoteWorkspaceConnection, paths []string, rescan bool) {
	if connection == nil || (len(paths) == 0 && !rescan) {
		return
	}
	s.workspaceWatchesMu.Lock()
	defer s.workspaceWatchesMu.Unlock()
	for watch := range s.workspaceWatches {
		if watch.workspace == workspace {
			watch.offer(connection, paths, rescan)
		}
	}
}

func (w *workspaceWatch) offer(connection *core.RemoteWorkspaceConnection, paths []string, rescan bool) {
	w.mu.Lock()
	pending := &w.pending
	if pending.connection != nil && !pending.connection.SameAttachment(connection) {
		rescan = true
	}
	pending.connection = connection
	pending.rescan = pending.rescan || rescan || !connection.IsCurrent() ||
		len(pending.paths)+len(paths) > maxWorkspaceWatchPaths
	if !pending.rescan {
		for _, path := range paths {
			pending.bytes += len(path)
			if pending.bytes > maxWorkspaceWatchBytes {
				pending.rescan = true
				break
			}
		}
	}
	if pending.rescan {
		pending.paths, pending.bytes = nil, 0
	} else {
		pending.paths = append(pending.paths, paths...)
	}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

func (s *Service) serveWorkspaceWatch(lifetime context.Context, caller pluginhost.Caller, id string, watch *workspaceWatch) {
	defer s.resources.dispose(caller, id)
	var sequence uint64
	for {
		select {
		case <-lifetime.Done():
			return
		case <-watch.wake:
		}
		watch.mu.Lock()
		batch := watch.pending
		watch.pending = workspaceWatchBatch{}
		watch.mu.Unlock()
		if batch.connection == nil {
			continue
		}
		request := watch.request
		request.HostPaths = batch.paths
		request.RequiresRescan = batch.rescan || !batch.connection.IsCurrent()
		if request.RequiresRescan {
			request.HostPaths = nil
		}
		call, cancel := context.WithTimeout(lifetime, 5*time.Second)
		event, err := s.kernel.PluginWatchChanges(call, request)
		cancel()
		if lifetime.Err() != nil {
			return
		}
		if err != nil {
			if s.WorkspaceWatchIssue != nil {
				s.WorkspaceWatchIssue(lifetime, err)
			}
			// A failed projection or a concurrent reattachment invalidates the
			// path details. A rescan is still useful on the original context.
			event = workspaceWatchRescan(request.RootID)
		} else if !batch.connection.IsCurrent() {
			event = workspaceWatchRescan(request.RootID)
		}
		if len(event) == 0 || string(event) == "null" {
			continue
		}
		sequence++
		params, err := json.Marshal(struct {
			ID       string          `json:"subscriptionID"`
			Sequence uint64          `json:"sequence"`
			Event    json.RawMessage `json:"event"`
		}{id, sequence, event})
		if err != nil {
			if s.WorkspaceWatchIssue != nil {
				s.WorkspaceWatchIssue(lifetime, err)
			}
			return
		}
		call, cancel = context.WithTimeout(lifetime, 5*time.Second)
		// Core records notification admission and terminal outcomes.
		_, _ = s.kernel.SendPluginHostNotification(call, caller.SessionID, notifySubscription, params)
		cancel()
	}
}

func workspaceWatchRescan(rootID string) json.RawMessage {
	// rootID is a host-generated, JSON-encodable identifier.
	event, _ := json.Marshal(struct {
		RootID         string   `json:"rootID"`
		ChangedPaths   []string `json:"changedPaths"`
		RequiresRescan bool     `json:"requiresRescan"`
	}{rootID, []string{}, true})
	return event
}
