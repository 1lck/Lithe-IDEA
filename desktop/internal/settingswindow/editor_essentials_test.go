package settingswindow

import (
	"reflect"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/gfx"
)

func TestEditorAutoCompletionSettingTogglesAndRestoresDefault(t *testing.T) {
	var changes []bool
	w := newWindow(NewController(Options{
		SetDisableAutoCompletion: func(disabled bool) { changes = append(changes, disabled) },
	}), Values{Language: "en"})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	d.click(i18n.Shared(i18n.English, "desktop.editorPrefs.autoCompletion"))
	d.pump()
	if len(changes) != 1 || !changes[0] || !w.sess.values.DisableAutoCompletion {
		t.Fatalf("switch did not disable automatic completion: %v", changes)
	}
	d.click(i18n.For(i18n.English).Settings.RestoreDefaults)
	d.pump()
	if len(changes) != 2 || changes[1] || w.sess.values.DisableAutoCompletion {
		t.Fatalf("restore did not re-enable automatic completion: %v", changes)
	}
}

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
	if !reflect.DeepEqual(next.sess.values.EditorPreferences, resolved) {
		t.Fatalf("reload %+v, want %+v", next.sess.values.EditorPreferences, resolved)
	}
}

func TestEditorRainbowBracketsSavesAndRestoresRealPreferences(t *testing.T) {
	var stored core.EditorStoredPreferences
	var resolved core.EditorPreferences
	var writes int
	w := newWindow(NewController(Options{SetEditorPreferences: func(s core.EditorStoredPreferences, r core.EditorPreferences) {
		stored, resolved = s, r
		writes++
	}}), Values{Language: "en", WindowWidth: windowMinWidth, WindowHeight: windowMinHeight, EditorStoredPreferences: core.EditorStoredPreferences{
		RainbowLightColors: []string{"#AA3300", "#2266FF"},
	}})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	toggle := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowBrackets")
	lightLabel := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowLightColors")
	swatch := i18n.SharedFormat(i18n.English, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": lightLabel, "number": "1"})
	clickPickerButton := func(label string) {
		t.Helper()
		// The settings window and the picker both have a Cancel button.
		// The picker buttons belong to its own focus scope.
		for _, hit := range d.driver.Snapshot().Hits {
			if hit.Label == label && hit.Role == gfx.RoleButton && !hit.Scope.IsZero() {
				d.clickHit(hit)
				return
			}
		}
		t.Fatalf("no color picker button labeled %q", label)
	}
	if writes != 0 || d.hit(toggle).Checked || d.has(swatch) {
		t.Fatal("opening editor settings should show the opt-in with palettes collapsed")
	}
	d.click(toggle)
	d.pump()
	if writes != 1 || stored.RainbowBrackets == nil || !*stored.RainbowBrackets || !resolved.RainbowBrackets ||
		len(stored.RainbowLightColors) != 2 || stored.RainbowDarkColors != nil {
		t.Fatalf("switch should preserve the custom two-color light palette and inherit dark colors: %+v", stored)
	}

	d.click(swatch)
	d.pump()
	w.rainbowLight.swatches[0].picker.SetHexText("#9700AA")
	d.pump()
	clickPickerButton(w.text.Settings.Cancel)
	d.pump()
	if writes != 1 || stored.RainbowLightColors[0] != "#AA3300" || w.sess.finished.Load() {
		t.Fatal("cancel should close the picker and keep the settings window and color")
	}
	d.click(swatch)
	d.pump()
	w.rainbowLight.swatches[0].picker.SetHexText("#9700aa")
	d.pump()
	if writes != 1 {
		t.Fatal("changing the color picker draft saved before confirmation")
	}
	clickPickerButton(i18n.Shared(i18n.English, "ui.save"))
	d.pump()
	wantLight := []string{"#9700AA", "#2266FF"}
	if writes != 2 || !slices.Equal(stored.RainbowLightColors, wantLight) ||
		!slices.Equal(resolved.RainbowLightColors, wantLight) || stored.RainbowDarkColors != nil ||
		w.editorPrefsError != "" {
		t.Fatalf("color picker save should preserve the other colors and normalize the applied value: %+v", stored)
	}

	add := i18n.SharedFormat(i18n.English, "desktop.editorPrefs.rainbowAddColor", map[string]string{"palette": lightLabel})
	d.click(add)
	d.pump()
	w.rainbowLight.add.picker.SetHexText("#00695C")
	d.pump()
	clickPickerButton(i18n.Shared(i18n.English, "ui.save"))
	d.pump()
	if writes != 3 || !slices.Equal(stored.RainbowLightColors, []string{"#9700AA", "#2266FF", "#00695C"}) {
		t.Fatalf("add color should append one slot without changing the existing colors: %+v", stored)
	}
	added := i18n.SharedFormat(i18n.English, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": lightLabel, "number": "3"})
	d.click(added)
	d.pump()
	clickPickerButton(i18n.Shared(i18n.English, "ui.remove"))
	d.pump()
	if writes != 4 || !slices.Equal(stored.RainbowLightColors, wantLight) {
		t.Fatalf("remove color should delete only the selected slot: %+v", stored)
	}

	reopened := newWindow(NewController(Options{}), Values{Language: "en", EditorStoredPreferences: stored})
	reopened.sess.page = pageEditor
	second := openWindow(t, reopened)
	second.pump()
	if !second.hit(toggle).Checked || !slices.Equal(reopened.sess.values.EditorPreferences.RainbowLightColors, wantLight) || second.has(added) {
		t.Fatal("reopened settings did not display the values saved to the editor configuration")
	}

	d.click(w.text.Settings.RestoreDefaults)
	d.pump()
	if writes != 5 || stored.RainbowBrackets != nil || stored.RainbowLightColors != nil || resolved.RainbowBrackets || d.has(swatch) {
		t.Fatalf("reset did not clear the rainbow bracket preferences: writes=%d, stored=%+v, resolved=%t, swatches=%t", writes, stored, resolved.RainbowBrackets, d.has(swatch))
	}
}

func TestEditorRainbowPaletteShowsLocalizedInvalidHex(t *testing.T) {
	language := i18n.Chinese
	writes := 0
	w := newWindow(NewController(Options{
		Text:     func() *i18n.Messages { return i18n.For(language) },
		Language: func() i18n.Language { return language },
		SetEditorPreferences: func(core.EditorStoredPreferences, core.EditorPreferences) {
			writes++
		},
	}), Values{Language: language.Code(), WindowWidth: windowMinWidth, WindowHeight: windowMinHeight})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	d.click(i18n.Shared(language, "desktop.editorPrefs.rainbowBrackets"))
	d.pump()
	light := i18n.Shared(language, "desktop.editorPrefs.rainbowLightColors")
	swatch := i18n.SharedFormat(language, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": light, "number": "1"})
	d.click(swatch)
	d.pump()
	d.click(i18n.Shared(language, "desktop.editorPrefs.rainbowHex"))
	d.typeText("G")
	d.pump()
	message := i18n.Shared(language, "desktop.editorPrefs.rainbowInvalidHex")
	if !d.text(message) {
		t.Fatalf("color picker did not show the localized error %q", message)
	}
	d.key(gfx.KeyEnter)
	d.pump()
	if writes != 1 || !d.text(message) {
		t.Fatal("saving invalid hex should keep the error visible without changing preferences")
	}
}

func TestEditorRainbowVariablesHasIndependentSwitchAndSharedPalette(t *testing.T) {
	var stored core.EditorStoredPreferences
	var resolved core.EditorPreferences
	w := newWindow(NewController(Options{SetEditorPreferences: func(s core.EditorStoredPreferences, r core.EditorPreferences) {
		stored, resolved = s, r
	}}), Values{Language: "en"})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	brackets := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowBrackets")
	variables := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowVariables")
	light := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowLightColors")
	swatch := i18n.SharedFormat(i18n.English, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": light, "number": "1"})
	if d.hit(variables).Checked || d.hit(brackets).Checked || d.has(swatch) {
		t.Fatal("both rainbow features should start off with their shared palette collapsed")
	}
	d.click(variables)
	d.pump()
	if !d.hit(variables).Checked || d.hit(brackets).Checked || !d.has(swatch) ||
		stored.RainbowVariables == nil || !*stored.RainbowVariables || !resolved.RainbowVariables || resolved.RainbowBrackets {
		t.Fatal("enabling rainbow variables alone should show the shared palette")
	}
	d.click(brackets)
	d.pump()
	d.click(variables)
	d.pump()
	if d.hit(variables).Checked || !d.hit(brackets).Checked || !d.has(swatch) ||
		stored.RainbowVariables == nil || *stored.RainbowVariables || resolved.RainbowVariables || !resolved.RainbowBrackets {
		t.Fatal("turning off variables should preserve bracket coloring and the shared palette")
	}
	d.click(brackets)
	d.pump()
	if d.has(swatch) || resolved.RainbowBrackets || resolved.RainbowVariables {
		t.Fatal("turning off both rainbow features should collapse their shared palette")
	}
}

func TestEditorIndentGuidesPreserveRainbowPreference(t *testing.T) {
	var stored core.EditorStoredPreferences
	var resolved core.EditorPreferences
	var writes int
	w := newWindow(NewController(Options{SetEditorPreferences: func(s core.EditorStoredPreferences, r core.EditorPreferences) {
		stored, resolved = s, r
		writes++
	}}), Values{Language: "en"})
	w.sess.page = pageEditor
	d := openWindow(t, w)
	d.pump()
	guides := i18n.Shared(i18n.English, "desktop.editorPrefs.indentGuides")
	rainbow := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowIndentGuides")
	light := i18n.Shared(i18n.English, "desktop.editorPrefs.rainbowLightColors")
	swatch := i18n.SharedFormat(i18n.English, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": light, "number": "1"})
	parent, child := d.hit(guides), d.hit(rainbow)
	if !parent.Checked || child.Checked || child.Disabled || d.has(swatch) {
		t.Fatalf("unexpected default guide controls: parent=%+v, child=%+v", parent, child)
	}
	d.click(rainbow)
	d.pump()
	if !resolved.RainbowIndentGuidesEffective || stored.RainbowIndentGuides == nil || !*stored.RainbowIndentGuides || !d.has(swatch) {
		t.Fatal("enabling rainbow guides alone should enable their shared palette")
	}
	d.click(guides)
	d.pump()
	child = d.hit(rainbow)
	if !child.Disabled || !child.Checked || resolved.RainbowIndentGuidesEffective ||
		stored.RainbowIndentGuides == nil || !*stored.RainbowIndentGuides || d.has(swatch) {
		t.Fatal("disabling guides should preserve the configured rainbow preference and hide its palette")
	}
	writesBeforeClick := writes
	d.clickHit(child)
	d.pump()
	if writes != writesBeforeClick {
		t.Fatal("disabled rainbow switch should not write preferences")
	}

	reopened := newWindow(NewController(Options{SetEditorPreferences: func(s core.EditorStoredPreferences, r core.EditorPreferences) {
		stored, resolved = s, r
	}}), Values{Language: "en", EditorStoredPreferences: stored})
	reopened.sess.page = pageEditor
	second := openWindow(t, reopened)
	second.pump()
	if child = second.hit(rainbow); !child.Disabled || !child.Checked {
		t.Fatal("reopened settings should retain the disabled, checked rainbow switch")
	}
	second.click(guides)
	second.pump()
	if child = second.hit(rainbow); child.Disabled || !child.Checked || !resolved.RainbowIndentGuidesEffective || !second.has(swatch) {
		t.Fatal("re-enabling indent guides should restore rainbow guides and the palette")
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
