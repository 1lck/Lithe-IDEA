package workbench

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// 持久化决策见 .agents/notes/implemented/bug-fix/2026-11-26-recent-project-history.md。
const (
	legacyRecentFile    = "recent-projects.json"
	recentLockFile      = recentFile + ".lock"
	recentUpdateTimeout = 5 * time.Second
)

// recentWrites orders one workbench's queued operations. The native lock
// serializes mutations by all workbenches and application processes.
type recentWrites struct {
	tail          <-chan struct{}
	next, applied uint64
}

type recentSnapshot struct {
	result  core.RecentProjectsResult
	missing map[string]bool
}

func (a *App) loadRecent() {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	view, stage, err := readRecent(ctx, a.store, a.kernel, core.NormalizeRecent(), false)
	a.finishRecent(view, stage, err)
}

func (a *App) changeRecent(action core.RecentAction, done func(core.RecentProjectsResult, error)) {
	a.queueRecent(action, true, done)
}

func (a *App) refreshRecent() {
	if a.store != nil && !a.documentOnly {
		a.queueRecent(core.NormalizeRecent(), false, nil)
	}
}

func (a *App) queueRecent(action core.RecentAction, save bool, done func(core.RecentProjectsResult, error)) {
	writes := &a.recentWrites
	previous, finished := writes.tail, make(chan struct{})
	writes.tail = finished
	writes.next++
	sequence := writes.next
	prefs, kernel := a.store, a.kernel
	a.background(nil, recentUpdateTimeout, func(ctx context.Context) func(*App) {
		defer close(finished)
		if previous != nil {
			select {
			case <-previous:
			case <-ctx.Done():
				return func(a *App) {
					a.finishRecent(recentSnapshot{}, "workspace_recent_save", ctx.Err())
					if done != nil {
						done(core.RecentProjectsResult{}, ctx.Err())
					}
				}
			}
		}
		view, stage, err := readRecent(ctx, prefs, kernel, action, save)
		return func(a *App) {
			if err != nil || sequence > a.recentWrites.applied {
				if err == nil {
					a.recentWrites.applied = sequence
				}
				a.finishRecent(view, stage, err)
			}
			if done != nil {
				done(view.result, err)
			}
		}
	})
}

func readRecent(ctx context.Context, prefs *store.Store, kernel Kernel, action core.RecentAction, save bool) (recentSnapshot, string, error) {
	result, stage, err := reduceStoredRecent(ctx, prefs, kernel, action, save)
	if err != nil {
		return recentSnapshot{}, stage, err
	}
	view := recentSnapshot{result: result, missing: make(map[string]bool)}
	for _, entry := range result.Entries {
		if entry.Remote == nil {
			if info, err := os.Stat(entry.Path); err != nil || !info.IsDir() {
				view.missing[entry.Path] = true
			}
		}
	}
	return view, "", nil
}

func reduceStoredRecent(ctx context.Context, prefs *store.Store, kernel Kernel, action core.RecentAction, save bool) (result core.RecentProjectsResult, stage string, err error) {
	if save {
		if err := os.MkdirAll(prefs.Dir(), 0o700); err != nil {
			return result, "workspace_recent_save", err
		}
		release, err := filelock.Acquire(ctx, prefs.Path(recentLockFile))
		if err != nil {
			return result, "workspace_recent_save", err
		}
		defer func() {
			if releaseErr := release(); releaseErr != nil {
				err = errors.Join(err, releaseErr)
				if stage == "" {
					stage = "workspace_recent_save"
				}
			}
		}()
	}
	var entries []core.RecentProject
	found, err := prefs.Load(recentFile, &entries)
	if !found && err == nil {
		// Old clients can keep writing their own file during a downgrade. Import
		// it until the first v2 mutation succeeds; an empty v2 list is authoritative.
		_, err = prefs.Load(legacyRecentFile, &entries)
	}
	if err != nil {
		if save {
			return result, "workspace_recent_save", err
		}
		return result, "recent_projects", err
	}
	result, err = kernel.ReduceRecentProjects(ctx, entries, action, 0)
	if err != nil {
		return result, "workspace_recent_reduce", err
	}
	if save {
		if err := ctx.Err(); err != nil {
			return result, "workspace_recent_save", err
		}
		if err := prefs.Save(recentFile, result.Entries); err != nil {
			return result, "workspace_recent_save", err
		}
	}
	return result, "", nil
}

func (a *App) finishRecent(view recentSnapshot, stage string, err error) {
	if err != nil {
		switch stage {
		case "recent_projects":
			a.storedStateFailed(stage, err)
			a.notifyError(a.text.Errors.Core(err.Error()))
		case "workspace_recent_save":
			a.operationFailed(stage, documentLogError(err))
			a.notifyError(a.text.Errors.SaveFailed(err.Error()))
		default:
			a.operationFailed(stage, documentLogError(err))
			a.notifyError(a.text.Errors.Core(err.Error()))
		}
		return
	}
	a.recent, a.missing = view.result.Entries, view.missing
	a.welcome.projectionValid = false
	a.refreshWelcomeBranches()
}
