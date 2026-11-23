package pluginservice

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Uninstall stops what plugin id runs and then removes it, in the order Core
// plans (pluginmanager.Manager.Apply): every installed version, its approvals,
// the enablement choice and its state directory. server is the plugin's
// language server session, which the window tracks, or nil; the plugin's
// backend is the host's.
//
// The programs stop first, and Uninstall waits for them (bounded): one still
// running could write its state again after the removal, and Windows cannot
// move the directory of a program that runs. stopNative waits for the window's
// other native owners, including other project tabs, before stopping the language
// server and backend. A failed stop preserves the package and state for retry.
func (s *Service) Uninstall(ctx context.Context, id string, server *LanguageSession, stopNative ...func(context.Context) error) (err error) {
	release := s.holdRuntimeStop(id)
	defer release()
	// A commit already past its cancellation check may finish while stopping.
	// Await it before Core snapshots installed versions for the removal plan.
	if err := s.stopRuntimePreparations(ctx, id); err != nil {
		return err
	}
	unlock, err := s.lockPackageChanges(ctx)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, unlock()) }()
	_, err = s.Manager.Apply(ctx, core.PluginUninstall, id, func() error { return s.stopWithNativePrograms(ctx, id, server, stopNative) })
	if err != nil {
		return err
	}
	return s.Installer.DiscardPending(s.Root, id)
}

// Disable records that the user turned plugin id off and stops what it runs,
// as Uninstall does, so a disabled plugin keeps no process. Core plans the
// choice before the stop, so nothing starts the plugin again while it stops.
func (s *Service) Disable(ctx context.Context, id string, server *LanguageSession, stopNative ...func(context.Context) error) (err error) {
	release := s.holdRuntimeStop(id)
	defer release()
	if err := s.stopRuntimePreparations(ctx, id); err != nil {
		return err
	}
	unlock, err := s.lockPackageChanges(ctx)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, unlock()) }()
	_, err = s.Manager.Apply(ctx, core.PluginDisable, id, func() error { return s.stopWithNativePrograms(ctx, id, server, stopNative) })
	return err
}

func (s *Service) stopWithNativePrograms(ctx context.Context, id string, server *LanguageSession, stopNative []func(context.Context) error) error {
	var failures []error
	for _, stop := range stopNative {
		failures = append(failures, stop(ctx))
	}
	failures = append(failures, s.stopPlugin(ctx, id, server))
	return errors.Join(failures...)
}

// StopDisplaced stops what plugin id runs after enabling another plugin turned it
// off (pluginmanager.Displaced): its choice is already recorded, so only the
// programs remain. server is its language server session, or nil.
func (s *Service) StopDisplaced(ctx context.Context, id string, server *LanguageSession, stopNative ...func(context.Context) error) error {
	release := s.holdRuntimeStop(id)
	defer release()
	return s.stopWithNativePrograms(ctx, id, server, stopNative)
}

// stopPlugin first cancels and awaits preparation/launch work, then stops all
// sessions it could have published before allowing package or state removal.
func (s *Service) stopPlugin(ctx context.Context, id string, server *LanguageSession) error {
	preparationErr := s.stopRuntimePreparations(ctx, id)
	stopBackend := s.DetachBackend(id)
	sessions := make(map[*LanguageSession]struct{})
	if server != nil {
		sessions[server] = struct{}{}
	}
	s.lsMu.Lock()
	for _, session := range s.lsSessions {
		if session.PluginID == id {
			sessions[session] = struct{}{}
		}
	}
	s.lsMu.Unlock()
	failures := []error{preparationErr}
	for session := range sessions {
		failures = append(failures, s.StopLanguageServer(ctx, session))
	}
	stopBackend()
	return errors.Join(failures...)
}
