package workbench

import (
	"context"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/gitmetadata"
	"github.com/vivaui/viva/ui"
)

// branchRead is what one read of the recent projects' branches found.
type branchRead struct {
	branches map[string]string
	failures []error
}

// refreshWelcomeBranches invalidates the last read: the next paint of the start
// screen reads again, and a read still running is cancelled.
func (a *App) refreshWelcomeBranches() { a.welcome.branchRevision++ }

// collectWelcomeBranches declares the branch read of the recent projects and
// applies what it finished. It runs at the start of every paint of the start
// screen and never performs filesystem IO on the window thread.
func (a *App) collectWelcomeBranches(c ui.C) {
	w := &a.welcome
	if w.branchesFx == nil {
		w.branchesFx = newKeyedEffect(func(ctx context.Context, paths []string) (branchRead, error) {
			read := branchRead{branches: make(map[string]string, len(paths))}
			for _, path := range paths {
				branch, err := gitmetadata.ReadBranch(ctx, a.kernel, path)
				if ctx.Err() != nil {
					return branchRead{}, ctx.Err()
				}
				if err != nil {
					read.failures = append(read.failures, err)
				} else if branch != "" {
					read.branches[path] = branch
				}
			}
			return read, nil
		})
	}
	paths := make([]string, 0, len(a.recent))
	for _, entry := range a.recent {
		if !a.missing[entry.Path] {
			paths = append(paths, entry.Path)
		}
	}
	if len(paths) == 0 {
		w.branches = nil
	} else {
		w.branchesFx.declare(c, strconv.Itoa(w.branchRevision), paths)
	}
	if read, err, ok := w.branchesFx.take(); ok && err == nil {
		w.branches = read.branches
		for _, failure := range read.failures {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_recent_branch", documentLogError(failure)))
		}
	}
}
