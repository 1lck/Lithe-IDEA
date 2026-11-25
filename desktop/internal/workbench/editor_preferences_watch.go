package workbench

import (
	"context"
	"os"
	"reflect"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
)

// One native directory registration per preferences directory observes atomic
// settings-file replacements made by independently launched client processes.
func (a *App) startEditorPreferencesWatch(state *editorPreferencesPublication) {
	dir := a.store.Dir()
	state.Lock()
	slot := state.watch
	state.Unlock()
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		err := os.MkdirAll(dir, 0o700)
		var native *app.DirectoryWatch
		wake := func() {
			state.watchDirty.Store(true)
			state.invalidate()
		}
		if err == nil {
			native, err = app.WatchDirectory(dir, wake)
		}
		var observed documentDirectoryWatch
		if native != nil {
			observed = native
		}
		slot.finish(observed, err)
		wake()
	}()
}

func (a *App) drainEditorPreferencesWatch() {
	state := a.settingsSubscription.editorPreferences
	if !state.watchDirty.Swap(false) {
		return
	}
	state.Lock()
	if state.reading {
		state.watchDirty.Store(true)
		state.Unlock()
		return
	}
	watch, ready, err := state.watch.state()
	if ready && err != nil {
		state.Unlock()
		a.backgroundFailed("editor_preferences_watch", err)
		return
	}
	if watch == nil {
		state.Unlock()
		return
	}
	changes := watch.Changes(nil)
	if changes.Resync {
		// Resync can mean the watched directory was replaced or the stream
		// ended. Register a fresh stream before its initial full reload.
		old := state.watch
		state.watch = &documentWatch{}
		state.Unlock()
		old.close()
		a.startEditorPreferencesWatch(state)
		return
	}
	if !ready && !changes.Resync && !slices.Contains(changes.Names, settingsFile) {
		state.Unlock()
		return
	}
	state.reading = true
	generation := state.latest.generation
	dir := a.store.Dir()
	state.Unlock()
	a.background(nil, kernelCallTimeout, func(ctx context.Context) func(*App) {
		var next settings
		_, err := store.At(dir).Load(settingsFile, &next)
		var resolved core.EditorPreferences
		if err == nil {
			resolved, err = core.NewClient().ResolveEditorPreferences(ctx, next.EditorPreferences)
		}
		// Publication ownership outlives the initiating App when another
		// project/window still uses this directory. Complete the shared read
		// before posting UI work, even if that initiating window has closed.
		state.completeEditorPreferencesRead(next.EditorPreferences, resolved, generation, err)
		return func(a *App) {
			if err != nil {
				a.backgroundFailed("editor_preferences_reload", err)
			}
		}
	})
}

func (state *editorPreferencesPublication) completeEditorPreferencesRead(stored core.EditorStoredPreferences, resolved core.EditorPreferences, generation uint64, err error) {
	state.Lock()
	state.reading = false
	if err == nil && generation == state.latest.generation && !state.pendingEditor && !reflect.DeepEqual(stored, state.latest.stored) {
		state.latest = editorPreferencesSnapshot{stored, resolved, state.latest.generation + 1}
	}
	state.Unlock()
	state.invalidate()
}
