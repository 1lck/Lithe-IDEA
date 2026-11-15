//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

func TestVisualBuiltinKeymapImport(t *testing.T) {
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
	}{{"light", i18n.English}, {"dark", i18n.Chinese}} {
		t.Run(look.theme, func(t *testing.T) {
			w, _ := importWindow(t)
			w.ctrl.opts.Text = func() *i18n.Messages { return i18n.For(look.language) }
			w.ctrl.opts.Language = func() i18n.Language { return look.language }
			w.sess.values.Theme = look.theme
			importPreview(t, w, shortcutImportFile(t))
			w.keyImport.name.SetText("Imported keys")
			session, err := headless.Open(w.config(), nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			if err = session.Driver().Pump(); err != nil {
				t.Fatal(err)
			}
			if err = session.Advance(300 * time.Millisecond); err != nil {
				t.Fatal(err)
			}
			if err = session.Screenshot(filepath.Join(out, "keymap-import-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
