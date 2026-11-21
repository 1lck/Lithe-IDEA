//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualTrustedLocations renders the Trusted Locations page and its Build directory row:
// the saved list, then a draft that adds a folder, one that removes a folder and Core's refusal
// of a filesystem root. The folders are fictional; the loader is the tests' fake.
func TestVisualTrustedLocations(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the trusted locations page")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	const (
		work    = "/Volumes/Work/clients"
		studies = "/Users/example/Projects/studies"
		sandbox = "/Users/example/Sandbox/experiments"
	)
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"/"+theme, func(t *testing.T) {
				loader := &fakeLocationsLoader{}
				loader.set(work, studies)
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, SystemDark: func() bool { return theme == "dark" },
					Toolchains: loader,
				}), Values{Theme: theme, Language: language.Code()})
				w.sess.page = pageBuild
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				l := w.toolchains.locations
				d.until("the trusted folders to load", func() bool { return l.loaded && !l.busy() })
				d.pump()
				shot := func(state string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, "trusted-locations-"+state+"-"+theme+"-"+language.Code()+".png")); err != nil {
						t.Fatal(err)
					}
				}
				shot("directory")
				// Pump paints only what was invalidated, so wait for the list's first folder to be
				// on the screen; otherwise the shot repeats the directory page.
				w.openBuildChild(pageTrustedLocations)
				d.until("the saved list to be painted", func() bool { return d.text(work) })
				shot("list")
				d.changeLocation(l, sandbox, true)
				d.changeLocation(l, studies, false)
				d.changeLocation(l, "/", true)
				if l.drafts() != 2 || l.refused == nil {
					t.Fatalf("drafts = %d, refused = %v", l.drafts(), l.refused)
				}
				shot("drafts")
			})
		}
	}
}
