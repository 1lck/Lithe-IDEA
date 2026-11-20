//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualRunPorts captures dark and light Run window screenshots displaying live listening
// ports in both the active execution tab badge and the indented tree row with clickable pills.
func TestVisualRunPorts(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		t.Run(look.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			kernel := &testKernel{Client: core.NewClient()}
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1440, 900
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(t.TempDir())
			p := h.app.project
			h.app.post(func(a *App) {
				buildOp := a.beginBuildOperation(p, "build", "compile", "", func(*App, *project) {})
				feedBuildOutput(a, p, buildOp, "[INFO] Compiled 24 source files cleanly\n")
				a.finishBuildTask(p, buildOp, []byte(`{"exitCode":0}`))

				runOp := a.beginRunOperation(p, "WebServiceApplication", "web", configurationRunKey("web"), func(*App, *project) {})
				runOp.session.processRunning = true
				runOp.session.ports = []core.ListeningPort{
					{Port: 8080, Address: "0.0.0.0", Label: ":8080", URL: "http://localhost:8080", ProcessID: 1001},
					{Port: 9090, Address: "127.0.0.1", Label: ":9090", URL: "http://localhost:9090", ProcessID: 1001},
				}
				a.setOperationStatus(p, runOp, a.text.Build.Running)
				feedBuildOutput(a, p, runOp, strings.Join([]string{
					"INFO  WebServiceApplication : Starting web service...\n",
					"INFO  WebServiceApplication : HTTP server initialized on port 8080\n",
					"INFO  ManagementEndpoint    : Metrics exposed on 127.0.0.1:9090\n",
					"INFO  WebServiceApplication : Ready to accept connections\n",
				}, ""))
				a.showBuildConsole(p)
			})
			h.settleChain()
			h.app.invalidator.Invalidate()
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, "run-ports-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
