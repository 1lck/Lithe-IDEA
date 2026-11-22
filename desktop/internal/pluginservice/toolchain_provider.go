package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

type toolchainProviderKernel interface {
	RequestPluginToolchain(context.Context, string, core.ToolchainQueryParams, int) error
	ToolchainFailureReply(context.Context, core.ToolchainQueryParams, string) (core.ToolchainProviderReply, error)
	DecodeToolchainReply(context.Context, core.ToolchainQuery) (core.ToolchainProviderSnapshot, error)
}

// ToolchainOptions binds discovery to the window's existing project identity
// and the native roots that provider answers must never authorize.
func (s *Service) ToolchainOptions(root string, options toolchain.Options) toolchain.Options {
	if s == nil || s.Contexts == nil {
		return options
	}
	options.WorkspaceRoots = s.Contexts.workspaceRoots()
	options.Providers = s.toolchainProviders
	if root == "" {
		return options
	}
	workspace, present := s.Contexts.ByPath(root)
	if !present {
		// A pin reread uses the captured canonical path while Open can receive an
		// alias from the chooser. Compare native identities only on this worker.
		if expected, err := os.Stat(root); err == nil {
			_, contexts := s.Contexts.List()
			for _, candidate := range contexts {
				if candidate.authorityKind() != "local" {
					continue
				}
				if info, err := os.Stat(candidate.Path); err == nil && os.SameFile(info, expected) {
					workspace, present = candidate, true
					break
				}
			}
		}
	}
	if !present || workspace.authorityKind() != "local" {
		// No project context is available for paths that a consumer is inspecting
		// without opening. Such paths remain eligible for declarative discovery.
		options.Providers = nil
		return options
	}
	options.ProviderScope = &toolchain.ProviderScope{
		Context: core.ToolchainQueryContext{ID: workspace.ContextID, Generation: workspace.Generation},
		RootID:  func(pluginID string) string { return s.Contexts.RootID(pluginID, workspace.Path) },
		Validate: func() error {
			_, err := s.Contexts.Lookup(workspace.ContextRef)
			return err
		},
	}
	return options
}

const toolchainQueryTimeout = 10 * time.Second

func (s *Service) queryToolchain(ctx context.Context, pluginID, version string, params core.ToolchainQueryParams) (core.ToolchainProviderReply, error) {
	queryCtx, cancel := context.WithTimeout(ctx, toolchainQueryTimeout)
	defer cancel()
	verify := func() error {
		if params.Context == nil {
			return nil
		}
		_, err := s.Contexts.Lookup(ContextRef{ContextID: params.Context.ID, Generation: params.Context.Generation})
		return err
	}
	if err := verify(); err != nil {
		return core.ToolchainProviderReply{}, err
	}
	session, err := s.Host.ensureBackend(queryCtx, pluginID, version)
	if err == nil {
		if err := verify(); err != nil {
			return core.ToolchainProviderReply{}, err
		}
		var reply core.ToolchainProviderReply
		reply, err = session.queryToolchain(queryCtx, params)
		if err == nil {
			if err := verify(); err != nil {
				return core.ToolchainProviderReply{}, err
			}
			return reply, nil
		}
	}
	if err := ctx.Err(); err != nil {
		return core.ToolchainProviderReply{}, err
	}
	code := core.ToolchainProviderUnavailable
	var failure *eventFailure
	var bridge *core.Error
	switch {
	case errors.Is(err, context.Canceled):
		return core.ToolchainProviderReply{}, err
	case errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &failure) && failure.Code == "requestTimeout"):
		code = core.ToolchainProviderTimeout
	case session == nil, errors.Is(err, ErrBackendUnavailable):
	case errors.As(err, &bridge) && (bridge.Code == core.CodeConnectionClosed ||
		(bridge.Code == core.CodeNotSupported && bridge.Details == core.ToolchainProviderUnavailable)):
	default:
		return core.ToolchainProviderReply{}, err
	}
	return s.toolchainKernel.ToolchainFailureReply(ctx, params, code)
}

func (b *BackendSession) queryToolchain(ctx context.Context, params core.ToolchainQueryParams) (core.ToolchainProviderReply, error) {
	if err := b.waitFor(ctx, func() bool { return b.ready && !b.ended }); err != nil {
		return core.ToolchainProviderReply{}, err
	}
	completed := make(chan core.BackendEvent, 1)
	b.mu.Lock()
	if b.ended {
		b.mu.Unlock()
		return core.ToolchainProviderReply{}, ErrBackendUnavailable
	}
	b.waiters[params.OperationID] = completed
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.waiters, params.OperationID)
		b.mu.Unlock()
	}()
	kernel := b.host.service.kernel
	if err := b.host.service.toolchainKernel.RequestPluginToolchain(ctx, b.Session.ID, params, int(toolchainQueryTimeout/time.Millisecond)); err != nil {
		return core.ToolchainProviderReply{}, err
	}
	select {
	case event := <-completed:
		value, err := decodeCompletion(event)
		if err != nil {
			return core.ToolchainProviderReply{}, err
		}
		var reply core.ToolchainProviderReply
		if err := json.Unmarshal(value, &reply); err != nil {
			return core.ToolchainProviderReply{}, err
		}
		return reply, nil
	case <-ctx.Done():
		cancelCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if err := kernel.CancelPluginOperation(cancelCtx, b.Session.ID, params.OperationID); err != nil && b.host.service.RecordFailed != nil {
			b.host.service.RecordFailed(cancelCtx, err)
		}
		return core.ToolchainProviderReply{}, ctx.Err()
	}
}
