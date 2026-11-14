package pluginservice

import (
	"context"

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
// move the directory of a program that runs.
func (s *Service) Uninstall(ctx context.Context, id string, server *LanguageSession) error {
	_, err := s.Manager.Apply(ctx, core.PluginUninstall, id, func() error { return s.stopPlugin(ctx, id, server) })
	return err
}

// Disable records that the user turned plugin id off and stops what it runs,
// as Uninstall does, so a disabled plugin keeps no process. Core plans the
// choice before the stop, so nothing starts the plugin again while it stops.
func (s *Service) Disable(ctx context.Context, id string, server *LanguageSession) error {
	_, err := s.Manager.Apply(ctx, core.PluginDisable, id, func() error { return s.stopPlugin(ctx, id, server) })
	return err
}

// stopPlugin stops a plugin's language server session and its backend, and
// returns once both ended or gave up.
func (s *Service) stopPlugin(ctx context.Context, id string, server *LanguageSession) error {
	stopBackend := s.DetachBackend(id)
	err := s.StopLanguageServer(ctx, server)
	stopBackend()
	return err
}
