//go:build vivahead && lithevisual

package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/searchprefs"
	"github.com/vivaui/viva/headless"
	"os"
	"path/filepath"
	"testing"
)

func TestVisualSearchPreferences(t *testing.T) {
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
				w := newWindow(NewController(Options{SearchPreferences: searchprefs.Source{Root: t.TempDir()}, Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language }, SystemLanguage: language, SystemDark: func() bool { return theme == "dark" }}), Values{Language: language.Code(), Theme: theme})
				w.sess.page = pageSearch
				config := w.config()
				config.Width, config.Height = 1120, 820
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				waitSearchPage(t, d, func() bool { return w.searchDraft.ready && !w.searchDraft.busy })
				d.pump()
				if err := session.Screenshot(filepath.Join(out, "search-settings-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
