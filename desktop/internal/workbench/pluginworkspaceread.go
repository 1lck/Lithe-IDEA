package workbench

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// workspaceReadKernel is the API-06/07/08 part of the shared kernel.
type workspaceReadKernel interface {
	ReadWorkspaceDirectory(context.Context, core.WorkspaceDirectoryRequest) (core.WorkspaceDirectoryPage, error)
	StatWorkspaceEntry(context.Context, string, string) (core.WorkspaceStat, error)
	ReadWorkspaceFile(context.Context, string, string, *int) (core.WorkspaceFileRead, error)
	FindWorkspaceFiles(context.Context, core.WorkspaceFindRequest) (core.WorkspaceFindPage, error)
	FindWorkspaceText(context.Context, core.WorkspaceFindRequest) (core.WorkspaceFindPage, error)
	PlanWorkspaceWatch(context.Context, string, string, bool) (core.WorkspaceWatchPlan, error)
	FilterWorkspaceWatchEvents(context.Context, core.WorkspaceWatchPlan, []string, bool) (core.WorkspaceWatchEvents, error)
}

var _ pluginservice.WorkspaceReadHost = pluginWorkbench{}
var _ pluginservice.WorkspaceFindHost = pluginWorkbench{}
var _ pluginservice.WorkspaceWatchHost = pluginWorkbench{}

// readWorkspace captures window-owned state, reads on the calling host goroutine,
// and checks the same project before publishing. Project closure and host request
// cancellation both cancel Core; no I/O runs on the window thread.
func readWorkspace[T any](w pluginWorkbench, ctx context.Context, root, operation string, read func(context.Context, workspaceReadKernel) (T, error)) (T, error) {
	type scope struct {
		project *project
		kernel  workspaceReadKernel
		ctx     context.Context
	}
	var zero T
	state, err := onWindow(w.app, ctx, func(a *App) (scope, error) {
		p, err := a.localProjectAt(root)
		if err != nil {
			return scope{}, err
		}
		if a.kernel == nil {
			return scope{}, hostError(pluginservice.CodeFailed, "The window has no kernel.")
		}
		return scope{p, a.kernel, a.operationContext(ctx)}, nil
	})
	if err != nil {
		return zero, err
	}
	readCtx, cancel := context.WithTimeout(state.ctx, 30*time.Second)
	defer cancel()
	stop := context.AfterFunc(state.project.ctx, cancel)
	defer stop()
	result, readErr := read(readCtx, state.kernel)
	return onWindow(w.app, ctx, func(a *App) (T, error) {
		if a.project != state.project || state.project.ctx.Err() != nil {
			return zero, hostError(pluginservice.CodeContextExpired, "The workspace is no longer open.")
		}
		if readErr != nil {
			mapped := pluginservice.WorkspaceReadError(readErr)
			var refusal *pluginservice.HostError
			if errors.As(mapped, &refusal) && refusal.Code != pluginservice.CodeFailed {
				a.operationRejectedIn(state.ctx, operation, strings.TrimPrefix(refusal.Code, "plugin.host."))
			} else if !errors.Is(mapped, context.Canceled) {
				a.operationFailedIn(state.ctx, operation, documentLogError(readErr))
			} else {
				// log-exempt: 用户取消：请求结束后不再发布磁盘读取结果。
			}
			return zero, mapped
		}
		return result, nil
	})
}

func (w pluginWorkbench) ReadDirectory(ctx context.Context, request core.WorkspaceDirectoryRequest) (core.WorkspaceDirectoryPage, error) {
	return readWorkspace(w, ctx, request.Root, "plugin_directory_read", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceDirectoryPage, error) {
		return kernel.ReadWorkspaceDirectory(ctx, request)
	})
}

func (w pluginWorkbench) StatEntry(ctx context.Context, root, path string) (core.WorkspaceStat, error) {
	return readWorkspace(w, ctx, root, "plugin_entry_stat", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceStat, error) {
		return kernel.StatWorkspaceEntry(ctx, root, path)
	})
}

func (w pluginWorkbench) ReadFile(ctx context.Context, root, path string, maximumBytes *int) (core.WorkspaceFileRead, error) {
	return readWorkspace(w, ctx, root, "plugin_file_read", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceFileRead, error) {
		return kernel.ReadWorkspaceFile(ctx, root, path, maximumBytes)
	})
}

func (w pluginWorkbench) FindFiles(ctx context.Context, request core.WorkspaceFindRequest) (core.WorkspaceFindPage, error) {
	return readWorkspace(w, ctx, request.Root, "plugin_find_files", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceFindPage, error) {
		return kernel.FindWorkspaceFiles(ctx, request)
	})
}

func (w pluginWorkbench) FindText(ctx context.Context, request core.WorkspaceFindRequest) (core.WorkspaceFindPage, error) {
	return readWorkspace(w, ctx, request.Root, "plugin_find_text", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceFindPage, error) {
		return kernel.FindWorkspaceText(ctx, request)
	})
}

func (w pluginWorkbench) PlanWatch(ctx context.Context, root, path string, recursive bool) (core.WorkspaceWatchPlan, error) {
	return readWorkspace(w, ctx, root, "plugin_workspace_watch", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceWatchPlan, error) {
		return kernel.PlanWorkspaceWatch(ctx, root, path, recursive)
	})
}

func (w pluginWorkbench) FilterWatchEvents(ctx context.Context, root string, plan core.WorkspaceWatchPlan, paths []string, rescan bool) (core.WorkspaceWatchEvents, error) {
	return readWorkspace(w, ctx, root, "plugin_workspace_watch_events", func(ctx context.Context, kernel workspaceReadKernel) (core.WorkspaceWatchEvents, error) {
		return kernel.FilterWorkspaceWatchEvents(ctx, plan, paths, rescan)
	})
}
