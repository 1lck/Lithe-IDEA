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

// TestVisualWorkspaceRepositories captures the views of a folder that is no repository itself and
// holds three: the branch popup listing them with one's panel open beside its row, the Git log
// with the color strip of the repository it walks and each repository's own sections in the
// reference pane, the Paths filter's Roots, the repository list behind the name after the filter
// chips, the log of two repositories merged by date, and the Commit window's groups.
func TestVisualWorkspaceRepositories(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"branch-popup", "git-log", "log-roots", "log-choose", "log-merged", "log-more", "commit-groups"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				// Fixed dates, so the merged log interleaves the two repositories the same way
				// on every run.
				at := func(date string) {
					t.Setenv("GIT_AUTHOR_DATE", date)
					t.Setenv("GIT_COMMITTER_DATE", date)
				}
				at("2026-11-09T09:00:00")
				parent := newWorkspaceFolder(t, "backend", "frontend", "shared")
				frontend, backend := filepath.Join(parent, "frontend"), filepath.Join(parent, "backend")
				commit := func(dir, message, date string) {
					at(date)
					gitRun(t, dir, "commit", "--allow-empty", "-m", message)
				}
				commit(backend, "Add the sign-in form", "2026-11-10T09:30:00")
				commit(backend, "Validate the email field", "2026-11-11T10:15:00")
				commit(backend, "Show the session banner", "2026-11-12T16:40:00")
				gitRun(t, backend, "branch", "feature/login")
				gitRun(t, backend, "branch", "release/1.0")
				gitRun(t, frontend, "branch", "feature/theme")
				gitRun(t, frontend, "switch", "-c", "develop")
				commit(frontend, "Lay out the dashboard", "2026-11-10T14:00:00")
				commit(frontend, "Tune the dark palette", "2026-11-12T11:20:00")
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
				p := h.openWorkspaceFolder(parent)
				switch scene {
				case "branch-popup":
					h.click(center(h.hitLabeled(h.app.text.Title.BranchMenu)))
					label := i18n.SharedFormat(h.app.language(), "desktop.branch.repositoryPanel", map[string]string{"repository": "frontend", "branch": "develop"})
					h.click(center(h.popupHit(label)))
				case "git-log", "log-roots", "log-choose", "log-merged", "log-more":
					h.app.layout.gitTab = gitTabLog
					if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
						h.click(center(h.button(itemGit)))
					}
					backendID := repositoryID(t, p, "backend")
					h.settleUntil("backend's history", func() bool { return p.logRepoID() == backendID && !p.log.loading && len(p.log.graph.Rows) == 4 })
					h.relayLogBar()
					switch scene {
					case "log-roots":
						h.click(center(h.hitLabeled(h.app.text.Git.FilterPaths)))
					case "log-choose":
						h.click(center(h.hitLabeled(h.app.text.Git.Repositories.Choose)))
					case "log-merged":
						choose := h.app.text.Git.Repositories.Choose
						h.click(center(h.hitLabeled(choose)))
						label := i18n.SharedFormat(h.app.language(), "desktop.nested.rootToggle", map[string]string{"name": "frontend"})
						h.click(center(h.hitLabeled(label)))
						h.settleUntil("backend's and frontend's histories in one list", func() bool {
							return p.walksSeveral() && !p.log.loading && len(p.log.graph.Rows) == 7
						})
						h.click(center(h.hitLabeled(choose)))
						if p.log.popover != logPopoverNone {
							t.Fatalf("popover %v after clicking the repository name again", p.log.popover)
						}
						h.relayLogBar()
					case "log-more":
						h.click(center(h.hitLabeled(i18n.Shared(h.app.language(), "git.log.toolbar.moreActions"))))
					}
				case "commit-groups":
					h.click(center(h.button(itemCommit)))
				}
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "workspace-"+scene+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
