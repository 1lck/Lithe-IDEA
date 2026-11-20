//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/headless"
)

// TestVisualLanguagesPage renders the Languages & Frameworks page of synthetic plugins that
// contribute four language pages, whose language servers are in different states, the page
// while no plugin contributes one, and the page of one language opened from it. The real Core projects the pages. Opt in with
// -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualLanguagesPage(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the Languages & Frameworks page")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	states := map[string]string{"dev.example.go": "ready", "dev.example.python": "starting", "dev.example.rust": "failed"}
	for _, look := range []struct {
		name      string
		theme     string
		language  i18n.Language
		languages []string
		open      string
	}{
		{"languages-settings-dark", "dark", i18n.Chinese, []string{"go", "python", "rust", "typescript"}, ""},
		{"languages-settings-light", "light", i18n.English, []string{"go", "python", "rust", "typescript"}, ""},
		{"languages-settings-empty", "dark", i18n.Chinese, nil, ""},
		{"languages-settings-go-page-dark", "dark", i18n.Chinese, []string{"go", "python", "rust", "typescript"}, "dev.example.go"},
	} {
		t.Run(look.name, func(t *testing.T) {
			contributions := languagePageContributions(t, look.languages...)
			client := core.NewClient()
			w := newWindow(NewController(Options{
				Text: func() *i18n.Messages { return i18n.For(look.language) }, Language: func() i18n.Language { return look.language },
				SystemLanguage: look.language, SystemDark: func() bool { return look.theme == "dark" },
				PluginSettings:     newBuildFormSource(t, client, contributions),
				SettingsNavigation: client.SettingsNavigation,
				SettingsPages: func(ctx context.Context, _ i18n.Language) ([]core.SettingsPage, error) {
					return client.SettingsPages(ctx, contributions, "")
				},
				LanguageServerState: func(id string) string { return states[id] },
				Marketplace:         func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
			}), Values{Theme: look.theme, Language: look.language.Code()})
			w.sess.page = pageLanguages
			w.sess.open[pageLanguages] = true
			config := w.config()
			config.Height = 700
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the plugin pages", func() bool { return w.dynamic.loaded && len(w.dynamic.pages) == len(look.languages) })
			if look.open != "" {
				for _, page := range w.languagePages() {
					if page.Contributors[0].PluginID == look.open {
						w.selectSettingsPage(pageLanguages, page.Key)
					}
				}
				d.until("the opened page", func() bool { return w.dynamicPage != "" && w.pluginSettings.loaded && d.wrapped("Run checks") })
			}
			d.pump()
			if err := session.Screenshot(filepath.Join(out, look.name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
