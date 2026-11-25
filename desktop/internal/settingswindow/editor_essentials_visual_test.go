//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/headless"
)

func TestVisualEditorEssentialsSettings(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		for _, scene := range []string{"editor-settings", "keymap-schemes", "keymap-double-shift"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				w := newWindow(NewController(Options{Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language }, SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" }}), Values{Language: look.language.Code(), Theme: look.theme})
				switch scene {
				case "editor-settings":
					w.sess.page = pageEditor
				case "keymap-double-shift":
					// Filtering by the gesture brings Search Everywhere's row, with its Double
					// Shift chip, to the top of the page.
					w.sess.page = pageKeymap
					w.keymap.query.SetText(shortcuts.DoubleShiftLabel())
				default:
					w.sess.page = pageKeymap
					if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "saveAs", ID: "my-keys", Name: "My workspace"}) {
						t.Fatal(w.scheme.failure)
					}
					// One action with its keys changed shows Reset pressable beside ones that
					// are not, and another shows the recorder waiting for a chord.
					actions := shortcuts.All()
					w.setKeymap(shortcuts.Overrides(nil).With(actions[0].ID, nil))
					// The schemes are loaded; loading them again in the first paint would end
					// the recording.
					w.scheme.ready = true
					w.beginRecording(actions[1])
				}
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				if err = session.Driver().Pump(); err != nil {
					t.Fatal(err)
				}
				if err = session.Screenshot(filepath.Join(out, scene+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
				if scene == "editor-settings" {
					d := &windowDriver{t: t, w: w, driver: session.Driver()}
					indentGuideLabel := i18n.Shared(look.language, "desktop.editorPrefs.indentGuides")
					rainbowGuideLabel := i18n.Shared(look.language, "desktop.editorPrefs.rainbowIndentGuides")
					d.click(rainbowGuideLabel)
					if err = session.Advance(300 * time.Millisecond); err != nil {
						t.Fatal(err)
					}
					if err = session.Screenshot(filepath.Join(out, "editor-settings-rainbow-guides-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
					d.click(indentGuideLabel)
					if err = session.Advance(300 * time.Millisecond); err != nil {
						t.Fatal(err)
					}
					if err = session.Screenshot(filepath.Join(out, "editor-settings-guides-disabled-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
					switchLabel := i18n.Shared(look.language, "desktop.editorPrefs.rainbowBrackets")
					variablesLabel := i18n.Shared(look.language, "desktop.editorPrefs.rainbowVariables")
					d.click(switchLabel)
					d.pump()
					d.click(variablesLabel)
					d.pump()
					if !d.hit(switchLabel).Checked || !d.hit(variablesLabel).Checked {
						t.Fatal("both rainbow switches should be enabled")
					}
					if err = session.Advance(300 * time.Millisecond); err != nil {
						t.Fatal(err)
					}
					if err = session.Screenshot(filepath.Join(out, "editor-settings-rainbow-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
					palette := i18n.Shared(look.language, "desktop.editorPrefs.rainbowLightColors")
					if look.theme == "dark" {
						palette = i18n.Shared(look.language, "desktop.editorPrefs.rainbowDarkColors")
					}
					swatch := i18n.SharedFormat(look.language, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{"palette": palette, "number": "1"})
					d.click(swatch)
					if err = session.Advance(300 * time.Millisecond); err != nil {
						t.Fatal(err)
					}
					if err = session.Screenshot(filepath.Join(out, "editor-settings-rainbow-picker-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
				}
			})
		}
	}
}
