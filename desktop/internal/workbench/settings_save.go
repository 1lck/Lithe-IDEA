package workbench

import (
	"context"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const settingsFlushTimeout = 5 * time.Second

type settingsSaveRequest struct {
	target     *App
	ctx        context.Context
	next       settings
	geometry   windowGeometry
	appliedGeo bool
	serial     uint64
	writer     func(*store.Store, settings) (string, error)
}

// A pending batch can be replaced by the latest snapshot until the worker holds the
// file lock. A caller awaiting that batch observes the result of the surviving write.
type settingsSaveBatch struct {
	request settingsSaveRequest
	done    chan struct{}
	err     error
}

func (b *settingsSaveBatch) wait(ctx context.Context) error {
	select {
	case <-b.done:
		return b.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (a *App) settingsSaveState() *editorPreferencesPublication {
	if a.settingsPublication == nil {
		a.settingsPublication = &editorPreferencesPublication{latest: editorPreferencesSnapshot{
			stored: cloneStoredEditorPreferences(a.settings.EditorPreferences), resolved: a.editorPreferences, generation: 1,
		}, watch: &documentWatch{}}
	}
	return a.settingsPublication
}

// A tab opened during a write starts with the in-memory settings it would have read
// had that write already finished. The caller clones the immutable snapshot.
func (state *editorPreferencesPublication) queuedSettings() *settings {
	if state == nil {
		return nil
	}
	state.Lock()
	defer state.Unlock()
	b := state.pendingSave
	if b == nil {
		b = state.activeSave
	}
	if b == nil {
		return nil
	}
	next := b.request.next
	next.EditorPreferences = state.latest.stored
	return &next
}

func (a *App) saveSettings() {
	a.queueSettingsSave()
}

func (a *App) queueSettingsSave() *settingsSaveBatch {
	a.settings.WorkbenchBackground = a.savedBackgroundState()
	a.updates.store(&a.settings)
	geo, appliedGeo := a.sessions.applyWindowGeometry(&a.settings)
	next := a.settings.clone()
	state := a.settingsSaveState()
	state.Lock()
	if state.pendingSave == nil {
		state.pendingSave = &settingsSaveBatch{done: make(chan struct{})}
	}
	batch := state.pendingSave
	state.saveSerial++
	batch.request = settingsSaveRequest{
		target: a, ctx: a.operationContext(context.Background()), next: next,
		geometry: geo, appliedGeo: appliedGeo, serial: state.saveSerial, writer: a.settingsDiskWriter,
	}
	start := state.saveIdle == nil
	if start {
		state.saveIdle = make(chan struct{})
	}
	state.Unlock()
	if start {
		dir := a.store.Dir()
		a.background(nil, 0, func(context.Context) func(*App) {
			state.writeSettings(dir)
			return nil
		})
	}
	return batch
}

// writeSettings owns the only active write for this preferences directory. Its
// mutex only protects in-memory state, including while another process holds the lock.
func (state *editorPreferencesPublication) writeSettings(dir string) {
	for {
		state.Lock()
		if state.pendingSave == nil {
			close(state.saveIdle)
			state.saveIdle = nil
			state.Unlock()
			return
		}
		state.Unlock()

		unlock, err := lockSettingsFile(dir)
		state.Lock()
		batch := state.pendingSave
		state.activeSave, state.pendingSave = batch, nil
		editor, pendingEditor := state.latest, state.pendingEditor
		state.Unlock()

		req := batch.request
		var backup string
		if err == nil {
			backup, err = req.write(dir, editor.stored, pendingEditor, unlock)
		}
		if err != nil {
			req.target.operationFailedIn(req.ctx, "settings_save", documentLogError(err))
		}
		state.Lock()
		if err == nil {
			state.savedSerial = req.serial
			if state.latest.generation == editor.generation {
				state.pendingEditor = false
			}
		}
		state.Unlock()
		req.target.post(func(a *App) {
			a.reportSettingsSave(backup, err)
			state.Lock()
			latest := state.savedSerial == req.serial
			state.Unlock()
			if err == nil && req.appliedGeo && latest {
				a.sessions.noteSavedWindowGeometry(req.geometry)
			}
		})
		state.Lock()
		batch.err = err
		close(batch.done)
		state.activeSave = nil
		state.Unlock()
	}
}

func lockSettingsFile(dir string) (func() error, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	return filelock.Acquire(ctx, filepath.Join(dir, ".settings.lock"))
}

func (r settingsSaveRequest) write(dir string, editor core.EditorStoredPreferences, pendingEditor bool, unlock func() error) (backup string, err error) {
	defer func() { err = errors.Join(err, unlock()) }()
	// Reload under the OS lock to preserve keys written since startup and to
	// move unreadable content aside before replacing it.
	disk := store.At(dir)
	var current settings
	found, loadErr := disk.Load(settingsFile, &current)
	next := r.next
	if pendingEditor {
		next.EditorPreferences = editor
	} else if found && loadErr == nil {
		next.EditorPreferences = current.EditorPreferences
	}
	if r.writer != nil {
		return r.writer(disk, next)
	}
	return disk.SaveWithBackup(settingsFile, next)
}

// flushSettings delays closing the window while the writer drains. The window
// continues dispatching events, including save results, until it can close.
func (a *App) flushSettings(timeout time.Duration, allow func()) {
	state := a.settingsPublication
	if state == nil {
		allow()
		return
	}
	state.Lock()
	idle := state.saveIdle
	state.Unlock()
	if idle == nil {
		allow()
		return
	}
	if timeout <= 0 {
		a.backgroundFailed(shutdownWaitOperation, context.DeadlineExceeded)
		allow()
		return
	}
	deadline := time.Now().Add(timeout)
	a.background(nil, timeout, func(ctx context.Context) func(*App) {
		select {
		case <-idle:
			return func(a *App) {
				// The window can queue another write between the worker
				// becoming idle and this callback being dispatched.
				a.flushSettings(time.Until(deadline), allow)
			}
		case <-ctx.Done():
			return func(a *App) {
				a.backgroundFailed(shutdownWaitOperation, ctx.Err())
				allow()
			}
		}
	})
}

// clone detaches the snapshot's mutable values from the window thread. File
// encoding and merging are deferred to the writer.
func (s settings) clone() settings {
	s.EditorPreferences = cloneStoredEditorPreferences(s.EditorPreferences)
	s.KeymapSchemes.Schemes = slices.Clone(s.KeymapSchemes.Schemes)
	for i := range s.KeymapSchemes.Schemes {
		scheme := &s.KeymapSchemes.Schemes[i]
		scheme.Bindings = cloneSettingsBindings(scheme.Bindings)
	}
	s.Keymap = cloneSettingsBindings(s.Keymap)
	s.MarketplaceSources = slices.Clone(s.MarketplaceSources)
	s.DismissedPluginRecommendations = slices.Clone(s.DismissedPluginRecommendations)
	s.EditorTabLimit = cloneSetting(s.EditorTabLimit)
	s.ProcessTermination.ConfirmTerminalTabClose = cloneSetting(s.ProcessTermination.ConfirmTerminalTabClose)
	s.ProcessTermination.GracefulStopSeconds = cloneSetting(s.ProcessTermination.GracefulStopSeconds)
	s.DebugSteppingFilters = maps.Clone(s.DebugSteppingFilters)
	for id, filters := range s.DebugSteppingFilters {
		filters.ClassNameFilters = slices.Clone(filters.ClassNameFilters)
		s.DebugSteppingFilters[id] = filters
	}
	s.Fonts = slices.Clone(s.Fonts)
	for i := range s.Fonts {
		s.Fonts[i].Scopes = slices.Clone(s.Fonts[i].Scopes)
	}
	s.UpdateSources = maps.Clone(s.UpdateSources)
	s.UpdateSkipped = maps.Clone(s.UpdateSkipped)
	s.Network.Exclusions = slices.Clone(s.Network.Exclusions)
	s.Network.PasswordIdentity = cloneSetting(s.Network.PasswordIdentity)
	s.LocalHistory.IgnorePatterns = slices.Clone(s.LocalHistory.IgnorePatterns)
	s.LocalHistory.IgnoreRegexes = slices.Clone(s.LocalHistory.IgnoreRegexes)
	return s
}

func cloneStoredEditorPreferences(p core.EditorStoredPreferences) core.EditorStoredPreferences {
	p.LineNumbers = cloneSetting(p.LineNumbers)
	p.Whitespace = cloneSetting(p.Whitespace)
	p.IndentGuides = cloneSetting(p.IndentGuides)
	p.RainbowIndentGuides = cloneSetting(p.RainbowIndentGuides)
	p.InlayHints = cloneSetting(p.InlayHints)
	p.RainbowBrackets = cloneSetting(p.RainbowBrackets)
	p.RainbowVariables = cloneSetting(p.RainbowVariables)
	p.RainbowLightColors = slices.Clone(p.RainbowLightColors)
	p.RainbowDarkColors = slices.Clone(p.RainbowDarkColors)
	p.CursorBlink = cloneSetting(p.CursorBlink)
	p.AutoSaveDelayMilliseconds = cloneSetting(p.AutoSaveDelayMilliseconds)
	return p
}

func cloneSettingsBindings(bindings map[string][]string) map[string][]string {
	cloned := maps.Clone(bindings)
	for name, keys := range cloned {
		cloned[name] = slices.Clone(keys)
	}
	return cloned
}

func cloneSetting[T any](value *T) *T {
	if value == nil {
		return nil
	}
	return new(*value)
}
