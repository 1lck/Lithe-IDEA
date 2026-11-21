//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualRemotePorts captures the Ports tool window of a remote workspace: the host's listening
// ports with one forwarded on a free local port because its own was taken and one added by hand,
// the row's menu, the question a target outside the host's loopback interface asks, and the
// dialog a forward's local port is chosen in.
func TestVisualRemotePorts(t *testing.T) {
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
			// The folder was kept in safe mode before, so it opens without the trust question.
			kernel.git.trust = map[string]string{remoteTestFolder: core.WorkspaceDistrusted}
			kernel.ports.listening = []core.RemoteListeningPort{
				{Address: "0.0.0.0", Port: 8080, PID: 41, Process: "node"},
				{Address: "127.0.0.1", Port: 5432, PID: 7, Process: "postgres"},
				{Address: "10.0.0.5", Port: 9000},
			}
			kernel.ports.taken = map[uint16]bool{8080: true}
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			lang := h.app.language()
			shot := func(scene string) {
				t.Helper()
				// The scenes set the window's state directly, which does not ask for a frame.
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "remote-ports-"+scene+"-"+look.suffix+".png")); err != nil {
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

			p := h.openRemoteTestProject(t)
			h.app.openToolWindow(itemPorts)
			h.redraw()
			ports := &p.remote.ports
			h.await("the Ports window's first reading", func() bool { return ports.listed || ports.readFailed != "" })
			if !ports.listed {
				t.Fatalf("reading the ports failed: %s", ports.readFailed)
			}

			// Nothing is forwarded until asked: 8080 is forwarded on a free local port because
			// another program uses its own, and 3000 is added by hand.
			for _, row := range ports.rows() {
				if row.key.port == 8080 {
					h.app.forwardRemotePort(p, row.key, row.target(), false, surfaceButton)
				}
			}
			h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
			ports.add.SetText("3000")
			h.app.addRemotePort(p, surfaceButton)
			h.await("the added port's forward", func() bool { return len(ports.forwards) == 2 && len(ports.busy) == 0 })
			shot("list")

			h.rightClickAt(h.portRowControl("8080", "8080"))
			h.settleChain()
			if !h.shows(i18n.Shared(lang, "desktop.remote.ports.changeLocal")) {
				t.Fatal("the row's menu did not open")
			}
			shot("menu")
			if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
				t.Fatal(err)
			}
			h.settleChain()

			for _, row := range ports.rows() {
				if row.key.host == "10.0.0.5" {
					h.app.forwardRemotePort(p, row.key, row.target(), false, surfaceButton)
				}
			}
			h.await("the question", func() bool { return ports.confirm != nil && len(ports.busy) == 0 })
			shot("confirm")
			ports.confirm = nil
			h.settleChain()

			h.app.chooseRemoteLocalPort(p, remotePortKey{port: 8080}, surfaceContextMenu)
			h.settleChain()
			if ports.local == nil {
				t.Fatal("the local port dialog did not open")
			}
			ports.localField.SetText("18080")
			shot("local")
		})
	}
}
