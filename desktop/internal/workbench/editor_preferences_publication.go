package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// A live subscription owns the latest immutable preferences for its native
// storage directory. The lock also serializes whole-settings writes so a window
// that has not handled its wake cannot restore an older editor configuration.
type editorPreferencesPublication struct {
	sync.Mutex
	latest                  editorPreferencesSnapshot
	pendingEditor           bool
	saveSerial, savedSerial uint64
	watch                   *documentWatch
	watchDirty              atomic.Bool
	reading                 bool
}

type editorPreferencesSnapshot struct {
	stored     core.EditorStoredPreferences
	resolved   core.EditorPreferences
	generation uint64
}

func samePreferencesDirectory(a, b *App) bool {
	x, y := filepath.Clean(a.store.Dir()), filepath.Clean(b.store.Dir())
	if runtime.GOOS == "windows" {
		return strings.EqualFold(x, y)
	}
	return x == y
}

func (a *App) setEditorPreferences(stored core.EditorStoredPreferences, resolved core.EditorPreferences) {
	sub := a.settingsSubscription
	if sub == nil {
		a.applyEditorPreferences(stored, resolved)
		a.saveSettings()
		return
	}
	select {
	case <-sub.done:
		return
	default:
	}
	// Palette editors replace their drafts, while snapshots own their slices.
	stored.RainbowBracketLightColors = slices.Clone(stored.RainbowBracketLightColors)
	stored.RainbowBracketDarkColors = slices.Clone(stored.RainbowBracketDarkColors)
	resolved.RainbowBracketLightColors = slices.Clone(resolved.RainbowBracketLightColors)
	resolved.RainbowBracketDarkColors = slices.Clone(resolved.RainbowBracketDarkColors)
	state := sub.editorPreferences
	state.Lock()
	state.latest = editorPreferencesSnapshot{stored, resolved, state.latest.generation + 1}
	state.pendingEditor = true
	state.Unlock()
	a.drainEditorPreferences()
	a.saveSettings()
	state.invalidate()
}

func (state *editorPreferencesPublication) invalidate() {
	settingsWindows.Lock()
	var targets []*App
	for target, subscribed := range settingsWindows.live {
		if subscribed.editorPreferences == state {
			targets = append(targets, target)
		}
	}
	settingsWindows.Unlock()
	for _, target := range targets {
		target.invalidator.Invalidate()
	}
}

func (a *App) drainEditorPreferences() {
	sub := a.settingsSubscription
	if sub == nil {
		return
	}
	state := sub.editorPreferences
	state.Lock()
	next := state.latest
	state.Unlock()
	if next.generation == sub.editorGeneration {
		return
	}
	sub.editorGeneration = next.generation
	a.applyEditorPreferences(next.stored, next.resolved)
}

func (a *App) applyEditorPreferences(stored core.EditorStoredPreferences, resolved core.EditorPreferences) {
	a.settings.EditorPreferences = stored
	inlayChanged := a.editorPreferences.InlayHints != resolved.InlayHints
	rainbowChanged := a.editorPreferences.RainbowBrackets != resolved.RainbowBrackets ||
		a.editorPreferences.RainbowVariables != resolved.RainbowVariables ||
		((resolved.RainbowBrackets || resolved.RainbowVariables) &&
			(!slices.Equal(a.editorPreferences.RainbowBracketLightColors, resolved.RainbowBracketLightColors) ||
				!slices.Equal(a.editorPreferences.RainbowBracketDarkColors, resolved.RainbowBracketDarkColors)))
	a.editorPreferences = resolved
	if inlayChanged {
		a.applyInlayHintsPreference(resolved.InlayHints)
	}
	if rainbowChanged {
		a.refreshBuiltinRainbowColors()
	}
	if a.settingsWindow != nil {
		a.settingsWindow.EditorPreferencesChanged(stored, resolved)
	}
	a.invalidator.Invalidate()
}

func (a *App) saveSettingsSnapshot() (string, error) {
	sub := a.settingsSubscription
	if sub == nil {
		return a.store.SaveWithBackup(settingsFile, a.settings)
	}
	state := sub.editorPreferences
	state.Lock()
	state.saveSerial++
	serial := state.saveSerial
	next := a.settings
	next.EditorPreferences = state.latest.stored
	state.Unlock()
	if err := os.MkdirAll(a.store.Dir(), 0o700); err != nil {
		return "", err
	}
	lockPath := filepath.Join(a.store.Dir(), ".settings.lock")
	unlock, err := filelock.TryAcquire(lockPath)
	if !errors.Is(err, filelock.ErrBusy) {
		if err != nil {
			return "", err
		}
		return state.persistSettings(a.store, next, serial, unlock)
	}
	// A competing process must never stall the native UI thread. Freeze this
	// whole-settings snapshot, then retry under an owned, bounded background task.
	data, err := json.Marshal(next)
	if err != nil {
		return "", err
	}
	a.background(nil, kernelCallTimeout, func(ctx context.Context) func(*App) {
		var frozen settings
		err := json.Unmarshal(data, &frozen)
		backup := ""
		if err == nil {
			var unlock func() error
			unlock, err = filelock.Acquire(ctx, lockPath)
			if err == nil {
				backup, err = state.persistSettings(a.store, frozen, serial, unlock)
			}
		}
		return func(a *App) { a.reportSettingsSave(backup, err) }
	})
	return "", nil
}

func (state *editorPreferencesPublication) persistSettings(preferences *store.Store, next settings, serial uint64, unlock func() error) (backup string, err error) {
	defer func() { err = errors.Join(err, unlock()) }()
	state.Lock()
	if serial < state.savedSerial {
		state.Unlock()
		return "", nil
	}
	pending := state.pendingEditor
	snapshot := state.latest
	state.Unlock()
	// Reload within the OS lock using a fresh native Store. This also preserves
	// keys written by another version since this process originally loaded them.
	disk := store.At(preferences.Dir())
	var current settings
	found, loadErr := disk.Load(settingsFile, &current)
	if pending {
		next.EditorPreferences = snapshot.stored
	} else if found && loadErr == nil {
		next.EditorPreferences = current.EditorPreferences
	}
	backup, err = disk.SaveWithBackup(settingsFile, next)
	if err == nil {
		state.Lock()
		state.savedSerial = serial
		if state.latest.generation == snapshot.generation {
			state.pendingEditor = false
		}
		state.Unlock()
	}
	return backup, err
}
