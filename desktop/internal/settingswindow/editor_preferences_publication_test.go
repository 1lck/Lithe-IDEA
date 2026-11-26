package settingswindow

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

func TestEditorPreferencesPublicationRefreshesOpenSettings(t *testing.T) {
	var saved core.EditorStoredPreferences
	ctrl := NewController(Options{SetEditorPreferences: func(stored core.EditorStoredPreferences, _ core.EditorPreferences) { saved = stored }})
	w := newWindow(ctrl, Values{Language: "en"})
	ctrl.current = w
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	on := true
	stored := core.EditorStoredPreferences{
		RainbowBrackets: &on, RainbowVariables: &on,
		RainbowLightColors: []string{"#112233", "#445566"},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolved, err := core.NewClient().ResolveEditorPreferences(ctx, stored)
	if err != nil {
		t.Fatal(err)
	}
	ctrl.EditorPreferencesChanged(core.EditorStoredPreferences{}, core.EditorPreferences{})
	ctrl.EditorPreferencesChanged(stored, resolved)
	d.pump()
	if !reflect.DeepEqual(w.sess.values.EditorStoredPreferences, stored) || !reflect.DeepEqual(w.sess.values.EditorPreferences, resolved) {
		t.Fatal("open settings did not display the newest published preferences")
	}
	d.click(i18n.Shared(i18n.English, "desktop.editorPrefs.lineNumbers"))
	d.pump()
	if saved.RainbowVariables == nil || !*saved.RainbowVariables || !reflect.DeepEqual(saved.RainbowLightColors, stored.RainbowLightColors) {
		t.Fatalf("editing another setting reverted the published rainbow preferences: %+v", saved)
	}
}
