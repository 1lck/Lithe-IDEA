package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	refreshing    bool
	refreshAgain  bool
}

type recentSnapshot struct {
	result  core.RecentProjectsResult
	missing map[string]bool
}

func (a *App) loadRecent() {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	result, stage, err := reduceStoredRecent(ctx, a.store, a.kernel, core.NormalizeRecent(), false)
	var view recentSnapshot
	if err == nil {
		view = checkRecentDirectories(result)
	}
	a.finishRecent(view, stage, err)
}

func (a *App) changeRecent(action core.RecentAction, done func(core.RecentProjectsResult, error)) {
	a.queueRecent(action, true, done)
}

func (a *App) refreshRecent() {
	if a.store == nil || a.documentOnly {
		return
	}
	writes := &a.recentWrites
	if writes.refreshing {
		writes.refreshAgain = true
		return
	}
	writes.refreshing = true
	a.queueRecent(core.NormalizeRecent(), false, func(_ core.RecentProjectsResult, _ error) {
		writes.refreshing = false
		if writes.refreshAgain {
			writes.refreshAgain = false
			a.refreshRecent()
		}
	})
}

// The preference directory already has one native registration per process.
// Also wake subscribers immediately after a local commit, including those
// whose activation read finished before that commit reached disk.
func (state *editorPreferencesPublication) publishRecentChange() {
	state.recentRevision.Add(1)
	state.invalidate()
}

func (a *App) drainRecentChange(sub *settingsSubscription) {
	revision := sub.editorPreferences.recentRevision.Load()
	if sub.recentRevision != revision {
		sub.recentRevision = revision
		a.refreshRecent()
	}
}

func (a *App) queueRecent(action core.RecentAction, save bool, done func(core.RecentProjectsResult, error)) {
	writes := &a.recentWrites
	previous, finished := writes.tail, make(chan struct{})
	writes.tail = finished
	writes.next++
	sequence := writes.next
	prefs, kernel := a.store, a.kernel
	var publication *editorPreferencesPublication
	if sub := a.settingsSubscription; sub != nil {
		publication = sub.editorPreferences
	}
	a.background(nil, recentUpdateTimeout, func(ctx context.Context) func(*App) {
		defer close(finished)
		if previous != nil {
			select {
			case <-previous:
			case <-ctx.Done():
				return func(a *App) {
					stage := "recent_projects"
					if save {
						stage = "workspace_recent_save"
					}
					a.finishRecent(recentSnapshot{}, stage, ctx.Err())
					if done != nil {
						done(core.RecentProjectsResult{}, ctx.Err())
					}
				}
			}
		}
		result, stage, err := reduceStoredRecent(ctx, prefs, kernel, action, save)
		var view recentSnapshot
		if err == nil {
			if save && publication != nil {
				publication.publishRecentChange()
			}
			view = checkRecentDirectories(result)
		}
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

func checkRecentDirectories(result core.RecentProjectsResult) recentSnapshot {
	view := recentSnapshot{result: result, missing: make(map[string]bool)}
	for _, entry := range result.Entries {
		if entry.Remote == nil {
			if info, err := os.Stat(entry.Path); err != nil || !info.IsDir() {
				view.missing[entry.Path] = true
			}
		}
	}
	return view
}

func reduceStoredRecent(ctx context.Context, prefs *store.Store, kernel Kernel, action core.RecentAction, save bool) (result core.RecentProjectsResult, stage string, err error) {
	if save {
		if err := os.MkdirAll(prefs.Dir(), 0o700); err != nil {
			return result, "workspace_recent_save", err
		}
		release, lockErr := filelock.Acquire(ctx, prefs.Path(recentLockFile))
		if lockErr != nil {
			return result, "workspace_recent_save", lockErr
		}
		defer func() {
			if releaseErr := release(); releaseErr != nil {
				err = errors.Join(err, releaseErr)
				if stage == "" || stage == "recent_legacy_recovered" {
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
		var syntax *json.SyntaxError
		var valueType *json.UnmarshalTypeError
		if save && (errors.As(err, &syntax) || errors.As(err, &valueType)) {
			// v1 still belongs to older clients. Leave the original bytes where
			// they are and begin the independent v2 history with this action.
			stage, entries, err = "recent_legacy_recovered", nil, nil
		}
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
	return result, stage, nil
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
	if stage == "recent_legacy_recovered" {
		a.storedStateFailed("recent_projects_legacy", errors.New("invalid legacy recent projects JSON"))
		a.notifyInfo(i18n.Shared(a.language(), "desktop.welcome.recoveredRecentHistory"))
	}
	a.recent, a.missing = view.result.Entries, view.missing
	a.welcome.projectionValid = false
	a.refreshWelcomeBranches()
}
