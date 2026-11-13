package pluginservice

import (
	"context"
	"errors"
)

// Uninstall stops what plugin id runs and then removes it. server is the
// plugin's language server session, which the window tracks, or nil; the
// plugin's backend is the host's. Removing it takes every installed version,
// its approvals, the enablement choice and its state directory
// (pluginmanager.Manager.Uninstall).
//
// The programs stop first, and Uninstall waits for them (bounded): one still
// running could write its state again after the removal, and Windows cannot
// move the directory of a program that runs.
func (s *Service) Uninstall(ctx context.Context, id string, server *LanguageSession) error {
	stopped := s.stopPlugin(ctx, id, server)
	return errors.Join(stopped, s.Manager.Uninstall(id))
}

// Disable records that the user turned plugin id off and stops what it runs,
// as Uninstall does, so a disabled plugin keeps no process. The choice is
// recorded first, so nothing starts the plugin again while it stops.
func (s *Service) Disable(ctx context.Context, id string, server *LanguageSession) error {
	recorded := s.Manager.SetEnabled(id, false)
	return errors.Join(recorded, s.stopPlugin(ctx, id, server))
}

// stopPlugin stops a plugin's language server session and its backend, and
// returns once both ended or gave up.
func (s *Service) stopPlugin(ctx context.Context, id string, server *LanguageSession) error {
	stopBackend := s.DetachBackend(id)
	err := s.StopLanguageServer(ctx, server)
	stopBackend()
	return err
}
