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

// TestVisualTrackingBranchMenu captures the tracking branch submenu of the Git log's reference
// menu over a repository with two remotes whose branch names have several "/" parts: the
// submenu itself, and the folders origin and codex opened in it.
func TestVisualTrackingBranchMenu(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	remotes := []string{
		"contributor/main",
		"contributor/feat/windows-run-panel",
		"contributor/fix/activity-rail-gutter",
		"contributor/fix/export-logs-layout",
		"origin/main",
		"origin/preview",
		"origin/bot/issue-1216-maven-jdk",
		"origin/build/core-pin-6477e9a",
		"origin/chore/rust-toolchain-1-100",
		"origin/chore/viva-upstream-sync-2026-11-15",
		"origin/codex/fix-1843-plugin-uninstall-lifecycle",
		"origin/codex/go-lsp-sdk-management",
		"origin/codex/ide-essentials",
		"origin/codex/issue-1143-ci-classification",
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []struct {
			id      string
			folders []string
		}{
			{"tracking-menu", nil},
			{"tracking-menu-origin-codex", []string{"origin", "codex"}},
		} {
			t.Run(scene.id+"-"+look.theme, func(t *testing.T) {
				dir := newTestRepository(t)
				gitRun(t, dir, "commit", "-am", "second")
				for _, remote := range []string{"origin", "contributor"} {
					gitRun(t, dir, "remote", "add", remote, t.TempDir())
				}
				for _, name := range remotes {
					gitRun(t, dir, "update-ref", "refs/remotes/"+name, "HEAD")
				}
				gitRun(t, dir, "branch", "--set-upstream-to=origin/main", "main")
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: gitKernel{core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.openLog(t, dir)
				h.logRefMenu("main")
				h.click(center(h.popupHit(h.shared("native.trackingBranch"))))
				for _, folder := range scene.folders {
					h.click(center(h.popupHit(folder)))
				}
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, scene.id+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
