//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/cli"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

func TestVisualCLISettings(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"-"+theme, func(t *testing.T) {
				// Actual shell configuration is read only. This scene never clicks registration.
				manager := cli.New()
				manager.Directory = filepath.Join(t.TempDir(), "bin")
				w := newWindow(NewController(Options{CLI: manager, Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language }, SystemLanguage: language, SystemDark: func() bool { return theme == "dark" }}), Values{Theme: theme, Language: language.Code()})
				config := w.config()
				config.Width, config.Height = 1120, 820
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				d.pump()
				deadline := time.NewTimer(5 * time.Second)
				defer deadline.Stop()
				for !w.cli.loaded && w.cli.err == nil {
					select {
					case <-d.driver.Wakes():
						d.pump()
					case <-deadline.C:
						t.Fatal("CLI source read timed out")
					}
				}
				if w.cli.err != nil {
					t.Fatal(w.cli.err)
				}
				if err := session.Screenshot(filepath.Join(out, "cli-settings-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
