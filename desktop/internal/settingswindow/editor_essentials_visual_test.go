//go:build vivahead && lithevisual

package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
	"os"
	"path/filepath"
	"testing"
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
		for _, scene := range []string{"editor-settings", "keymap-schemes"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				w := newWindow(NewController(Options{Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language }, SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" }}), Values{Language: look.language.Code(), Theme: look.theme})
				if scene == "editor-settings" {
					w.sess.page = pageEditor
				} else {
					w.sess.page = pageKeymap
					if !w.reduceScheme(core.KeymapSchemeRequest{Operation: "saveAs", ID: "my-keys", Name: "My workspace"}) {
						t.Fatal(w.scheme.failure)
					}
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
			})
		}
	}
}
