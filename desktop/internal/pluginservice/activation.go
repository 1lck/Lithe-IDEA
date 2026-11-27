package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
)

// EventWorkspaceOpen is the activation event that starts a backend when a
// workspace opens.
const EventWorkspaceOpen = "onWorkspaceOpen"

type workspaceNotificationRevision struct {
	sessionID string
	revision  uint64
}

// relayDeclaration is the part of a manifest the cross-plugin relay needs.
type relayDeclaration struct {
	PluginFunctions *struct {
		Exports []json.RawMessage `json:"exports"`
		Calls   []json.RawMessage `json:"calls"`
	} `json:"pluginFunctions"`
}

// SyncFunctionRelay sends Core the complete view the cross-plugin relay checks
// calls against: the enabled plugins that declare pluginFunctions, copied from
// their normalised manifests without interpretation, and the live workspace
// contexts. Each call replaces the previous view, so installing, updating,
// disabling and uninstalling a plugin take effect at once.
func (s *Service) SyncFunctionRelay(ctx context.Context, entries []pluginmanager.Entry) error {
	if s == nil || s.Contexts == nil {
		return nil
	}
	if s.kernel == nil {
		return fmt.Errorf("%w: no kernel", ErrAssembly)
	}
	snapshot, readErr := s.ReadInstalled(ctx, entries)
	if err := ctx.Err(); err != nil {
		if errors.Is(readErr, err) {
			return readErr
		}
		return errors.Join(readErr, err)
	}
	return errors.Join(readErr, s.syncFunctionRelay(ctx, snapshot))
}

func (s *Service) syncFunctionRelay(ctx context.Context, snapshot InstalledSnapshot) error {
	var plugins []core.RelayPlugin
	var failures []error
	for _, installed := range snapshot.manifests {
		entry, manifest := installed.entry, installed.manifest
		var declaration relayDeclaration
		if err := json.Unmarshal(manifest, &declaration); err != nil {
			failures = append(failures, fmt.Errorf("decode relay manifest for %s@%s: %w", entry.Installed.ID, entry.Installed.Version, err))
			continue
		}
		if declaration.PluginFunctions == nil {
			continue
		}
		plugins = append(plugins, core.RelayPlugin{
			PluginID: entry.Installed.ID,
			Exports:  declaration.PluginFunctions.Exports,
			Calls:    declaration.PluginFunctions.Calls,
		})
	}
	_, workspaces := s.Contexts.List()
	contexts := make([]core.RelayContext, 0, len(workspaces))
	for _, workspace := range workspaces {
		contexts = append(contexts, core.RelayContext{ContextID: workspace.ContextID, Generation: workspace.Generation, Authority: "local"})
	}
	if err := s.kernel.ConfigureFunctionRelay(ctx, plugins, contexts); err != nil {
		failures = append(failures, fmt.Errorf("configure function relay: %w", err))
	}
	return errors.Join(failures...)
}

// ActivateWorkspace consumes the context the window opened and starts the backends
// that asked for onWorkspaceOpen, one plugin at a time. It belongs on a background
// goroutine: starting a backend never delays opening the workspace, and a backend
// that fails to start is reported without blocking the others.
func (s *Service) ActivateWorkspace(ctx context.Context, entries []pluginmanager.Entry, workspace ContextRef) error {
	if s == nil || s.Contexts == nil || s.Host == nil {
		return nil
	}
	if _, err := s.checkedWorkspaceContext(ctx, workspace); err != nil {
		return err
	}
	snapshot, readErr := s.ReadInstalled(ctx, entries)
	return errors.Join(readErr, s.activateWorkspace(ctx, snapshot, workspace))
}

func (s *Service) activateWorkspace(ctx context.Context, snapshot InstalledSnapshot, workspace ContextRef) error {
	var failures []error
	if _, err := s.checkedWorkspaceContext(ctx, workspace); err != nil {
		return errors.Join(append(failures, err)...)
	}
	for _, installed := range snapshot.manifests {
		entry, manifest := installed.entry, installed.manifest
		if !declaresBackend(manifest) || !declaredActivation(manifest, EventWorkspaceOpen) {
			continue
		}
		if _, err := s.checkedWorkspaceContext(ctx, workspace); err != nil {
			return errors.Join(append(failures, err)...)
		}
		if err := s.activateWorkspaceBackend(ctx, entry.Installed.ID, workspace); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
		}
	}
	return errors.Join(failures...)
}

// activateWorkspaceBackend replays the current context revision after initialization. An open
// notification sent before this backend existed cannot bootstrap its workspace providers.
func (s *Service) activateWorkspaceBackend(ctx context.Context, pluginID string, workspace ContextRef) error {
	if _, err := s.Host.EnsureBackend(ctx, pluginID); err != nil {
		return err
	}
	if _, err := s.Host.Functions(ctx, pluginID); err != nil {
		return err
	}
	if _, err := s.checkedWorkspaceContext(ctx, workspace); err != nil {
		return err
	}
	s.contextsNotifyMu.Lock()
	defer s.contextsNotifyMu.Unlock()
	return s.notifyWorkspaceContextsLocked(ctx, pluginID, s.Contexts.Revision())
}

// checkedWorkspaceContext never creates an owner on behalf of delayed work.
// Closing and reopening a path invalidates the captured ID/generation even when
// the new project's native root is identical.
func (s *Service) checkedWorkspaceContext(ctx context.Context, ref ContextRef) (WorkspaceContext, error) {
	if err := ctx.Err(); err != nil {
		return WorkspaceContext{}, err
	}
	if s == nil || s.Contexts == nil {
		return WorkspaceContext{}, ErrContextExpired
	}
	return s.Contexts.Lookup(ref)
}

// DetachWorkspaces ends every workspace context and removes every backend from
// the host at once, returning the function that stops the detached processes
// (bounded). It runs when the project closes: a backend is shared by the windows
// that are open, and this client has one. Detaching now and stopping later keeps
// a stop on a background goroutine from ending a backend the next project starts.
func (s *Service) DetachWorkspaces() func() {
	if s == nil || s.Contexts == nil || s.Host == nil {
		return func() {}
	}
	stopObserving := s.toolchainProviders.Invalidate()
	s.Contexts.CloseAll()
	if s.workflow != nil {
		s.workflow.httpMu.Lock()
		if s.workflow.transport != nil {
			s.workflow.transport.CloseIdleConnections()
		}
		s.workflow.httpMu.Unlock()
	}
	stopBackend := s.Host.DetachAll()
	return func() {
		stopObserving()
		stopBackend()
	}
}

// DetachBackend removes one plugin's backend from the host, as DetachWorkspaces
// does for all of them.
func (s *Service) DetachBackend(pluginID string) func() {
	if s == nil || s.Host == nil {
		return func() {}
	}
	stopObserving := s.toolchainProviders.Invalidate()
	stopBackend := s.Host.Detach(pluginID)
	return func() {
		stopObserving()
		stopBackend()
	}
}

// contextsChanged tells running backends the contexts changed and refreshes the
// relay view. It is the observer of WorkspaceContexts and runs on its own
// goroutine so a slow backend never blocks opening or closing a project.
func (s *Service) contextsChanged() {
	go s.refreshWorkspaceContexts(context.Background())
}

func (s *Service) refreshWorkspaceContexts(ctx context.Context) {
	err := s.refreshWorkspaceContextsOnce(ctx)
	// log-exempt: 用户取消：只有取消原因时无需记录，超时和混合故障仍报告。
	if err != nil && !contextRefreshCanceled(err) && s.ContextIssue != nil {
		s.ContextIssue(ctx, err)
	}
}

// refreshWorkspaceContextsOnce keeps relay replacement and backend delivery
// ordered with other refreshes. Its caller reports failures after unlocking.
func (s *Service) refreshWorkspaceContextsOnce(ctx context.Context) error {
	s.contextsNotifyMu.Lock()
	defer s.contextsNotifyMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	revision := s.Contexts.Revision()
	if revision <= s.contextsRefreshRevision {
		return nil
	}
	// Queued observers can converge on the same revision. A later context change
	// can retry a failure. The deadline starts once this refresh owns the lock.
	s.contextsRefreshRevision = revision
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	entries, relayErr := s.Manager.Installed()
	if relayErr != nil {
		relayErr = fmt.Errorf("list installed plugins for function relay: %w", relayErr)
	} else {
		relayErr = s.SyncFunctionRelay(ctx, entries)
	}
	notifyErr := s.notifyWorkspaceContextsLocked(ctx, "", s.Contexts.Revision())
	return errors.Join(relayErr, notifyErr)
}

// A partial failure can contain both cancellation and a diagnostic failure.
func contextRefreshCanceled(err error) bool {
	switch wrapped := err.(type) {
	case interface{ Unwrap() []error }:
		for _, cause := range wrapped.Unwrap() {
			if !contextRefreshCanceled(cause) {
				return false
			}
		}
		return true
	case interface{ Unwrap() error }:
		return contextRefreshCanceled(wrapped.Unwrap())
	default:
		return errors.Is(err, context.Canceled)
	}
}

// notifyWorkspaceContextsLocked sends the newest revision once to each ready backend session.
// Callers hold contextsNotifyMu so activation and simultaneous open/close notifications cannot
// be delivered out of order. A new backend session always starts with no delivered revision.
func (s *Service) notifyWorkspaceContextsLocked(ctx context.Context, onlyPlugin string, revision uint64) error {
	if s.contextsNotified == nil {
		s.contextsNotified = make(map[string]workspaceNotificationRevision)
	}
	params, err := json.Marshal(map[string]uint64{"revision": revision})
	if err != nil {
		return err
	}
	ids := s.Host.RunningPlugins()
	for pluginID := range s.contextsNotified {
		if s.Host.Running(pluginID) == nil {
			delete(s.contextsNotified, pluginID)
		}
	}
	var failures []error
	for _, pluginID := range ids {
		if onlyPlugin != "" && pluginID != onlyPlugin {
			continue
		}
		session := s.Host.Running(pluginID)
		if session == nil || !session.granted(grantWorkspace) || !session.isReady() {
			continue
		}
		last := s.contextsNotified[pluginID]
		if last.sessionID == session.Session.ID && last.revision >= revision {
			continue
		}
		delivered, err := s.Host.NotifyResult(ctx, pluginID, grantWorkspace, notifyDidChangeCtxs, params)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", pluginID, err))
			continue
		}
		if !delivered {
			err := fmt.Errorf("%s: workspace change notification was not delivered", pluginID)
			failures = append(failures, err)
			continue
		}
		s.contextsNotified[pluginID] = workspaceNotificationRevision{sessionID: session.Session.ID, revision: revision}
	}
	return errors.Join(failures...)
}
