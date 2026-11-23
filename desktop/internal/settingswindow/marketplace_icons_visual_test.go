//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualMarketplaceSVG renders the production market with synthetic,
// offline SVG bytes. Loading, missing and refused icons retain their initials;
// the loaded SVG replaces the row and detail avatars in both themes/languages.
func TestVisualMarketplaceSVG(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture marketplace SVG icons")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"light", "dark"} {
			t.Run(language.Code()+"-"+theme, func(t *testing.T) {
				url := "https://raw.githubusercontent.com/example/icons/main/brand.svg"
				broken := "https://raw.githubusercontent.com/example/icons/main/broken.svg"
				plugins := []core.MarketplacePlugin{
					{ID: "dev.lithe.test.market-brand", Name: "Brand Icon", Author: "Example", Icon: &url, Description: "Synthetic marketplace entry for SVG presentation.", LatestVersion: "1.0.0"},
					{ID: "dev.lithe.test.market-absent", Name: "Fallback Example", Author: "Example", LatestVersion: "1.0.0"},
					{ID: "dev.lithe.test.market-broken", Name: "Broken Icon", Author: "Example", Icon: &broken, LatestVersion: "1.0.0"},
				}
				release := make(chan struct{})
				var once sync.Once
				t.Cleanup(func() { once.Do(func() { close(release) }) })
				w := marketIconFixture(plugins, func(ctx context.Context, address string) (gfx.Icon, error) {
					if strings.HasSuffix(address, "broken.svg") {
						return pluginicons.CompileSVG("marketplace.svg", []byte(`<svg><script/></svg>`))
					}
					select {
					case <-release:
						return pluginicons.CompileSVG("marketplace.svg", []byte(marketTestSVG))
					case <-ctx.Done():
						return gfx.Icon{}, ctx.Err()
					}
				}, nil)
				w.ctrl.opts.Language = func() i18n.Language { return language }
				w.ctrl.opts.Text = func() *i18n.Messages { return i18n.For(language) }
				w.sess.values.Theme = theme
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				name := "marketplace-svg-" + language.Code() + "-" + theme
				if err := session.Screenshot(filepath.Join(out, name+"-loading.png")); err != nil {
					t.Fatal(err)
				}
				once.Do(func() { close(release) })
				waitForMarketIconFrame(d, "the SVG and fallback icons", func() bool {
					loaded := w.marketIcons.entries[url]
					failed := w.marketIcons.entries[broken]
					return loaded != nil && loaded.done && failed != nil && failed.done
				})
				if !d.text("FE") {
					t.Fatal("the entry without an SVG lost its fallback")
				}
				if err := session.Screenshot(filepath.Join(out, name+"-loaded.png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
