//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualSettingsGroups renders where the sidebar puts the Version Control, Build and Tools
// pages, with Version Control, Build and Tools expanded: the Version Control directory, the Git
// page, the Build directory, the Console page and the Trusted Locations page. Dark scenes are in
// Chinese, light ones in English. The loader is the tests' fake, so Trusted Locations is listed;
// only its own page loads it.
func TestVisualSettingsGroups(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the settings groups")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	scenes := []struct {
		name string
		page pageID
	}{
		{"version-control", pageVersionControl},
		{"git", pageGit},
		{"build", pageBuild},
		{"console", pageConsole},
		{"trusted-locations", pageTrustedLocations},
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
	}{{"dark", i18n.Chinese}, {"light", i18n.English}} {
		for _, scene := range scenes {
			t.Run(scene.name+"-"+look.theme, func(t *testing.T) {
				language := look.language
				loader := &fakeLocationsLoader{}
				loader.set("/Users/example/Projects")
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, SystemDark: func() bool { return look.theme == "dark" },
					Toolchains: loader,
				}), Values{Theme: look.theme, Language: language.Code()})
				w.sess.page = scene.page
				w.sess.open[pageAppearance] = false
				w.sess.open[pageVersionControl] = true
				w.sess.open[pageBuild] = true
				w.sess.open[pageTools] = true
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				if scene.page == pageTrustedLocations {
					l := w.toolchains.locations
					d.until("the trusted folders to load", func() bool { return l.loaded && !l.busy() })
				}
				d.pump()
				if err := session.Screenshot(filepath.Join(out, scene.name+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
