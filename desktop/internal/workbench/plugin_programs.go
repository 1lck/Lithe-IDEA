package workbench

import (
	"context"
	"errors"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
)

// pluginLaunches owns native starts until they either publish a process or finish
// cleaning it up. stop closes admission before cancelling starts; its waiter must
// finish before the plugin's executable or state can be removed.
type pluginLaunches struct {
	mu      sync.Mutex
	blocked map[string]bool
	active  map[*pluginLaunch]string
}

type pluginLaunch struct {
	cancel context.CancelFunc
	done   chan struct{}
	err    error
}

func (r *pluginLaunches) begin(ctx context.Context, id string) (context.Context, func(error), error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.blocked[id] {
		return nil, nil, buildprovider.ErrClosed
	}
	ctx, cancel := context.WithCancel(ctx)
	launch := &pluginLaunch{cancel: cancel, done: make(chan struct{})}
	if r.active == nil {
		r.active = make(map[*pluginLaunch]string)
	}
	r.active[launch] = id
	return ctx, func(err error) {
		cancel()
		r.mu.Lock()
		// Cancellation and admission refusal are expected during uninstall. A
		// different error may include failed process cleanup and prevents deletion.
		if err != context.Canceled && err != context.DeadlineExceeded && err != buildprovider.ErrClosed {
			launch.err = err
		}
		if launch.err == nil || !r.blocked[id] {
			delete(r.active, launch)
		}
		close(launch.done)
		r.mu.Unlock()
	}, nil
}

func (r *pluginLaunches) stop(id string) func(context.Context) error {
	r.mu.Lock()
	if r.blocked == nil {
		r.blocked = make(map[string]bool)
	}
	r.blocked[id] = true
	var pending []*pluginLaunch
	for launch, owner := range r.active {
		if owner == id {
			launch.cancel()
			pending = append(pending, launch)
		}
	}
	r.mu.Unlock()
	return func(ctx context.Context) error {
		var failures []error
		for _, launch := range pending {
			select {
			case <-launch.done:
				failures = append(failures, launch.err)
			case <-ctx.Done():
				return errors.Join(append(failures, ctx.Err())...)
			}
		}
		return errors.Join(failures...)
	}
}

func (r *pluginLaunches) allow(id string) {
	r.mu.Lock()
	delete(r.blocked, id)
	r.mu.Unlock()
}

type pluginClient struct {
	table  map[string]*buildprovider.Client
	key    string
	client *buildprovider.Client
}

// takePluginClients snapshots native handles belonging to id. A failed stop
// keeps its handle registered so retrying uninstall must stop it again.
func takePluginClients(clients map[string]*buildprovider.Client, id string) []pluginClient {
	var taken []pluginClient
	for key, client := range clients {
		if strings.HasPrefix(key, id+"\x00") {
			taken = append(taken, pluginClient{table: clients, key: key, client: client})
		}
	}
	return taken
}

func stopPluginClients(ctx context.Context, mu *sync.Mutex, clients []pluginClient, pending func(context.Context) error) error {
	var failures []error
	for _, owned := range clients {
		if err := owned.client.Close(ctx); err != nil {
			failures = append(failures, err)
			continue
		}
		mu.Lock()
		if owned.table[owned.key] == owned.client {
			delete(owned.table, owned.key)
		}
		mu.Unlock()
	}
	failures = append(failures, pending(ctx))
	return errors.Join(failures...)
}

func (r *buildRuntime) detachPlugin(id string) func(context.Context) error {
	wait := r.launches.stop(id)
	r.mu.Lock()
	clients := append(takePluginClients(r.providers, id), takePluginClients(r.shared, id)...)
	r.mu.Unlock()
	return func(ctx context.Context) error { return stopPluginClients(ctx, &r.mu, clients, wait) }
}

func (r *vcsRuntime) detachPlugin(id string) func(context.Context) error {
	wait := r.launches.stop(id)
	r.mu.Lock()
	clients := takePluginClients(r.clients, id)
	r.mu.Unlock()
	return func(ctx context.Context) error { return stopPluginClients(ctx, &r.mu, clients, wait) }
}

// detachPluginPrograms takes native handles on the UI thread, then returns the
// bounded cleanup performed by Core's stopPrograms step. A hidden project tab
// owns its own plugin stack and must finish using the same package too.
// Note: 卸载约束见 .agents/notes/implemented/bug-fix/2026-11-13-viva-plugin-install-enables-and-uninstall-cleans-state.md。
func (a *App) detachPluginPrograms(id string) func(context.Context) error {
	var stops []func(context.Context) error
	for _, tab := range a.everyTab() {
		service := tab.plugins
		if service == nil {
			continue
		}
		server := tab.detachPluginServer(id)
		if p := tab.project; p != nil {
			stops = append(stops, p.buildSessions.detachPlugin(id))
			stops = append(stops, p.vcs.runtime().detachPlugin(id))
			var debugging []*debugSession
			for _, session := range p.debug.sessions {
				if session.adapter.PluginID == id {
					if session.cleanupDone == nil {
						session.cleanupDone = make(chan struct{})
					}
					debugging = append(debugging, session)
				}
			}
			for _, session := range debugging {
				if p.debug.hasSession(session) {
					tab.endDebugSession(p, session)
				}
			}
			stops = append(stops, func(ctx context.Context) error {
				var failures []error
				for _, session := range debugging {
					select {
					case <-session.cleanupDone:
						failures = append(failures, session.cleanupErr)
					case <-ctx.Done():
						return errors.Join(append(failures, ctx.Err())...)
					}
				}
				return errors.Join(failures...)
			})
		}
		stops = append(stops, func(ctx context.Context) error {
			return service.StopDisplaced(ctx, id, server)
		})
	}
	return func(ctx context.Context) error {
		var failures []error
		for _, stop := range stops {
			failures = append(failures, stop(ctx))
		}
		return errors.Join(failures...)
	}
}

// allowPluginPrograms opens native launch admission after an installation or
// explicit enable. The old starts were awaited before the package changed.
func (a *App) allowPluginPrograms(id string) {
	for _, tab := range a.everyTab() {
		tab.pluginServerMu.Lock()
		delete(tab.pluginServerSuppressed, id)
		tab.pluginServerMu.Unlock()
		if p := tab.project; p != nil {
			p.buildSessions.launches.allow(id)
			if p.vcs.launches != nil {
				p.vcs.launches.allow(id)
			}
		}
	}
}
