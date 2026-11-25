package settingswindow

import (
	"reflect"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type editorPreferencesUpdate struct {
	stored   core.EditorStoredPreferences
	resolved core.EditorPreferences
}

// EditorPreferencesChanged coalesces external changes for the settings window's
// own UI thread, so its next edit starts from the current stored preferences.
func (c *Controller) EditorPreferencesChanged(stored core.EditorStoredPreferences, resolved core.EditorPreferences) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil {
		c.current.editorPreferencesChanged.Store(&editorPreferencesUpdate{stored, resolved})
		c.current.inv.Invalidate()
	}
}

func (w *window) takeEditorPreferences() {
	next := w.editorPreferencesChanged.Swap(nil)
	if next == nil || (reflect.DeepEqual(w.sess.values.EditorStoredPreferences, next.stored) &&
		reflect.DeepEqual(w.sess.values.EditorPreferences, next.resolved)) {
		return
	}
	w.sess.values.EditorStoredPreferences = next.stored
	w.sess.values.EditorPreferences = next.resolved
	w.editorDelay.SetText(strconv.FormatUint(next.resolved.AutoSaveDelayMilliseconds, 10))
	w.loadRainbowPalettes(next.resolved)
	w.editorPrefsError = ""
	w.editorDelayReady = true
}
