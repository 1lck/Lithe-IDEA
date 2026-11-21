//go:build vivahead && lithevisual

package settingswindow

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualTrustedLocations renders the Trusted Locations page under Tools: the saved list with
// the remote workspace records under their connections, then a draft that adds a folder, one that
// removes a folder, Core's refusal of a filesystem root and a removed remote record. The folders
// and hosts are fictional; the loader is the tests' fake.
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
				loader := &fakeRemoteTrustLoader{}
				loader.fakeLocationsLoader.set(work, studies)
				loader.set(core.RemoteWorkspaceTrustTarget{
					Target:               json.RawMessage(`{"hops":[{"ssh":{"destination":"build.example.com","user":"dev"}}]}`),
					Label:                "Build server",
					TrustedWorkspaces:    []string{"/home/dev/services/api"},
					DistrustedWorkspaces: []string{"/home/dev/downloads/sample"},
				}, core.RemoteWorkspaceTrustTarget{
					Target:           json.RawMessage(`{"hops":[{"ssh":{"destination":"lab.example.com","port":2222}},{"container":{"engine":"docker","program":"docker","container":"web"}}]}`),
					TrustedLocations: []string{"/workspace"},
				})
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, SystemDark: func() bool { return theme == "dark" },
					Toolchains: loader,
				}), Values{Theme: theme, Language: language.Code()})
				w.sess.show(pageTrustedLocations)
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				l, r := w.toolchains.locations, w.toolchains.remote
				d.until("the trusted folders to load", func() bool { return l.loaded && !l.busy() && r.loaded && !r.busy() })
				d.pump()
				shot := func(state string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, "trusted-locations-"+state+"-"+theme+"-"+language.Code()+".png")); err != nil {
						t.Fatal(err)
					}
				}
				// Pump paints only what was invalidated, so wait for the list's first folder to be
				// on the screen.
				d.until("the saved list to be painted", func() bool { return d.text(work) && d.text("Build server") })
				shot("list")
				d.changeLocation(l, sandbox, true)
				d.changeLocation(l, studies, false)
				d.changeLocation(l, "/", true)
				d.removeRemoteRecords(1)
				if l.drafts() != 2 || l.refused == nil || r.drafts() != 1 {
					t.Fatalf("drafts = %d, refused = %v, remote drafts = %d", l.drafts(), l.refused, r.drafts())
				}
				shot("drafts")
			})
		}
	}
}
