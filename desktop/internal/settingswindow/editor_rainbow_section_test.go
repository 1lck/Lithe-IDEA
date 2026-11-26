package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

func TestEditorRainbowSettingsHaveTheirOwnSection(t *testing.T) {
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		t.Run(language.Code(), func(t *testing.T) {
			on := true
			w := newWindow(NewController(Options{
				Text:     func() *i18n.Messages { return i18n.For(language) },
				Language: func() i18n.Language { return language },
			}), Values{Language: language.Code(), WindowWidth: windowMinWidth, WindowHeight: 1000,
				EditorStoredPreferences: core.EditorStoredPreferences{RainbowBrackets: &on}})
			w.sess.page = pageEditor
			d := openWindow(t, w)
			d.pump()
			title := i18n.Shared(language, "desktop.editorPrefs.rainbowBrackets")
			toggle := d.hit(title)
			var heading gfx.Rect
			for _, text := range d.driver.Snapshot().Texts {
				if text.Value == title && text.Bounds.Y < toggle.Bounds.Y {
					heading = text.Bounds
				}
			}
			if heading.Height == 0 {
				t.Fatal("rainbow settings have no separate section heading")
			}
			display := d.hit(i18n.Shared(language, "desktop.editorPrefs.cursorBlink"))
			indent := d.hit(i18n.Shared(language, "desktop.editorPrefs.indentGuides"))
			guides := d.hit(i18n.Shared(language, "desktop.editorPrefs.rainbowIndentGuides"))
			variables := d.hit(i18n.Shared(language, "desktop.editorPrefs.rainbowVariables"))
			if display.Bounds.Y+display.Bounds.Height >= heading.Y || indent.Bounds.Y+indent.Bounds.Height >= heading.Y || guides.Bounds.Y < heading.Y || variables.Bounds.Y < heading.Y {
				t.Fatal("display controls and rainbow controls are not in separate sections")
			}
			for _, key := range []string{"desktop.editorPrefs.rainbowLightColors", "desktop.editorPrefs.rainbowDarkColors"} {
				palette := i18n.Shared(language, key)
				label := i18n.SharedFormat(language, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": palette, "number": "1"})
				if swatch := d.hit(label); swatch.Bounds.Y < heading.Y {
					t.Fatal("a palette is still in the display section")
				}
			}
		})
	}
}
