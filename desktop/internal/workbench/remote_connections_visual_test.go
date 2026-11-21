//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// remoteVisualKernel reports a fixed probe outcome instead of starting OpenSSH; everything else
// is the real Core.
type remoteVisualKernel struct {
	*core.Client
	result core.RemoteProbeResult
}

func (k *remoteVisualKernel) RemoteProbe(context.Context, core.SSHConnection) (core.RemoteProbeResult, error) {
	return k.result, nil
}

// TestVisualRemoteConnections captures the Remote Development window: two saved connections
// with the tested one's host report, a host Core refused under its field, and OpenSSH's password
// question over the window.
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
			kernel := &remoteVisualKernel{Client: core.NewClient(), result: probed}
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

			save := func(name, host, port, user, authentication, identityFile string) {
				t.Helper()
				r.selectNew()
				r.form.name.SetText(name)
				r.form.host.SetText(host)
				r.form.port.SetText(port)
				r.form.user.SetText(user)
				r.form.authentication = authentication
				r.form.identityFile.SetText(identityFile)
				h.app.saveRemote()
				h.settleChain()
				if r.err != "" || r.fieldErr.field != "" {
					t.Fatalf("saving %s: %q %+v", name, r.err, r.fieldErr)
				}
			}
			save("Lab ARM", "lab-arm.internal", "", "dev", core.RemoteAuthenticationAgent, "")
			save("Build box", "build.example", "2222", "dev", core.RemoteAuthenticationPrivateKey, "/home/me/.ssh/id_ed25519")
			h.app.testRemote()
			h.settleChain()
			if r.result == nil {
				t.Fatal("the test did not report")
			}
			shot("tested")

			r.selectNew()
			r.form.host.SetText("dev@build.example")
			h.app.saveRemote()
			h.settleChain()
			if r.fieldErr.field != "host" {
				t.Fatalf("refusal = %+v, want the host", r.fieldErr)
			}
			shot("refused")

			for _, entry := range r.source.Connections {
				if entry.Name == "Build box" {
					r.selectEntry(entry.ID)
				}
			}
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
