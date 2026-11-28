//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualWelcomeRecentProjects(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, scene := range []struct{ theme, language string }{{"light", "zh-Hans"}, {"dark", "en-US"}} {
		t.Run(scene.theme+"-"+scene.language, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": scene.theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{scene.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1000, 640
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			base := t.TempDir()
			h.app.welcome.home, h.app.welcome.homeRead = base, true
			ctx, cancel := context.WithTimeout(context.Background(), remoteReadTimeout)
			defer cancel()
			source, err := remoteconn.Read(ctx, h.app.kernel, h.app.globalToolchainRoot())
			if err != nil {
				t.Fatal(err)
			}
			_, savedID, _, err := source.Edit(ctx, h.app.kernel, core.RemoteConnectionEdit{Save: &core.RemoteConnectionSave{
				Name: "West Lab", Connection: core.SSHConnection{Host: "west.example"},
			}})
			if err != nil {
				t.Fatal(err)
			}
			legacyKey := fmt.Sprintf("remote:%d:%s/projects/Beacon", len(savedID), savedID)
			atlas := welcomeRecentDir(t, base, "Atlas")
			h.seedRecent([]core.RecentProject{
				{Path: atlas, LastOpenedAt: 2, Pinned: true, Tags: []string{"Research", "Work"}},
				{Path: welcomeRecentDir(t, base, "Notebook"), LastOpenedAt: 3, Tags: []string{"Personal"}},
				{Path: legacyKey, LastOpenedAt: 4, Tags: []string{"Work"}, Remote: &core.RecentRemoteProject{
					ConnectionID: savedID, Name: "West Lab", Folder: "/projects/Beacon", SSHConnectionID: savedID,
				}},
			})
			if err := h.driver.Resize(1000, 640); err != nil {
				t.Fatal(err)
			}
			h.settle()
			save := func(name string) {
				t.Helper()
				if err := session.Screenshot(filepath.Join(out, "welcome-"+name+"-"+scene.theme+"-"+scene.language+".png")); err != nil {
					t.Fatal(err)
				}
			}
			save("recent")
			h.clickNamed(i18n.Shared(h.app.language(), "desktop.welcome.filterTags"))
			h.clickNamed("Work")
			save("filtered")
			h.rightClickRow(h.app.recent[0].Path)
			h.clickNamed(i18n.Shared(h.app.language(), "desktop.welcome.editTags"))
			save("tag-editor")
			lang := h.app.language()
			h.app.changeRecent(core.SetRecentTags(atlas, []string{"Updated", "Work"}), nil)
			h.settle()
			h.app.welcome.tagEdit.field.SetText("Research, Draft")
			h.redraw()
			h.clickNamed(i18n.Shared(lang, "ui.save"))
			h.settle()
			if !h.app.welcome.tagEdit.conflict {
				t.Fatal("the saved tags did not trigger a conflict")
			}
			save("tag-conflict")
			h.clickNamed(i18n.Shared(lang, "desktop.git.cancel"))

			h.clickNamed("Beacon")
			h.await("SSH history rejection", func() bool { return h.app.remote.err != "" })
			h.settle()
			if h.app.remote.err != i18n.Shared(lang, "desktop.welcome.recentSSHTargetChanged") {
				t.Fatalf("unexpected SSH history refusal: %s", h.app.remote.err)
			}
			save("ssh-history-rejected")
		})
	}
}
