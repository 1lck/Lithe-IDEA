//go:build vivahead && lithevisual

package settingswindow

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualRemoteWorkspace renders the Remote Workspace page under Tools: the automatic values as
// Core resolves them on this machine, then drafts that choose an SSH program and a reconnect time,
// and one that keeps the host's programs when a workspace closes.
// The preference directory is a test directory and the home directory is fictional.
func TestVisualRemoteWorkspace(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the remote workspace page")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.English, i18n.Chinese} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"/"+theme, func(t *testing.T) {
				loader := newCorePreferencesLoader(t)
				// Opening the page and drafting create nothing, so the fictional folders are never written.
				loader.home = "/Users/example"
				loader.root = "/Users/example/Library/Application Support/Lithe Desktop"
				w := newWindow(NewController(Options{
					Text: func() *i18n.Messages { return i18n.For(language) }, Language: func() i18n.Language { return language },
					SystemLanguage: language, SystemDark: func() bool { return theme == "dark" },
					Toolchains: loader,
				}), Values{Theme: theme, Language: language.Code()})
				w.sess.show(pageRemoteWorkspace)
				session, err := headless.Open(w.config(), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				r := w.toolchains.prefs
				d.until("the preferences to load", func() bool { return r.loaded && !r.busy() })
				d.pump()
				shot := func(state string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, "remote-workspace-"+state+"-"+theme+"-"+language.Code()+".png")); err != nil {
						t.Fatal(err)
					}
				}
				title := i18n.Shared(language, "desktop.remoteSettings.sshProgram")
				d.until("the page to be painted", func() bool { return d.text(title) })
				shot("automatic")
				program := "/opt/homebrew/bin/ssh"
				seconds := uint32(300)
				r.setProgram(&program)
				r.setLimit(&seconds)
				d.until("the drafts to be painted", func() bool { return d.text(program) })
				shot("drafts")
				// Closing a remote workspace keeps the host's programs instead of asking.
				keep := core.RemoteCloseKeep
				r.setClosing(&keep)
				d.w.inv.Invalidate()
				d.until("the closing draft to be painted", func() bool {
					return d.text(i18n.Shared(language, "desktop.remoteSettings.closeKeep"))
				})
				shot("closing")
			})
		}
	}
}
