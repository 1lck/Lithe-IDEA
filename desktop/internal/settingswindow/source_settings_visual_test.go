//go:build vivahead && lithevisual

package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
	"os"
	"path/filepath"
	"testing"
)

func TestVisualNativeSettingsForm(t *testing.T) {
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
				source := nativeFormSource(t)
				w := nativeFormWindow(t, source, language, theme)
				config := w.config()
				config.Width, config.Height = 1120, 900
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				d.until("compiler page", func() bool { return len(w.dynamic.pages) == 1 })
				w.selectSettingsPage(pageBuild, "compiler:fictional")
				d.until("compiler settings action", func() bool {
					return w.pluginSettings.pageKey == w.dynamicPage && w.pluginSettings.loaded && len(w.pluginSettings.layout) > 0
				})
				d.click("Compiler settings")
				d.until("native compiler form", func() bool { return w.pluginSettings.sources != nil })
				d.pump()
				if err := session.Screenshot(filepath.Join(out, "native-settings-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
