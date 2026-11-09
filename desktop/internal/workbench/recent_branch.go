package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/gitmetadata"
)

// refreshWelcomeBranches invalidates the last read. One worker owns all paths;
// a newer request cancels it and starts after it finishes, bounding concurrency.
func (a *App) refreshWelcomeBranches() {
	w := &a.welcome
	if w.branchClosed {
		return
	}
	w.branchGeneration++
	w.branchPending = true
	if w.branchCancel != nil {
		w.branchCancel()
	}
}

func (a *App) closeWelcomeBranchReads() {
	w := &a.welcome
	w.branchClosed = true
	w.branchPending = false
	w.branchGeneration++
	if w.branchCancel != nil {
		w.branchCancel()
	}
}

// startWelcomeBranchReads is called while painting, after the window owns its
// invalidator. It copies only paths and never performs filesystem IO on the UI thread.
func (a *App) startWelcomeBranchReads() {
	w := &a.welcome
	if w.branchClosed || w.branchRunning || !w.branchPending {
		return
	}
	w.branchPending = false
	paths := make([]string, 0, len(a.recent))
	for _, entry := range a.recent {
		if !a.missing[entry.Path] {
			paths = append(paths, entry.Path)
		}
	}
	if len(paths) == 0 {
		w.branches = nil
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	w.branchCancel, w.branchRunning = cancel, true
	generation, kernel := w.branchGeneration, a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		branches := make(map[string]string, len(paths))
		var failures []error
		for _, path := range paths {
			branch, err := gitmetadata.ReadBranch(ctx, kernel, path)
			if ctx.Err() != nil {
				break
			}
			if err != nil {
				failures = append(failures, err)
			} else if branch != "" {
				branches[path] = branch
			}
		}
		return func(a *App) {
			cancel()
			w := &a.welcome
			w.branchCancel, w.branchRunning = nil, false
			if w.branchClosed || w.branchGeneration != generation {
				return
			}
			w.branches = branches
			for _, err := range failures {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_recent_branch", documentLogError(err)))
			}
		}
	})
}
