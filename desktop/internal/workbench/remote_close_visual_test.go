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
	"github.com/vivaui/viva/headless"
)

// TestVisualRemoteClose captures closing a remote workspace whose host still runs a terminal and a
// process of it: the question with the programs, Remember my choice and its help; the notice once
// they are kept on the host; on the next connection, the offer to end the kept programs or show
// the process in the Run window; and the Run tab that receives the kept process again.
func TestVisualRemoteClose(t *testing.T) {
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
				if err := session.Screenshot(filepath.Join(out, "remote-close-"+scene+"-"+look.suffix+".png")); err != nil {
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
			h.openRemoteTestProject(t)
			kernel.set(func(k *remoteHostKernel) { k.close.running = remoteTestPrograms })

			h.closeQuestion(t)
			// The pointer rests on the default action, as after a click on the window's close button.
			shot("question")
			h.answer(1)
			h.awaitClosed(t)
			shot("kept")
			h.app.clearNotifications()

			kernel.set(func(k *remoteHostKernel) { k.close.running = nil })
			h.app.openRemote(surfaceMenu)
			h.settleChain()
			p := h.openRemoteTestProject(t)
			h.await("the offer to end the kept programs", func() bool { return len(h.app.prompts.queue) == 1 })
			shot("offer")
			if h.app.prompts.queue[0].title != i18n.Shared(h.app.language(), "desktop.remote.kept.title") {
				t.Fatal("the offer to end the kept programs is not shown")
			}

			// Show in Run Window receives the kept process, which goes on running, in a Run tab.
			kernel.setRuns(func(r *remoteHostRuns) {
				r.hold, r.signalled = true, make(chan struct{})
				r.attachOutput = "  VITE ready in 312 ms\n\n  ➜  Local:   http://localhost:5173/\n"
			})
			attach := 1
			h.app.answerPrompt(&attach)
			h.await("the kept process's output in its Run tab", func() bool {
				op := p.build.runOf("remote-attach:7")
				return op != nil && op.session != nil && strings.Contains(op.session.output.all(), "VITE ready")
			})
			// The pointer leaves the dialog's buttons, whose highlight would stay.
			if err := h.driver.Move(800, 300); err != nil {
				t.Fatal(err)
			}
			h.app.invalidator.Invalidate()
			for range 3 {
				if err := h.driver.Pump(); err != nil {
					t.Fatal(err)
				}
			}
			if err := session.Screenshot(filepath.Join(out, "remote-close-attached-"+look.suffix+".png")); err != nil {
				t.Fatal(err)
			}
			// The process ends before the window closes, which waits for every run.
			kernel.setRuns(func(r *remoteHostRuns) { close(r.signalled) })
			h.awaitRemoteRun(p, "npm", nil)
		})
	}
}
