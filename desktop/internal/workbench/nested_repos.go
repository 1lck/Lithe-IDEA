package workbench

import (
	"context"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file keeps the repositories nested in the project folder with their own changes
// (matrix ids git-multi-repository-change-groups, git-workspace-staged-commit). Core discovers
// them; the project reads each one's status in the background after every project status, so the
// Commit tool window can group their changes under the project's and count their staged changes
// toward the commit. The commit itself is planned by commit_nested.go. The window is declared in
// nested_repos_view.go.

// nestedRepo is one repository nested in the project folder: its ID as a workspace commit names
// it, where it is on disk, and the changes its status lists.
type nestedRepo struct {
	id      string
	root    string
	changes []core.GitChange
	err     error
}

// nestedState is what a project keeps of its nested repositories.
type nestedState struct {
	// gen counts the readings started; an answer of an older reading is dropped.
	gen   int
	repos []nestedRepo
	// focus is the ID of the nested repository a folder of the project tree asked for; empty
	// when the project's own repository is meant.
	focus string
	// logRepo is the ID of the nested repository the Git log walks; empty for the project's own
	// repository (git_log_repo.go).
	logRepo string
	// refGen counts the reference readings; references are the last ones by repository ID
	// (nested_refs.go).
	refGen     int
	references map[string]nestedReferences
	// slots are the color slots Core assigned to the repositories by ID, and showColors says a
	// view with several repositories shows them (nested_refs.go).
	slots      map[string]int
	showColors bool
	// folded are the repositories whose changes the Commit window hides under their header; a
	// group shows unfolded until it is folded (nested_repos_view.go).
	folded map[string]bool
}

// nestedRepositoryID is the ID of the repository at path in a workspace commit of projectRoot: its
// path relative to the project folder with "/" separators. It reports false for a repository
// outside the project folder or the project folder itself.
func nestedRepositoryID(projectRoot, path string) (string, bool) {
	rel, err := filepath.Rel(projectRoot, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	return filepath.ToSlash(rel), true
}

// loadNestedRepos reads the nested repositories of the project and the status of each in the
// background. It does nothing outside a repository or without a kernel that discovers them.
func (a *App) loadNestedRepos(p *project) {
	discoverer, ok := a.kernel.(repositoryDiscoverer)
	if !ok || !p.git.isRepository() {
		return
	}
	n := &p.nested
	n.gen++
	gen := n.gen
	kernel, root := a.kernel, p.root
	own := filepath.Clean(p.git.repositoryRoot(p.root))
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		found, err := discoverer.DiscoverWorkspaceRepositories(ctx, root)
		var repos []nestedRepo
		if err == nil {
			for _, repo := range found {
				path := filepath.Clean(filepath.FromSlash(repo.Path))
				id, inside := nestedRepositoryID(root, path)
				if !inside || path == own {
					continue
				}
				status, serr := kernel.GitStatus(core.AutomaticRefresh(ctx), path)
				repos = append(repos, nestedRepo{id: id, root: path, changes: status.Changes, err: serr})
			}
		}
		return func(a *App) {
			if p.nested.gen != gen || err != nil {
				return
			}
			p.nested.repos = repos
			if _, ok := p.nested.repo(p.nested.focus); !ok {
				p.nested.focus = ""
			}
			// A repository the log walks that left the workspace hands the log back to the project's own,
			// which loads the references too.
			if a.logFallsBack(p) {
				a.loadLog(p)
				return
			}
			// The Git Log's reference pane lists the nested repositories' references too, so they
			// are read again once the repositories are.
			if p.log.started {
				a.loadNestedReferences(p)
			}
		}
	})
}

// repo is the nested repository with ID id.
func (n *nestedState) repo(id string) (*nestedRepo, bool) {
	for i := range n.repos {
		if n.repos[i].id == id {
			return &n.repos[i], true
		}
	}
	return nil, false
}

// nestedStagedCount is the number of changes staged in the nested repositories.
func (p *project) nestedStagedCount() int {
	if p.lists.inUse() {
		return 0
	}
	n := 0
	for _, repo := range p.nested.repos {
		n += countStaged(repo.changes)
	}
	return n
}

// nestedOwner is the nested repository that owns the path full, the deepest one containing it,
// and empty when the project's own repository owns it.
func (p *project) nestedOwner(full string) string {
	owner, depth := "", -1
	for _, repo := range p.nested.repos {
		if strings.HasPrefix(full, repo.root+string(filepath.Separator)) && len(repo.root) > depth {
			owner, depth = repo.id, len(repo.root)
		}
	}
	return owner
}

// showRepositoryChangesOf opens the Commit tool window on the repository that owns full: the
// nested repository's group is marked in the window, and the project's own repository is shown
// otherwise.
func (a *App) showRepositoryChangesOf(p *project, full string) {
	p.nested.focus = p.nestedOwner(full)
	a.showChanges()
}

// stageNestedChanges stages or unstages changes of the nested repository repo, as a click on
// their checkboxes asks: a click on the repository's checkbox stages everything it can, or
// unstages everything when it is all staged. Then the nested repositories are read again.
func (a *App) stageNestedChanges(p *project, repo nestedRepo, changes []core.GitChange, all bool) {
	if p.commit.busy {
		return
	}
	var paths []string
	stage := !all
	for _, change := range changes {
		if !change.CanToggleStaging {
			continue
		}
		if all && change.Staged {
			paths = append(paths, change.StagingPaths()...)
		}
		if !all && stagesChange(change) {
			paths = append(paths, change.StagingPaths()...)
		}
	}
	if len(paths) == 0 {
		return
	}
	a.writeNestedStaging(p, repo.root, stage, paths)
}

// stageNestedChange stages or unstages one change of the nested repository repo, as the
// checkbox of its row asks.
func (a *App) stageNestedChange(p *project, repo nestedRepo, change core.GitChange) {
	if p.commit.busy || !change.CanToggleStaging {
		return
	}
	a.writeNestedStaging(p, repo.root, stagesChange(change), change.StagingPaths())
}

// writeNestedStaging stages or unstages paths of the repository at root, then reads the nested
// repositories again.
func (a *App) writeNestedStaging(p *project, root string, stage bool, paths []string) {
	if stage {
		a.performed("git.stage", surfaceButton)
	} else {
		a.performed("git.unstage", surfaceButton)
	}
	p.commit.busy = true
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		var err error
		if stage {
			err = kernel.GitStage(ctx, root, paths)
		} else {
			err = kernel.GitUnstage(ctx, root, paths)
		}
		return func(a *App) {
			p.commit.busy = false
			// The project's status is read with the nested repositories, as the group of its own changes
			// may be the one that was staged.
			a.loadGit(p)
			if err != nil {
				a.stagingFailed(stage, err)
			}
		}
	})
}

// nestedCommitTarget is the commit of one nested repository: it commits the staged changes of
// that repository alone, with the message the Commit tool window holds.
func (a *App) nestedCommitTarget(p *project, repo nestedRepo) commitTarget {
	return commitTarget{
		state:  &p.commit,
		root:   repo.root,
		repoID: repo.id,
		written: func(a *App) {
			a.loadGit(p)
		},
	}
}

// canCommitNested reports that the commit button of repo may start a commit of its staged changes.
func (p *project) canCommitNested(repo nestedRepo) bool {
	return !p.lists.inUse() && p.listsReady() && p.commit.idle() && !p.commit.busy &&
		countStaged(repo.changes) > 0 && p.commit.message() != ""
}

// stageAllRepositories stages every change of the project and of its nested repositories, or
// unstages every staged one when stage is false: the checkbox of the project's change list acts
// on all repositories it lists. The repositories are written one after another, then read again.
func (a *App) stageAllRepositories(p *project, stage bool) {
	if p.commit.busy {
		return
	}
	a.performed("git.stageAll", surfaceButton)
	p.commit.busy = true
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	projectChanges := p.git.status.Changes
	repos := append([]nestedRepo(nil), p.nested.repos...)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		var err error
		if stage {
			err = kernel.GitStageAll(ctx, root)
		} else if paths := stagedPaths(projectChanges); len(paths) > 0 {
			err = kernel.GitUnstage(ctx, root, paths)
		}
		for _, repo := range repos {
			if err != nil {
				break
			}
			var paths []string
			for _, change := range repo.changes {
				if !change.CanToggleStaging {
					continue
				}
				if stage && stagesChange(change) || !stage && change.Staged {
					paths = append(paths, change.StagingPaths()...)
				}
			}
			if len(paths) == 0 {
				continue
			}
			if stage {
				err = kernel.GitStage(ctx, repo.root, paths)
			} else {
				err = kernel.GitUnstage(ctx, repo.root, paths)
			}
		}
		return func(a *App) {
			p.commit.busy = false
			a.loadGit(p)
			a.loadNestedRepos(p)
			if err != nil {
				a.stagingFailed(stage, err)
			}
		}
	})
}

// submoduleReferenceChanged reports that the project's own status lists the nested repository with
// the given ID as changed: the reference the parent records for it has moved. A nested repository
// that has changes of its own but no moved reference shows the hint that the parent does not
// record them yet.
func (p *project) submoduleReferenceChanged(id string) bool {
	for _, change := range p.git.status.Changes {
		if strings.TrimSuffix(change.Path, "/") == id {
			return true
		}
	}
	return false
}
