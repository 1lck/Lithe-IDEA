package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/vivaui/viva/app"
)

const methodWorkspaceWatch = pluginhost.MethodPrefix + "workspace/watch"

// WorkspaceWatchHost delegates watch scope and event projection to Core.
// root remains the window's context path even if Core canonicalizes plan.Root.
type WorkspaceWatchHost interface {
	PlanWatch(context.Context, string, string, bool) (core.WorkspaceWatchPlan, error)
	FilterWatchEvents(context.Context, string, core.WorkspaceWatchPlan, []string, bool) (core.WorkspaceWatchEvents, error)
}

// workspaceWatch serializes delivery with disposal. Cancelling before taking mu
// also interrupts a notification already waiting for Core's bounded queue.
type workspaceWatch struct {
	mu     sync.Mutex
	closed bool
	native *app.DirectoryWatch
	cancel context.CancelFunc
}

func (w *workspaceWatch) stop() {
	w.cancel()
	w.mu.Lock()
	defer w.mu.Unlock()
	w.closed = true
	if w.native != nil {
		w.native.Close()
		w.native = nil
	}
}

func (s *Service) registerWorkspaceWatch(host WorkspaceWatchHost) error {
	return s.HostServices.Register(methodWorkspaceWatch, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
		return s.handleWorkspaceWatch(ctx, host, params)
	})
}

func (s *Service) handleWorkspaceWatch(ctx context.Context, host WorkspaceWatchHost, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context   ContextRef `json:"context"`
		Resource  Resource   `json:"resource"`
		Recursive bool       `json:"recursive"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if refusal := s.checkRoot(caller.PluginID, workspace, request.Resource); refusal != nil {
		return nil, refusal
	}
	_, session, refusal := s.buildCaller(ctx)
	if refusal != nil {
		return nil, refusal
	}
	if session.isEnded() {
		return nil, failure(pluginhost.CodeCancelled, "The requesting backend session ended.")
	}
	plan, err := host.PlanWatch(ctx, workspace.Path, request.Resource.Path, request.Recursive)
	if err != nil {
		return nil, hostFailureOf(WorkspaceReadError(err))
	}
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	watch := &workspaceWatch{cancel: cancel}
	id := s.resources.addLimited(caller, workspace.ContextID, watch.stop, maxBuildConfigurationWatches)
	if id == "" {
		watch.stop()
		return nil, failure("plugin.host.limitExceeded", "The backend has reached its native subscription limit.")
	}
	accepted := false
	defer func() {
		if !accepted {
			s.resources.dispose(caller, id)
		}
	}()
	stopRequest := context.AfterFunc(ctx, watch.stop)
	defer stopRequest()
	wake := make(chan struct{}, 1)
	signal := func() {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
	// The native stream follows the whole root, including ancestor replacement.
	// Only raw identity facts are checked here; Core decides scope and visibility.
	rootBefore, err := os.Stat(plan.Root)
	if err != nil {
		return nil, s.workspaceWatchFailure(ctx, err)
	}
	target := filepath.Join(plan.Root, filepath.FromSlash(plan.Path))
	targetBefore, err := os.Stat(target)
	if err != nil {
		return nil, s.workspaceWatchFailure(ctx, err)
	}
	native, err := app.WatchTree(plan.Root, nil, signal)
	if err != nil {
		return nil, s.workspaceWatchFailure(ctx, err)
	}
	watch.mu.Lock()
	if watch.closed {
		native.Close()
	} else {
		watch.native = native
	}
	watch.mu.Unlock()
	confirmed, err := host.PlanWatch(ctx, workspace.Path, request.Resource.Path, request.Recursive)
	if err != nil {
		return nil, hostFailureOf(WorkspaceReadError(err))
	}
	rootAfter, rootErr := os.Stat(plan.Root)
	targetAfter, targetErr := os.Stat(target)
	if rootErr != nil {
		return nil, s.workspaceWatchFailure(ctx, rootErr)
	}
	if targetErr != nil {
		return nil, s.workspaceWatchFailure(ctx, targetErr)
	}
	if confirmed != plan || !os.SameFile(rootBefore, rootAfter) || !os.SameFile(targetBefore, targetAfter) {
		return nil, s.workspaceWatchFailure(ctx, errors.New("workspace locations changed during watch registration"))
	}
	if _, err := s.Contexts.Lookup(request.Context); err != nil {
		return nil, contextFailure(err)
	}
	if session.isEnded() || lifetime.Err() != nil || ctx.Err() != nil {
		return nil, failure(pluginhost.CodeCancelled, "The workspace watch request ended.")
	}
	// A successful registration owns its lifetime independently of the request.
	// The initial rescan closes changes between validation and native registration.
	accepted = true
	go func() {
		defer s.resources.dispose(caller, id)
		sequence := uint64(1)
		if !s.sendWorkspaceWatch(lifetime, watch, session, request.Context, caller, id, request.Resource.RootID, sequence, core.WorkspaceWatchEvents{ChangedPaths: []string{}, RequiresRescan: true}) {
			return
		}
		var names []string
		for {
			select {
			case <-lifetime.Done():
				return
			case <-wake:
			}
			changes := native.Changes(names[:0])
			names = changes.Names
			currentRoot, err := os.Stat(plan.Root)
			if err != nil || !os.SameFile(rootBefore, currentRoot) {
				if err != nil && !errors.Is(err, os.ErrNotExist) && lifetime.Err() == nil && s.WorkspaceWatchIssue != nil {
					s.WorkspaceWatchIssue(lifetime, err)
				}
				// log-exempt: 预期的缺失：被删除或替换的根不能继续使用旧原生事件流。
				sequence++
				s.sendWorkspaceWatch(lifetime, watch, session, request.Context, caller, id, request.Resource.RootID, sequence, core.WorkspaceWatchEvents{ChangedPaths: []string{}, RequiresRescan: true})
				return
			}
			events, err := host.FilterWatchEvents(lifetime, workspace.Path, plan, names, changes.Resync)
			if err != nil {
				// log-exempt: 同一次失败已经记录过：Core/Workbench records rejected event projection.
				if lifetime.Err() == nil {
					sequence++
					s.sendWorkspaceWatch(lifetime, watch, session, request.Context, caller, id, request.Resource.RootID, sequence, core.WorkspaceWatchEvents{ChangedPaths: []string{}, RequiresRescan: true})
				}
				return
			}
			if len(events.ChangedPaths) == 0 && !events.RequiresRescan {
				continue
			}
			sequence++
			if !s.sendWorkspaceWatch(lifetime, watch, session, request.Context, caller, id, request.Resource.RootID, sequence, events) {
				return
			}
		}
	}()
	return marshalResult(map[string]string{"subscriptionID": id})
}

func (s *Service) workspaceWatchFailure(ctx context.Context, err error) *pluginhost.Failure {
	if s.WorkspaceWatchIssue != nil {
		s.WorkspaceWatchIssue(ctx, err)
	}
	switch {
	case errors.Is(err, os.ErrNotExist):
		return failure(CodeNotFound, "The workspace watch target no longer exists.")
	case errors.Is(err, os.ErrPermission):
		return failure(CodePermissionDenied, "The workspace watch target is not accessible.")
	case errors.Is(err, app.ErrUnsupported):
		return failure(codeAuthorityUnsupported, "Native workspace watches are unavailable.")
	case errors.Is(err, app.ErrWatchTooLarge):
		return failure("plugin.host.limitExceeded", "The workspace tree exceeds the native watch limit.")
	default:
		return failure(CodeFailed, "The workspace could not be watched.")
	}
}

func (s *Service) sendWorkspaceWatch(parent context.Context, watch *workspaceWatch, session *BackendSession, ref ContextRef, caller pluginhost.Caller, id, rootID string, sequence uint64, events core.WorkspaceWatchEvents) bool {
	watch.mu.Lock()
	defer watch.mu.Unlock()
	if watch.closed || parent.Err() != nil || session.isEnded() {
		return false
	}
	if _, err := s.Contexts.Lookup(ref); err != nil {
		// log-exempt: 用户取消：关闭的工作区不再接收监听通知。
		return false
	}
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	params, _ := json.Marshal(map[string]any{
		"subscriptionID": id, "sequence": sequence,
		"event": map[string]any{"rootID": rootID, "changedPaths": events.ChangedPaths, "requiresRescan": events.RequiresRescan},
	})
	// Core records lsp.hostNotify's terminal outcome at the request boundary.
	sent, err := s.kernel.SendPluginHostNotification(ctx, caller.SessionID, notifySubscription, params)
	if err != nil || !sent {
		// log-exempt: 同一次失败已经记录过：Core records delivery failure; session closure is cancellation.
		return false
	}
	return true
}
