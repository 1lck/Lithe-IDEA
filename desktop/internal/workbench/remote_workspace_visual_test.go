//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRemoteWorkspace captures a remote workspace being opened: the host's home folder in
// the Remote Development window with a folder chosen, the question whether to trust it, the
// workspace it opened in safe mode with its notice and title bar host selector, the host menu,
// the connection, a host file open in the editor, the conflict a save over a change made on the
// host shows, a terminal running on the host, the host's search, and, once trusted, the Commit
// tool window of a folder inside a repository that starts above it.
func TestVisualRemoteWorkspace(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language, suffix string }{
		{"light", "en-US", "light-en-US"},
		{"dark", "zh-Hans", "dark-zh-CN"},
	} {
		t.Run(look.suffix, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			kernel := &remoteHostKernel{testKernel: &testKernel{Client: core.NewClient()}}
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			shot := func(scene string) {
				t.Helper()
				// The scenes set the window's state directly, which does not ask for a frame.
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "remote-workspace-"+scene+"-"+look.suffix+".png")); err != nil {
					t.Fatal(err)
				}
			}
			timers := &remoteTimers{}
			anchor := filepath.Join(t.TempDir(), remoteplaceholder.AnchorName)
			h.app.remoteBundle = func() (remoteserver.Bundle, error) {
				return remoteserver.Bundle{Version: "0.0.0-visual", Builds: []remoteserver.Build{{
					Target: "x86_64-unknown-linux-musl", Path: "/bundle/lithe-server", SHA256: strings.Repeat("0", 64),
				}}}, nil
			}
			h.app.remoteAnchor = func() (string, error) { return anchor, nil }
			h.app.remoteAfter = timers.start
			h.app.openRemote(surfaceMenu)
			h.settleChain()
			r := &h.app.remote
			r.selectNew()
			r.form.name.SetText("Build box")
			r.form.host.SetText(remoteTestHost)
			r.form.user.SetText("dev")
			h.app.saveRemote()
			h.settleChain()
			if r.err != "" || r.fieldErr.field != "" {
				t.Fatalf("saving the connection: %q %+v", r.err, r.fieldErr)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			source, err := remoteconn.Read(ctx, kernel, prefs.Dir())
			if err != nil {
				t.Fatal(err)
			}
			if _, _, _, err := source.Edit(ctx, kernel, core.RemoteConnectionEdit{Save: &core.RemoteConnectionSave{
				Name: "CI box", Connection: core.SSHConnection{Host: "ci.example", User: "runner", Port: 2222},
			}}); err != nil {
				t.Fatal(err)
			}
			kernel.set(func(k *remoteHostKernel) {
				k.wsl.list = core.RemoteWSLDistributions{Available: true, Distributions: []string{remoteTestWSL}}
				k.containers.running = map[string][]core.RemoteContainer{
					core.ContainerEngineDocker: {{ID: strings.Repeat("a", 64), Name: remoteTestContainer, Image: remoteTestImage}},
				}
			})

			b := h.connectAndBrowse(t)
			h.clickFront("project")
			h.settleChain()
			if b.target() != remoteTestHome+"/project" {
				t.Fatal("the project folder was not chosen")
			}
			shot("browse")

			// A folder never decided is asked about first; opening it in safe mode reads it only.
			h.clickFront(i18n.SharedFormat(h.app.language(), "desktop.remote.browse.open", map[string]string{"name": "project"}))
			h.await("the trust question", func() bool { return h.app.remote.trust != nil })
			shot("trust")
			h.clickFront(i18n.Shared(h.app.language(), "desktop.remote.trust.safeOpen"))
			h.await("the remote workspace's tree", func() bool {
				p := h.app.project
				return p != nil && p.remote != nil && !p.remote.beating && p.tree.root != nil && p.tree.root.listed && !p.tree.reading
			})
			shot("opened")

			h.openRemoteHostChoices(t)
			if !h.app.project.remote.menuOpen {
				t.Fatal("the connection's menu did not open")
			}
			shot("menu")
			h.app.closeRemoteHostMenu()
			h.settleChain()
			p := h.app.project
			for _, state := range []struct {
				link remoteLink
				name string
			}{{remoteUnresponsive, "unresponsive"}, {remoteReconnecting, "reconnecting"}, {remoteDisconnected, "disconnected"}} {
				p.remote.link = state.link
				shot(state.name)
			}
			p.remote.link = remoteConnected
			h.openRemoteHostChoices(t)
			h.clickFront(remoteTestContainer)
			h.await("the chosen container's folders", func() bool {
				return h.app.remote.browser != nil && !h.app.remote.browser.loading
			})
			shot("switch-folder")
			h.app.closeRemote()
			h.settleChain()

			// The host's README opens in the editor, and a save over a change made on the host
			// meanwhile is refused and shows the conflict.
			kernel.put(remoteTestReadme, "# Project\n\nBuilt and run on the host.\n")
			d := h.openRemoteFile(t, p, "README.md")
			if d == nil {
				t.Fatal("README.md did not open")
			}
			shot("file")
			kernel.put(remoteTestReadme, "# Project\n\nChanged on the host.\n")
			typeAtCaret(t, d, "Edited here. ")
			h.saveAndWait(t, p, d)
			if !d.conflicted {
				t.Fatal("the save over the host's change did not show the conflict")
			}
			shot("conflict")
			// Loading the host's version resolves the conflict, and clearing the notifications takes
			// down the refused save's toast, so the next scene shows the file as it is on the host.
			h.app.loadDocumentDisk(p, d)
			awaitDocumentState(t, h, func() bool { return !d.resolvingConflict })
			h.app.clearNotifications()

			// The Terminal tool window runs the host's login shell in the host folder, in a tab
			// named after the connection.
			term, run := h.openRemoteTerminal(t, kernel, p)
			run.echo <- []byte("uname -sm\r\nLinux x86_64\r\n" + remoteHostPrompt + " ")
			h.awaitTerminal(term, "Linux x86_64")
			// The pointer leaves the button it clicked, whose tooltip would cover the terminal.
			if err := h.driver.Move(800, 300); err != nil {
				t.Fatal(err)
			}
			shot("terminal")

			// Find in Files searches the host's folder, and Search Everywhere the host's file names
			// and text in every scope, not only actions.
			kernel.put(remoteTestNotes, "Release notes kept on the host.\n")
			h.app.searchView.delay = 0
			h.app.everywhereView.delay = 0
			h.app.openFindInFiles(p, false)
			h.app.searchView.query.SetText("host")
			h.await("the host's search results", func() bool {
				s := &p.search
				return !s.loading && !s.running && len(s.matches) == 2 && s.counts != nil && s.countCancel == nil
			})
			shot("search")
			h.app.openEverywhere(p)
			h.app.everywhereView.query.SetText("notes")
			h.await("the host's file name and text", func() bool {
				s := &p.everywhere
				return !s.loading && !s.running && len(s.matches) == 2
			})
			shot("everywhere")
			h.app.closeEverywhere(p)

			// Open File on Host lists the host's home folder, and a file outside the workspace's
			// folder opens read-only, the status bar naming its host path.
			kernel.put(remoteTestHome+"/notes.txt", "Notes kept outside the project.\n")
			h.app.openRemoteHostFiles(p, surfaceMenu)
			h.awaitHostListing(t, &p.remote.hostFiles)
			shot("host-file")
			p.remote.hostFiles.query.SetText("~/notes.txt")
			h.redraw()
			h.app.submitRemoteHostFiles(p, surfaceShortcut)
			outside := filepath.Join(p.root+remoteplaceholder.HostSuffix, "home", "dev", "notes.txt")
			awaitDocumentState(t, h, func() bool { _, opening := p.docs.opening[outside]; return p.docs.byPath(outside) != nil && !opening })
			shot("host-file-readonly")

			// Trusting the folder starts Git on the host; a repository that starts above the folder
			// leaves the Commit tool window empty and says why.
			kernel.set(func(k *remoteHostKernel) { k.git.repository = "above" })
			h.app.askToTrustProject(p, nil)
			// Asking does not ask for a frame.
			h.app.invalidator.Invalidate()
			h.settleChain()
			h.clickFront(i18n.Shared(h.app.language(), "desktop.trust.trustProject"))
			h.await("the host's status", func() bool { return p.git.remoteAbove })
			h.app.openToolWindow(itemCommit)
			shot("git-above")
		})
	}
}
