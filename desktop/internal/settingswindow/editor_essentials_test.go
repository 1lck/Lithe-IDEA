package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"testing"
)

func TestEditorEssentialsDisplaySettingsApplyActualValues(t *testing.T) {
	var stored core.EditorStoredPreferences
	var resolved core.EditorPreferences
	w := newWindow(NewController(Options{SetEditorPreferences: func(s core.EditorStoredPreferences, r core.EditorPreferences) { stored, resolved = s, r }}), Values{Language: "en"})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.editorPrefs.lineNumbers"))
	d.pump()
	if stored.LineNumbers == nil || *stored.LineNumbers || resolved.LineNumbers {
		t.Fatal("line number setting did not reach owner")
	}
	prefs := w.sess.values.EditorPreferences
	prefs.Whitespace = true
	prefs.CursorStyle = "block"
	prefs.CursorBlink = false
	prefs.AutoSaveDelayMilliseconds = 1
	w.setEditorPresentation(prefs)
	if resolved.CursorStyle != "block" || !resolved.Whitespace || resolved.CursorBlink || resolved.AutoSaveDelayMilliseconds != 250 || w.editorDelay.Text() != "250" {
		t.Fatalf("resolved display settings: %+v", resolved)
	}
	// The persisted source reopens as the same actual preference values.
	next := newWindow(NewController(Options{}), Values{Language: "en", EditorStoredPreferences: stored})
	next.sess.page = pageEditor
	nd := openWindow(t, next)
	nd.pump()
	if next.sess.values.EditorPreferences != resolved {
		t.Fatalf("reload %+v, want %+v", next.sess.values.EditorPreferences, resolved)
	}
}
func TestEditorEssentialsKeymapSchemesStayIndependent(t *testing.T) {
	var published core.KeymapSchemeResult
	w := newWindow(NewController(Options{SetKeymapSchemes: func(value core.KeymapSchemeResult) { published = value }}), Values{Language: "en"})
	w.sess.page = pageKeymap
	d := openWindow(t, w)
	d.pump()
	if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "saveAs", ID: "mine", Name: "My keys"}) {
		t.Fatal(w.scheme.failure)
	}
	w.setKeymap(shortcuts.Overrides{"editor.find": []string{"meta+shift+f"}})
	if published.State.Active != "mine" || len(published.Bindings["editor.find"]) != 1 {
		t.Fatalf("active scheme %+v", published)
	}
	if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "select", ID: "default"}) || len(w.sess.values.Keymap) != 0 {
		t.Fatal("custom keys leaked into default")
	}
	if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "rename", ID: "mine", Name: "Renamed"}) {
		t.Fatal(w.scheme.failure)
	}
	if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "select", ID: "mine"}) || len(w.sess.values.Keymap["editor.find"]) != 1 {
		t.Fatal("custom keys were lost")
	}
	before := w.sess.values.KeymapSchemes
	if w.reduceScheme(core.KeymapSchemeRequest{Operation: "saveAs", ID: "duplicate", Name: "renamed"}) || len(w.sess.values.KeymapSchemes.Schemes) != len(before.Schemes) {
		t.Fatal("duplicate changed state")
	}
	if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "delete", ID: "mine"}) || w.sess.values.KeymapSchemes.Active != "default" {
		t.Fatal("delete did not return to default")
	}
	if w.reduceScheme(core.KeymapSchemeRequest{Operation: "delete", ID: "default"}) {
		t.Fatal("default deleted")
	}
}
