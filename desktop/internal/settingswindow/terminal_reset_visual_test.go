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

// Render the real settings page before and after the footer reset, with an isolated owner.
func TestVisualTerminalRestoreDefaults(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"light", "dark"} {
			t.Run(theme+"-"+language.Code(), func(t *testing.T) {
				var scrollbacks []int
				var cursors [][2]string
				w := terminalResetWindow(Values{Language: language.Code(), Theme: theme, TerminalScrollback: 50000, TerminalCursorShape: CursorShapeBar, TerminalCursorThickness: CursorThicknessThick}, language, theme == "dark", &scrollbacks, &cursors)
				config := w.config()
				config.Height = 1000
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				d.until("offline shell facts", func() bool { return w.terminal.loaded })
				prefix := "terminal-reset-" + theme + "-" + language.Code()
				if err := session.Screenshot(filepath.Join(out, prefix+"-before.png")); err != nil {
					t.Fatal(err)
				}
				d.click(w.text.Settings.RestoreDefaults)
				d.pump()
				// Finish widget transitions on the virtual frame clock before recording pixels.
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				assertTerminalDefaults(t, w, d, scrollbacks, cursors)
				if err := session.Screenshot(filepath.Join(out, prefix+"-after.png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
