package workbench

import (
	"context"
	"errors"
	"slices"
	"time"
)

// The cache of the consented agents' session records serves more than the History tab:
// lithe/host/agents/usage answers a plugin's view, such as a usage dashboard, from the last
// sync, and Core never syncs on its own. So the window keeps the cache current in the
// background: it syncs the readable agents once Core configured them, which covers the window
// opening, a consent given and an agent plugin installed or updated, and again when the window
// is activated, at most once per agentRecordSyncInterval, which covers sessions a CLI wrote in
// a terminal meanwhile. The History tab still syncs when it first shows and on its button.
//
// A sync reads only the files that changed since the last one. It starts the backend of an
// agent's plugin when the manifest activates it on the agent, as the History tab's sync does.

// agentRecordSyncInterval is the shortest time between two syncs the window's activation asks for.
const agentRecordSyncInterval = time.Minute

// agentRecordSync is the state of the window's background sync of the session records.
type agentRecordSync struct {
	// running is set while a sync is on its way; again asks for one more when it ends, because
	// the agents or the consent changed while it ran.
	running bool
	again   bool
	// last is when the last sync started.
	last time.Time
}

// syncAgentRecords syncs the readable agents in the background. A sync asked for by a
// configuration (configured) always runs, after the one running ends; one asked for by the
// window's activation runs only when the last one started agentRecordSyncInterval ago. It runs
// on the window thread.
func (a *App) syncAgentRecords(configured bool) {
	v := &a.agentsView
	s := &v.recordSync
	keys := v.readableAgents()
	if a.agentKernel == nil || len(keys) == 0 {
		return
	}
	if s.running {
		s.again = s.again || configured
		return
	}
	now := a.now()
	if !configured && !s.last.IsZero() && now.Sub(s.last) < agentRecordSyncInterval {
		return
	}
	s.running, s.again, s.last = true, false, now
	kernel, service := a.agentKernel, a.plugins
	catalog := slices.Clone(v.catalog)
	a.background(nil, agentSyncTimeout, func(ctx context.Context) func(*App) {
		var failures []error
		for _, agent := range catalog {
			if !slices.Contains(keys, agent.Key()) {
				continue
			}
			if service != nil {
				if err := service.EnsureAgentBackend(ctx, agent.PluginID, agent.AgentID); err != nil {
					failures = append(failures, err)
					continue
				}
			}
			if _, err := kernel.Sync(ctx, agent.PluginID, agent.AgentID); err != nil {
				failures = append(failures, err)
			}
		}
		failure := errors.Join(failures...)
		return func(a *App) {
			s := &a.agentsView.recordSync
			s.running = false
			if failure != nil {
				a.backgroundFailed("agents_records_sync", failure)
			}
			if s.again {
				a.syncAgentRecords(true)
			}
		}
	})
}

// resumeAgentRecordSync syncs the session records as the window is activated, at most once per
// agentRecordSyncInterval.
func (a *App) resumeAgentRecordSync() {
	a.syncAgentRecords(false)
}
