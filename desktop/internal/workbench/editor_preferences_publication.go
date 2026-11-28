package workbench

import (
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A live subscription owns the latest immutable preferences for its native
// storage directory and serializes whole-settings writes for that directory.
type editorPreferencesPublication struct {
	sync.Mutex
	latest                  editorPreferencesSnapshot
	pendingEditor           bool
	watch                   *documentWatch
	watchDirty              atomic.Bool
	watchReady              bool
	recentRevision          atomic.Uint64
	reading                 bool
	readAgain               bool
	pendingSave             *settingsSaveBatch
	activeSave              *settingsSaveBatch
	saveSerial, savedSerial uint64
	saveIdle                chan struct{}
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
	if sub != nil {
		select {
		case <-sub.done:
			return
		default:
		}
	}
	// Published preferences must remain immutable for the writer and other windows.
	stored = cloneStoredEditorPreferences(stored)
	resolved.RainbowLightColors = slices.Clone(resolved.RainbowLightColors)
	resolved.RainbowDarkColors = slices.Clone(resolved.RainbowDarkColors)
	state := a.settingsSaveState()
	state.Lock()
	state.latest = editorPreferencesSnapshot{stored, resolved, state.latest.generation + 1}
	state.pendingEditor = true
	state.Unlock()
	if sub == nil {
		a.applyEditorPreferences(stored, resolved)
	} else {
		a.drainEditorPreferences()
	}
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
	docCommentsChanged := a.editorPreferences.RenderDocComments != resolved.RenderDocComments ||
		a.editorPreferences.RenderDocCommentsInReadOnly != resolved.RenderDocCommentsInReadOnly
	rainbowChanged := a.editorPreferences.RainbowBrackets != resolved.RainbowBrackets ||
		a.editorPreferences.RainbowVariables != resolved.RainbowVariables ||
		((resolved.RainbowBrackets || resolved.RainbowVariables) &&
			(!slices.Equal(a.editorPreferences.RainbowLightColors, resolved.RainbowLightColors) ||
				!slices.Equal(a.editorPreferences.RainbowDarkColors, resolved.RainbowDarkColors)))
	a.editorPreferences = resolved
	if inlayChanged {
		a.applyInlayHintsPreference(resolved.InlayHints)
	}
	if docCommentsChanged {
		a.applyDocCommentPreferences()
	}
	if rainbowChanged {
		a.refreshBuiltinRainbowColors()
	}
	if a.settingsWindow != nil {
		a.settingsWindow.EditorPreferencesChanged(stored, resolved)
	}
	a.invalidator.Invalidate()
}
