//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualConsoleEncoding renders the production settings page using Core's real catalog.
func TestVisualConsoleEncoding(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture console settings")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	encodings := consoleTestEncodings(t)
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"/"+theme, func(t *testing.T) {
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, SystemDark: func() bool { return theme == "dark" },
					ConsoleEncodings: func() (ConsoleEncodings, bool) { return encodings, true },
				}), Values{Theme: theme, Language: language.Code()})
				w.sess.page = pageConsole
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				title := i18n.Shared(language, "desktop.consoleSettings.encoding")
				if !d.has(title) {
					t.Fatal("Console page did not render")
				}
				for _, state := range []string{"page", "choices"} {
					if state == "choices" {
						d.click(title)
					}
					if err := session.Screenshot(filepath.Join(out, "console-"+state+"-"+theme+"-"+language.Code()+".png")); err != nil {
						t.Fatal(err)
					}
				}
			})
		}
	}
}
