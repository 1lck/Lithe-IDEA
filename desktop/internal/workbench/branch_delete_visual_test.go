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
	"github.com/vivaui/viva/gfx"
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
		for _, scene := range []string{"remote-dialog", "marked-menu", "marked-dialog", "unmerged-warning", "force-confirmation", "mixed-result", "mixed-result-deferred", "tree-selection"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				dir := newTestRepository(t)
				writeTreeFiles(t, dir, "selection-a.txt", "selection-b.txt")
				gitRun(t, dir, "commit", "-am", "second")
				gitRun(t, dir, "remote", "add", "origin", t.TempDir())
				for _, name := range []string{"main", "feature"} {
					gitRun(t, dir, "update-ref", "refs/remotes/origin/"+name, "HEAD")
				}
				gitRun(t, dir, "branch", "--set-upstream-to=origin/main", "main")
				gitRun(t, dir, "branch", "one")
				gitRun(t, dir, "branch", "two")
				if scene == "unmerged-warning" || scene == "force-confirmation" || scene == "mixed-result" || scene == "mixed-result-deferred" {
					makeUnmergedBranch(t, dir, "backup/before-strip-trailers")
				}
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
				if scene == "tree-selection" {
					p := h.app.project
					h.app.reduceChrome(core.SetChromeOpen(itemProject, true))
					h.settleChain()
					h.await("tree files loaded", func() bool { return p.tree.root != nil && p.tree.root.listed })
					h.settleChain()
					// Real pointer clicks: plain click followed by the platform's primary modifier.
					var files []string
					for _, n := range p.tree.rows {
						if n.path != "" && !n.dir {
							files = append(files, n.path)
						}
					}
					if len(files) < 2 {
						t.Fatal("tree fixture has fewer than two files")
					}
					h.click(center(h.treeRowHit(files[0]).Bounds))
					h.settleChain()
					key := gfx.KeyControlLeft
					if primaryModifier() == gfx.ModifierMeta {
						key = gfx.KeyMetaLeft
					}
					if err := h.driver.KeyDown(key, ""); err != nil {
						t.Fatal(err)
					}
					h.click(center(h.treeRowHit(files[1]).Bounds))
					if err := h.driver.KeyUp(key, ""); err != nil {
						t.Fatal(err)
					}
				} else if scene == "mixed-result" || scene == "mixed-result-deferred" {
					h.markLogRefs("one", "backup/before-strip-trailers", "origin/feature")
					h.clickNamed(h.app.text.Git.DeleteBranch)
					confirm := h.app.text.Branch.DeleteButton
					if scene == "mixed-result-deferred" {
						k := startPendingGitDeletion(t, h, confirm)
						openBranchDraftDuringGitDeletion(t, h)
						close(k.release)
						h.await("deferred deletion result", func() bool { return !h.app.branch.busy })
						finishBranchDraftAfterGitDeletion(t, h)
						openGitDeletionNotice(t, h)
					} else {
						h.click(center(h.popupHit(confirm)))
						h.await("mixed deletion result", func() bool { return !h.app.branch.busy })
					}
				} else if scene == "remote-dialog" {
					h.logRefMenu("origin/feature")
					h.click(center(h.popupHit(h.app.text.Branch.Delete)))
				} else if scene == "unmerged-warning" || scene == "force-confirmation" {
					h.logRefMenu("backup/before-strip-trailers")
					h.click(center(h.popupHit(h.app.text.Branch.Delete)))
					h.click(center(h.popupHit(h.app.text.Branch.DeleteButton)))
					h.await("unmerged warning", func() bool { return !h.app.branch.busy })
					h.settleChain()
					if h.app.branch.dialog != branchDialogDeleteUnmerged {
						t.Fatal("Core did not refuse the unmerged branch")
					}
					if scene == "force-confirmation" {
						h.click(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.branch.reviewForceDelete"))))
					}
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
