//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBranchDelete captures deleting branches from the Git log's branches pane (issue
// #2184): the confirmation of one remote branch, the menu of rows marked together and the
// confirmation of the marked branches, which leaves HEAD and the current branch out.
func TestVisualBranchDelete(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"remote-dialog", "marked-menu", "marked-dialog"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				dir := newTestRepository(t)
				gitRun(t, dir, "commit", "-am", "second")
				gitRun(t, dir, "remote", "add", "origin", t.TempDir())
				for _, name := range []string{"main", "feature"} {
					gitRun(t, dir, "update-ref", "refs/remotes/origin/"+name, "HEAD")
				}
				gitRun(t, dir, "branch", "--set-upstream-to=origin/main", "main")
				gitRun(t, dir, "branch", "one")
				gitRun(t, dir, "branch", "two")
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
				if scene == "remote-dialog" {
					h.logRefMenu("origin/feature")
					h.click(center(h.popupHit(h.app.text.Branch.Delete)))
				} else {
					h.markLogRefs("one", "two", "origin/feature", "main", "HEAD")
					label := i18n.SharedFormat(h.app.language(), "desktop.branch.deleteSelected", map[string]string{"count": "3"})
					h.rightClickAt(h.topHit(h.app.logView.refs.RowID(h.logRefRowOf("two"))))
					if scene == "marked-dialog" {
						h.click(center(h.popupHit(label)))
					} else if !h.hasPopupItem(label) {
						t.Fatalf("the menu of a marked row has no %q", label)
					}
				}
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "branch-delete-"+scene+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
