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

// TestVisualRemoteTreeMenu captures the remote workspace's Project tool window context menus for
// a file row and a folder row in both light/en-US and dark/zh-CN.
func TestVisualRemoteTreeMenu(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
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
			kernel.git.trust = map[string]string{remoteTestFolder: core.WorkspaceDistrusted}
			kernel.initRemoteFS(map[string]string{
				"README.md":   "# Remote\n",
				"src/main.go": "package main\n",
			}, "src")
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
				h.app.invalidator.Invalidate()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "remote-tree-menu-"+scene+"-"+look.suffix+".png")); err != nil {
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
			h.connectAndBrowse(t)
			h.clickFront("project")
			h.settleChain()
			h.clickFront(i18n.SharedFormat(h.app.language(), "desktop.remote.browse.open", map[string]string{"name": "project"}))
			h.await("the remote workspace's tree", func() bool {
				p := h.app.project
				return p != nil && p.remote != nil && !p.remote.beating && p.tree.root != nil && p.tree.root.listed && !p.tree.reading
			})

			h.rightClickNamed("README.md")
			shot("file")

			h.rightClickNamed("src")
			shot("dir")
		})
	}
}
