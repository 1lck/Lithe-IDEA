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

func TestVisualGitDeletionInProgress(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"remote-branch", "worktree", "worktree-deferred-review", "worktree-replacement"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				dir, linked := newWorktreeRepository(t)
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language}); err != nil {
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

				capture := func(name string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, name+"-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
				}
				if scene == "worktree-deferred-review" || scene == "worktree-replacement" {
					k, w := startDirtyWorktreeRemovalWithBranchDraft(t, h, dir, linked)
					close(k.release)
					h.await("worktree removal result", func() bool { return !w.busy })
					if scene == "worktree-deferred-review" {
						capture("worktree-draft-and-notice")
					}
					finishBranchDraftAfterGitDeletion(t, h)
					if scene == "worktree-replacement" {
						replaceReviewedWorktree(t, dir, linked)
						openGitDeletionNotice(t, h)
						message := i18n.Shared(h.app.language(), "desktop.worktree.removeSelectionChanged")
						h.await("stale removal notification", func() bool { return lastNotice(h) == message })
						if w.dialog != worktreeDialogNone {
							t.Fatal("a stale review opened a confirmation")
						}
						capture(scene)
						return
					}
					openGitDeletionNotice(t, h)
					h.clickNamed(h.app.text.Worktrees.ReviewForce)
					capture(scene)
					return
				}
				var confirm string
				switch scene {
				case "remote-branch":
					gitRun(t, dir, "remote", "add", "origin", t.TempDir())
					gitRun(t, dir, "update-ref", "refs/remotes/origin/obsolete", "HEAD")
					h.openLog(t, dir)
					h.logRefMenu("origin/obsolete")
					h.click(center(h.popupHit(h.app.text.Branch.Delete)))
					confirm = h.app.text.Branch.DeleteButton
				case "worktree":
					h.openWorktrees(t, dir)
					h.selectWorktreeAt(t, linked)
					h.clickNamed(h.app.text.Worktrees.Remove)
					confirm = h.app.text.Worktrees.RemoveButton
				}
				startPendingGitDeletion(t, h, confirm)
				capture(scene)
			})
		}
	}
}
