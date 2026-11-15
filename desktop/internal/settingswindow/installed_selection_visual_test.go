//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualInstalledSelection renders the Installed list of three plugins whose IDs all hash
// past 2^31 after a click on the middle row, which the list has to show as chosen. Opt in
// with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualInstalledSelection(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the Installed list selection")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	facts := []PluginFacts{
		{ID: "dev.lithe.test.first", Name: "First Fixture", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk},
		{ID: "dev.lithe.test.second", Name: "Second Fixture", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk},
		{ID: "dev.lithe.test.third", Name: "Third Fixture", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk},
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		t.Run(look.theme, func(t *testing.T) {
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language },
				SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" },
				Marketplace:      func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
				InstalledPlugins: func() []PluginFacts { return facts },
				PluginState:      func(string) PluginState { return PluginState{Installed: true, Version: "1.0.0", Enabled: true} },
			}), Values{Theme: look.theme, Language: look.language.Code()})
			w.sess.page = pagePlugins
			session, err := headless.Open(w.config(), nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the marketplace index", func() bool { return w.market.status == marketReady })
			d.pump()
			var middle gfx.Hit
			for _, hit := range d.driver.Snapshot().Hits {
				if hit.Label == facts[1].Name && hit.Role == gfx.RoleOption {
					middle = hit
				}
			}
			if middle.Label == "" {
				t.Fatalf("no row %q", facts[1].Name)
			}
			d.clickHit(middle)
			d.until("the middle row chosen", func() bool { return w.installed.selected == facts[1].ID })
			if err := session.Screenshot(filepath.Join(out, "installed-selection-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
