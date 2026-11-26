//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// This explicitly enabled integration scene uses this computer's actual daemon discovery.
// The empty workspace is real; no engine, container or configuration data is substituted.
func TestVisualDevcontainerActualRuntimeAndBasicForm(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" || os.Getenv("LITHE_TEST_CONTAINER_RUNTIMES") != "1" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR and LITHE_TEST_CONTAINER_RUNTIMES=1 for real engine discovery")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Second)
	defer cancel()
	client := core.NewClient()
	runtimes, err := client.RemoteContainerRuntimes(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(runtimes.Runtimes) == 0 {
		t.Fatal("no actual container runtime was found")
	}
	for _, runtime := range runtimes.Runtimes {
		t.Logf("actual runtime: %s; ready=%t; context=%s; WSL=%s", runtime.Label, runtime.Available, runtime.Context, runtime.WSL)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"en-US", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: client}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 820
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.app.openRemote(surfaceMenu)
				h.settleChain()
				// The container list stays read-only and only this explicit scene probes real runtimes.
				h.app.remote.containers.runtimes, h.app.remote.containers.discovered = runtimes, true
				h.app.openRemoteDevcontainer()
				d := h.app.remote.devcontainer
				folder := t.TempDir()
				d.folder.SetText(folder)
				h.app.readRemoteDevcontainer()
				awaitRemoteDevcontainerRead(t, h)
				shot := func(state string) {
					t.Helper()
					h.redraw()
					h.settleChain()
					if err := session.Screenshot(filepath.Join(out, "devcontainer-"+state+"-"+theme+"-"+language+".png")); err != nil {
						t.Fatal(err)
					}
				}
				if d.err != "" || !d.create {
					t.Fatalf("empty folder has no form: %q", d.err)
				}
				shot("image-form")
				h.clickFront(i18n.Shared(h.app.language(), "desktop.remote.devcontainer.runtime"))
				shot("runtimes")
				// Escape closes the actual picker before changing the source using its shared control.
				if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
					t.Fatal(err)
				}
				h.settle()
				d.source = "dockerfile"
				shot("dockerfile-form")
				if err := h.driver.Scroll(gfx.ScrollEvent{X: 900, Y: 500, DeltaY: 700, Precise: true}); err != nil {
					t.Fatal(err)
				}
				shot("advanced-form")
				if !h.shows(i18n.Shared(h.app.language(), "desktop.remote.devcontainer.form.ports")) {
					t.Fatal("scrolled form has no port field")
				}
			})
		}
	}
}
