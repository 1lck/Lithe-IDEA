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
// with the color strip of the repository it walks, the Paths filter's Roots, and the Commit
// window's groups.
func TestVisualWorkspaceRepositories(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		for _, scene := range []string{"branch-popup", "git-log", "log-roots", "commit-groups"} {
			t.Run(scene+"-"+look.theme, func(t *testing.T) {
				parent := newWorkspaceFolder(t, "backend", "frontend", "shared")
				frontend, backend := filepath.Join(parent, "frontend"), filepath.Join(parent, "backend")
				for _, message := range []string{"Add the sign-in form", "Validate the email field", "Show the session banner"} {
					gitRun(t, backend, "commit", "--allow-empty", "-m", message)
				}
				gitRun(t, backend, "branch", "feature/login")
				gitRun(t, backend, "branch", "release/1.0")
				gitRun(t, frontend, "branch", "feature/theme")
				gitRun(t, frontend, "switch", "-c", "develop")
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
				case "git-log", "log-roots":
					h.app.layout.gitTab = gitTabLog
					if !h.app.chrome.isOpen(catalogIndex[itemGit]) {
						h.click(center(h.button(itemGit)))
					}
					backendID := repositoryID(t, p, "backend")
					h.settleUntil("backend's history", func() bool { return p.logRepoID() == backendID && !p.log.loading && len(p.log.graph.Rows) == 4 })
					if scene == "log-roots" {
						h.click(center(h.hitLabeled(h.app.text.Git.FilterPaths)))
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
