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
// ports by the addresses the host serves them on, with one forwarded on a free local port because
// its own was taken and a URL added by hand, the row's menu, the question a target outside the
// host's loopback interface asks, and the dialog a forward's local port is chosen in.
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
				{Address: "::", Port: 8080, PID: 41, Process: "node"},
				{Address: "127.0.0.1", Port: 5432, PID: 7, Process: "postgres"},
				{Address: "10.0.0.5", Port: 9000},
			}
			kernel.ports.taken = map[uint16]bool{8080: true}
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 960
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

			// Nothing is forwarded until asked: 8080, which the host serves on both families, is
			// forwarded on a free local port because another program uses its own, and a URL is
			// added by hand.
			for _, row := range ports.rows() {
				if row.key.port == 8080 {
					h.app.forwardRemotePort(p, row.key, row.target(), false, surfaceButton)
				}
			}
			h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
			ports.add.SetText("http://localhost:5173/app")
			h.app.addRemotePort(p, surfaceButton)
			h.await("the added URL's forward", func() bool { return len(ports.forwards) == 2 && len(ports.busy) == 0 })
			shot("list")

			both := i18n.SharedFormat(lang, "desktop.remote.ports.remoteMore", map[string]string{"address": "0.0.0.0:8080", "count": "1"})
			h.rightClickAt(h.portRowControl(both, both))
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
			ports.local, ports.localOpen = nil, false
			h.settleChain()

			// Forwarding rules listen on the host: one reaches another server, one listens on every
			// interface, and one brings a host port back to this computer.
			kernel.set(func(k *remoteHostKernel) { k.ports.rules.allowReverse = true })
			addRule := func(kind remotePortRuleKind, listen, target string, all bool) {
				t.Helper()
				h.app.openRemotePortRule(p, nil, surfaceToolbar)
				h.settleChain()
				draft := ports.rule
				draft.kind, draft.allInterfaces = kind, all
				draft.listen.SetText(listen)
				draft.target.SetText(target)
				h.app.submitRemotePortRule(p, surfaceButton)
				for range 2 {
					h.await("the rule", func() bool {
						return ports.rule != draft || (!draft.starting && draft.confirm != remotePortRuleNoConfirm)
					})
					if ports.rule != draft {
						return
					}
					h.app.confirmRemotePortRule(p, surfaceButton)
				}
				h.await("the confirmed rule", func() bool { return ports.rule != draft })
			}
			addRule(remotePortRuleHost, "15432", "db.internal:5432", false)
			addRule(remotePortRuleHost, "9200", "http://search.internal:9200", true)
			addRule(remotePortRuleReverse, "", "3000", false)
			if len(ports.rules()) != 3 {
				t.Fatalf("%d rules started, want 3", len(ports.rules()))
			}
			shot("rules")

			h.app.openRemotePortRule(p, nil, surfaceToolbar)
			h.settleChain()
			draft := ports.rule
			draft.allInterfaces = true
			draft.listen.SetText("8000")
			draft.target.SetText("10.0.0.8:8000")
			shot("rule")
			h.app.submitRemotePortRule(p, surfaceButton)
			h.await("the question", func() bool { return !draft.starting && draft.confirm == remotePortRuleConfirmAll })
			shot("rule-confirm")
			ports.rule, ports.ruleOpen = nil, false
			h.settleChain()

			// The user names rows and rules; the window remembers them with the forwards left
			// running and the rules, and lists them again when the workspace opens again.
			label := func(target remotePortLabelTarget, text string, scene string) {
				t.Helper()
				h.app.editRemotePortLabel(p, target, surfaceContextMenu)
				h.settleChain()
				ports.labelField.SetText(text)
				if scene != "" {
					shot(scene)
				}
				h.app.applyRemotePortLabel(p)
				h.await("the port records", func() bool { return !ports.recordsBusy })
			}
			label(remotePortLabelTarget{key: &remotePortKey{port: 8080}}, "Web UI", "label")
			label(remotePortLabelTarget{key: &remotePortKey{port: 5432}}, "Database", "")
			tunnel := remotePortRuleOf(ports.rules()[0])
			label(remotePortLabelTarget{rule: &tunnel}, "DB tunnel", "")
			shot("labels")

			h.app.closeProject()
			h.awaitClosed(t)
			h.app.openRemote(surfaceMenu)
			h.settleChain()
			p = h.openRemoteTestProject(t)
			h.app.openToolWindow(itemPorts)
			h.redraw()
			ports = &p.remote.ports
			h.await("the remembered forwards", func() bool { return ports.listed && !ports.recordsBusy && len(ports.forwards) == 2 })
			if len(ports.idleRules()) != 3 {
				t.Fatalf("%d remembered rules, want 3", len(ports.idleRules()))
			}
			shot("remembered")
		})
	}
}
