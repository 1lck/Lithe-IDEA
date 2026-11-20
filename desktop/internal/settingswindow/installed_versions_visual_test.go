//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualInstalledVersions renders the Versions & Source, Overview and Permissions &
// Programs tabs of one marketplace plugin, the last both with its programs closed and with
// one opened. Opt in with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualInstalledVersions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the Versions & Source tab")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			w, fact, _ := detailFixture(look.language)
			w.sess.values.Theme = look.theme
			config := w.config()
			config.Width, config.Height = 1100, 720
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the marketplace index", func() bool { return w.market.status == marketReady })
			for _, tab := range []struct {
				name string
				tab  int
			}{{"versions", installedVersions}, {"overview", installedOverview}, {"permissions", installedPermissions}} {
				w.installed.tab = tab.tab
				w.inv.Invalidate()
				d.pump()
				if tab.tab == installedVersions {
					d.versionsLabelsKeepTheirWidth(look.language)
				}
				if err := session.Screenshot(filepath.Join(out, "installed-"+tab.name+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
			// The Permissions & Programs tab again, with its first program opened.
			w.installed.programsOpen = map[string]bool{programKey(fact, fact.Programs[0]): true}
			w.inv.Invalidate()
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "installed-permissions-open-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
