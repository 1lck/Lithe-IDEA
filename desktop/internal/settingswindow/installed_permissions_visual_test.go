//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualInstalledPermissions renders the Permissions & Programs tab of a plugin that holds
// every permission of the linked plugin contract, in Chinese on the dark theme and in English
// on the light theme, so each description can be read beside its permission's name. Opt in
// with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualInstalledPermissions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the Permissions & Programs tab")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	permissions := contractPermissions(t)
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			w, _, _ := detailFixture(look.language, func(opts *Options) {
				installed := opts.InstalledPlugins
				opts.InstalledPlugins = func() []PluginFacts {
					facts := installed()
					facts[0].Permissions = permissions
					return facts
				}
			})
			w.sess.values.Theme = look.theme
			config := w.config()
			config.Width, config.Height = 1100, 1760
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the marketplace index", func() bool { return w.market.status == marketReady })
			w.installed.tab = installedPermissions
			w.inv.Invalidate()
			last := permissions[len(permissions)-1]
			d.until("the last permission", func() bool { return d.text(last) })
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "installed-permissions-all-"+look.language.Code()+"-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
