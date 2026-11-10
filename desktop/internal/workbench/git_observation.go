package workbench

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
)

// This file watches the Git metadata of the open project: the repository's git directory,
// the common directory that linked worktrees share, and its branch refs directory. Native
// watches only report entry names; Core decides what a name means (a context change, an
// ignore rule, a metadata write, or an index-only write), and the window refreshes the status
// from that answer. Idle watches hold no timer, and closing the project releases them.

const (
	// gitObserveDebounce coalesces the burst of writes one Git command makes.
	gitObserveDebounce = 150 * time.Millisecond
	// gitObserveMaxPaths is the most changed paths kept for one classification. Beyond it the
	// change is handled as a full rescan.
	gitObserveMaxPaths = 512
)

// gitObserveKernel is what the metadata observation asks of the kernel.
type gitObserveKernel interface {
	GitWatchContextOf(ctx context.Context, root string) (core.GitWatchContext, bool, error)
	GitClassifyMetadataChanges(ctx context.Context, metadata core.GitMetadataContext, paths []string) ([]core.GitMetadataEvent, error)
}

// gitObservation is the Git metadata watch of the open project.
type gitObservation struct {
	// gen counts the starts; a resolution answered for an older start is dropped.
	gen      int
	metadata *core.GitMetadataContext
	watches  map[string]*documentWatch
	// paths are changed paths waiting for classification; full asks for a rescan whatever
	// the paths say.
	paths   []string
	full    bool
	running bool
	// revision counts the changes that can move history (commits, refs, HEAD or config), so
	// a consumer such as the inline blame refreshes on it and not on index writes.
	revision int
}

// startGitObservation resolves the metadata roots of the project in the background and
// installs their watches. The first answer rescans the status once.
func (a *App) startGitObservation(p *project) {
	kernel, ok := a.kernel.(gitObserveKernel)
	if !ok || p.observe.metadata != nil || p.observe.watches != nil {
		return
	}
	p.observe.gen++
	gen, root := p.observe.gen, p.root
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		watch, found, err := kernel.GitWatchContextOf(core.AutomaticRefresh(ctx), root)
		var dirs []string
		if found && err == nil {
			dirs = []string{watch.GitDirectory}
			if watch.GitCommonDirectory != watch.GitDirectory {
				dirs = append(dirs, watch.GitCommonDirectory)
			}
			// Loose branch refs live under the common directory; packed-only repositories
			// have no such directory and are not watched there.
			heads := filepath.Join(watch.GitCommonDirectory, "refs", "heads")
			if info, statErr := os.Stat(heads); statErr == nil && info.IsDir() {
				dirs = append(dirs, heads)
			}
		}
		return func(a *App) {
			o := &p.observe
			if a.project != p || o.gen != gen {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("git_metadata_watch", documentLogError(err)))
				return
			}
			if !found {
				return
			}
			o.metadata = &core.GitMetadataContext{
				RepositoryRoot:     watch.RepositoryRoot,
				GitDirectory:       watch.GitDirectory,
				GitCommonDirectory: watch.GitCommonDirectory,
				WorkspaceRoot:      p.root,
			}
			o.watches = make(map[string]*documentWatch, len(dirs))
			for _, dir := range dirs {
				a.startGitWatch(p, dir)
			}
			o.full = true
			a.scheduleGitObservation(p)
		}
	})
}

// startGitWatch installs the native watch of one metadata directory.
func (a *App) startGitWatch(p *project, dir string) {
	o := &p.observe
	if _, ok := o.watches[dir]; ok {
		return
	}
	slot := &documentWatch{}
	o.watches[dir] = slot
	a.tasks.running.Add(1)
	wake := func() {
		a.post(func(a *App) { a.drainGitWatch(p, dir, slot) })
	}
	go func() {
		defer a.tasks.running.Done()
		watch, err := app.WatchDirectory(dir, wake)
		var observed documentDirectoryWatch
		if watch != nil {
			observed = watch
		}
		slot.finish(observed, err)
		wake()
	}()
}

// drainGitWatch takes the names a metadata directory reported and schedules their
// classification.
func (a *App) drainGitWatch(p *project, dir string, slot *documentWatch) {
	if a.project != p || p.observe.watches[dir] != slot {
		return
	}
	watch, ready, err := slot.state()
	if ready {
		// The watch was installed after the last status: one rescan covers the gap.
		p.observe.full = true
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("git_metadata_watch", documentLogError(err)))
		}
	}
	if watch != nil {
		changes := watch.Changes(nil)
		if changes.Resync {
			// Events were dropped or the directory was replaced: rescan and watch again.
			p.observe.full = true
			slot.close()
			delete(p.observe.watches, dir)
			a.startGitWatch(p, dir)
		} else {
			for _, name := range changes.Names {
				a.addGitPath(p, filepath.Join(dir, name))
			}
		}
	}
	a.scheduleGitObservation(p)
}

// addGitPath keeps one changed path, or marks a full rescan when the flood is too large.
func (a *App) addGitPath(p *project, path string) {
	o := &p.observe
	if len(o.paths) >= gitObserveMaxPaths {
		o.full = true
		o.paths = o.paths[:0]
		return
	}
	o.paths = append(o.paths, path)
}

// scheduleGitObservation starts one debounced classification of the waiting paths. Paths that
// arrive meanwhile wait for the next one.
func (a *App) scheduleGitObservation(p *project) {
	o := &p.observe
	kernel, ok := a.kernel.(gitObserveKernel)
	if !ok || a.project != p || o.metadata == nil || o.running || (!o.full && len(o.paths) == 0) {
		return
	}
	paths, full := o.paths, o.full
	o.paths, o.full, o.running = nil, false, true
	metadata := *o.metadata
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		timer := time.NewTimer(gitObserveDebounce)
		select {
		case <-ctx.Done():
			timer.Stop()
			return func(a *App) { p.observe.running = false }
		case <-timer.C:
		}
		if full {
			return func(a *App) { a.finishGitObservation(p, nil, nil) }
		}
		events, err := kernel.GitClassifyMetadataChanges(ctx, metadata, paths)
		return func(a *App) { a.finishGitObservation(p, events, err) }
	})
}

// gitChangeScope is what a classification means for the window: the status must be read
// again, the history (commits, refs, HEAD, config) moved, or the repository was replaced and
// must be resolved again.
type gitChangeScope struct {
	status, history, restart bool
}

// gitScopeOf maps Core's classification to a scope. A nil events slice is a full rescan
// request; a classification failure also rescans, as Core asks. An index-only write refreshes
// the status (staging changes it) but not the history.
func gitScopeOf(events []core.GitMetadataEvent, err error) gitChangeScope {
	if events == nil || err != nil {
		return gitChangeScope{status: true, history: true}
	}
	var scope gitChangeScope
	for _, e := range events {
		switch e.Kind {
		case "context":
			scope.restart = true
		case "ignoreRule", "metadata":
			scope.status = true
			if !e.IndexOnly {
				scope.history = true
			}
		}
	}
	return scope
}

// finishGitObservation applies Core's classification to the window.
func (a *App) finishGitObservation(p *project, events []core.GitMetadataEvent, err error) {
	o := &p.observe
	o.running = false
	if a.project != p {
		return
	}
	scope := gitScopeOf(events, err)
	if scope.restart {
		// The repository itself moved: resolve it again and watch its new roots.
		a.closeGitObservation(p)
		a.startGitObservation(p)
		return
	}
	if scope.history {
		o.revision++
		// The blame of a saved file follows HEAD: a commit, checkout or ref move changes it,
		// while an index write does not.
		a.refreshInlineBlames(p)
	}
	if scope.status {
		a.loadGit(p)
	}
	a.scheduleGitObservation(p)
}

// closeGitObservation releases the metadata watches of the project.
func (a *App) closeGitObservation(p *project) {
	o := &p.observe
	for _, slot := range o.watches {
		slot.close()
	}
	o.gen++
	o.watches, o.metadata, o.paths, o.full = nil, nil, nil, false
}
