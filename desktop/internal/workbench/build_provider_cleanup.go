package workbench

import (
	"context"
	"errors"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
)

// closingBuildProviders retains native owners across project close. The
// project context is an identity, so reopening the same path has a new owner.
type closingBuildProviders struct {
	mu      sync.Mutex
	clients map[*buildprovider.Client]context.Context
}

// A failed disposal stays in closingBuildProviders. Uninstall can retry it
// after waiting for the launch that first attempted cleanup.
type trackedBuildProviderStopError struct{ cause error }

func (e *trackedBuildProviderStopError) Error() string { return e.cause.Error() }
func (e *trackedBuildProviderStopError) Unwrap() error { return e.cause }

func (r *closingBuildProviders) add(project context.Context, client *buildprovider.Client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.clients == nil {
		r.clients = make(map[*buildprovider.Client]context.Context)
	}
	r.clients[client] = project
}

func (r *closingBuildProviders) snapshot(matches func(*buildprovider.Client, context.Context) bool) []*buildprovider.Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	var clients []*buildprovider.Client
	for client, owner := range r.clients {
		if matches(client, owner) {
			clients = append(clients, client)
		}
	}
	return clients
}

func (r *closingBuildProviders) close(ctx context.Context, client *buildprovider.Client) error {
	if err := client.Close(ctx); err != nil {
		return err
	}
	r.mu.Lock()
	delete(r.clients, client)
	r.mu.Unlock()
	return nil
}

func (a *App) retireBuildProvider(ctx context.Context, client *buildprovider.Client) {
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		drainCtx, cancelDrain := context.WithTimeout(context.Background(), buildRequestTimeout)
		drainErr := client.Drain(drainCtx)
		cancelDrain()
		stopCtx, cancelStop := context.WithTimeout(context.Background(), buildStopTimeout)
		defer cancelStop()
		if err := errors.Join(drainErr, a.closingBuildProviders.close(stopCtx, client)); err != nil {
			a.backgroundFailedIn(ctx, "build_provider_restart", err)
		}
	}()
}
