//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRemoteConnections captures the Remote Development window: saved connections under
// their groups with the tested one's overview, its form, a new connection whose host Core refused
// under its field, and OpenSSH's password question over the window.
func TestVisualRemoteConnections(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	const gib = uint64(1) << 30
	probed := core.RemoteProbeResult{
		Status: core.RemoteProbeConnected,
		Host: &core.RemoteProbedHost{
			System: "Linux", Machine: "x86_64", HomeDirectory: "/home/dev", ServerTarget: "x86_64-unknown-linux-musl",
			Details: core.RemoteHostDetails{
				HostName: "build", OperatingSystem: "Ubuntu 24.04.1 LTS", Kernel: "6.8.0-49-generic",
				CPUCount: 16, MemoryBytes: 64 * gib, DiskTotalBytes: 512 * gib, DiskAvailableBytes: 301 * gib,
			},
		},
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
			kernel := &remoteProbeKernel{Client: core.NewClient(), result: probed}
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
				if err := session.Screenshot(filepath.Join(out, "remote-connections-"+scene+"-"+look.suffix+".png")); err != nil {
					t.Fatal(err)
				}
			}
			h.app.openRemote(surfaceMenu)
			h.settleChain()
			r := &h.app.remote

			type saved struct {
				name, host, port, user, authentication, identityFile, proxyJump, group string
				color                                                                  core.RemoteConnectionColor
			}
			save := func(entry saved) {
				t.Helper()
				r.selectNew()
				r.form.name.SetText(entry.name)
				r.form.host.SetText(entry.host)
				r.form.port.SetText(entry.port)
				r.form.user.SetText(entry.user)
				r.form.authentication = entry.authentication
				r.form.identityFile.SetText(entry.identityFile)
				r.form.proxyJump.SetText(entry.proxyJump)
				r.form.color = entry.color
				r.form.group = remoteNewGroup
				r.form.newGroup.SetText(entry.group)
				h.app.saveRemote()
				h.settleChain()
				if r.err != "" || r.fieldErr.field != "" {
					t.Fatalf("saving %s: %q %+v", entry.name, r.err, r.fieldErr)
				}
			}
			save(saved{name: "Build box", host: "build.example", port: "2222", user: "dev", authentication: core.RemoteAuthenticationPrivateKey,
				identityFile: "/home/me/.ssh/id_ed25519", proxyJump: "bastion.example", group: "Production", color: core.RemoteConnectionRed})
			save(saved{name: "API gateway", host: "api.example", user: "deploy", authentication: core.RemoteAuthenticationAgent,
				group: "Production", color: core.RemoteConnectionOrange})
			save(saved{name: "Lab ARM", host: "lab-arm.internal", user: "dev", authentication: core.RemoteAuthenticationAgent,
				group: "Lab", color: core.RemoteConnectionGreen})
			save(saved{name: "Scratch VM", host: "10.0.4.17", authentication: core.RemoteAuthenticationAuto})
			buildBox := ""
			for _, entry := range r.source.Connections {
				if entry.Name == "Build box" {
					buildBox = entry.ID
				}
			}
			r.selectEntry(buildBox)
			h.app.testRemote()
			h.settleChain()
			if r.result == nil {
				t.Fatal("the test did not report")
			}
			shot("overview")

			h.app.editSelectedRemote()
			r.form.advanced.Open = true
			shot("edit")

			h.app.newRemote()
			r.form.host.SetText("dev@build.example")
			r.form.color = core.RemoteConnectionPurple
			r.form.group = remoteNewGroup
			r.form.newGroup.SetText("Experiments")
			h.app.saveRemote()
			h.settleChain()
			if r.fieldErr.field != "host" {
				t.Fatalf("refusal = %+v, want the host", r.fieldErr)
			}
			shot("refused")

			r.selectEntry(buildBox)
			done := make(chan struct{})
			h.app.gitAuth.queue = append(h.app.gitAuth.queue, core.GitAuthChallenge{
				RequestID: "visual", Prompt: "dev@build.example's password: ", Secret: true, Attempt: 1, Remote: true, Done: done,
			})
			shot("password")
			h.app.gitAuth.queue = nil
			close(done)
			h.app.closeRemote()
			h.settleChain()
		})
	}
}
