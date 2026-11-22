//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRemoteRun captures a built-in run configuration of a remote workspace that ran on the
// host after its before-launch step, another built-in run, ran there: the Run window's tab with
// the host badge, the step's header and both host processes' output, and the title bar's run
// configuration menu, which says build tools do not run in a remote workspace yet. Then the
// connection breaks while the configuration runs again: the tab waits for the workspace to connect
// again, and once the workspace resumes the host session it goes on with the process's output,
// after a line that says some of it was lost.
func TestVisualRemoteRun(t *testing.T) {
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
			zero := 0
			// Greet starts once Prepare, another built-in run, ran before it on the host.
			prepare := core.RunConfiguration{ID: "prepare", Name: "Prepare", Provider: runProviderShell}
			kernel.runs.configurations = []core.RunConfiguration{prepare, remoteTestRunConfiguration}
			kernel.runs.steps = []core.RunBeforeLaunchItem{{ConfigurationID: prepare.ID, Name: prepare.Name}}
			kernel.runs.exit = core.RemoteProcessExit{ExitCode: &zero}
			kernel.runs.plan = core.RunLaunchPlan{
				Executable:       core.RunPlanExecutable{Command: "sh"},
				WorkingDirectory: "src",
				InlineScript:     &core.RunInlineScript{Content: "echo hello from the host\n"},
			}
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
				if err := session.Screenshot(filepath.Join(out, "remote-run-"+scene+"-"+look.suffix+".png")); err != nil {
					t.Fatal(err)
				}
			}
			// shotRunning is shot while a run waits on the host, which settle would wait for.
			shotRunning := func(scene string) {
				t.Helper()
				h.app.invalidator.Invalidate()
				for range 3 {
					if err := h.driver.Pump(); err != nil {
						t.Fatal(err)
					}
				}
				if err := session.Screenshot(filepath.Join(out, "remote-run-"+scene+"-"+look.suffix+".png")); err != nil {
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
			h.app.post(func(a *App) { a.loadBuildSystems(p) })
			h.await("the remote workspace's run configurations", func() bool {
				return p.runConfigs.generation > 0 && !p.runConfigs.loading && len(p.runConfigs.list) == 2
			})
			h.app.chooseTitleConfiguration(p, remoteTestRunConfiguration.ID)
			h.app.openToolWindow(itemRun)
			h.startRemoteRun(p, remoteTestRunConfiguration.ID)
			run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
			h.await("the step's and the configuration's host output in the console", func() bool {
				return strings.Count(run.output.all(), "hello from the host") == 2
			})
			// The pointer leaves the title bar, whose tooltip would cover the console.
			if err := h.driver.Move(800, 300); err != nil {
				t.Fatal(err)
			}
			shot("console")

			h.app.openRunConfigMenu()
			h.settleChain()
			if !h.app.title.runConfigOpen {
				t.Fatal("the run configuration menu did not open")
			}
			shot("menu")
			h.app.title.runConfigOpen = false

			// Greet runs again, without its step, and the connection breaks while it runs.
			kernel.set(func(k *remoteHostKernel) { k.close.resumable = true })
			kernel.setRuns(func(r *remoteHostRuns) {
				r.steps = nil
				r.attachTruncated = true
				r.attachOutput = "hello again from the host\n"
			})
			op := h.startHeldRemoteRun(kernel, p)
			h.breakRunConnection(kernel, p, op)
			shotRunning("waiting")
			kernel.setRuns(func(r *remoteHostRuns) { r.hold = false })
			h.reconnectWhileRunning(t, timers, p.remote)
			again := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, run)
			if again.outcome != runSucceeded {
				t.Fatalf("the run ended %v after the reconnection", again.outcome)
			}
			shot("resumed")
		})
	}
}
