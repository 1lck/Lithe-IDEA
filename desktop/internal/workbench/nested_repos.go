package workbench

import (
	"context"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file keeps the repositories of the project folder (matrix ids
// git-multi-repository-change-groups, git-workspace-staged-commit, git-multi-repository-references).
// Core discovers them, picks the one a view acts on and groups their changes; the project reads the
// status of each nested one in the background after every project status. A folder that is no
// repository itself but holds repositories is a workspace too: its views then act on the nested
// ones. The Commit tool window shows Core's groups (nested_repos_view.go), a commit binds Core's list
// (commit_nested.go), and the Git Log and the branch popup act on the repository Core picks
// (git_log_repo.go).

// repositoryDiscoverer is the part of the kernel the workspace's repositories use. Core's client
// implements it; a kernel that does not lists no nested repositories.
type repositoryDiscoverer interface {
	DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]core.WorkspaceRepository, error)
	SelectWorkspaceRepository(ctx context.Context, repositories []core.WorkspaceRepository, selected string) (core.WorkspaceRepositorySelection, error)
	GroupWorkspaceChanges(ctx context.Context, repositories []core.WorkspaceRepositoryChanges) (core.WorkspaceChangeGroups, error)
}

// nestedRepo is one repository nested in the project folder: its ID and name as Core lists them,
// where it is on disk, and the branch and changes its status reads.
type nestedRepo struct {
	id, name string
	root     string
	branch   string
	changes  []core.GitChange
	err      error
}

// nestedState is what a project keeps of the repositories of its folder.
type nestedState struct {
	// gen counts the readings started; an answer of an older reading is dropped.
	gen int
	// discovered is Core's list as it answered, the repository that contains the folder first;
	// requests hand it back to Core unchanged. repos are its nested entries with their status.
	discovered []core.WorkspaceRepository
	repos      []nestedRepo
	// others are the IDs of the repositories the Git Log does not walk, in Core's order: the
	// groups its reference pane lists (nested_refs.go).
	others []string
	// groupGen counts the groupings asked for; groups is Core's last answer, and grouped says
	// one arrived for the repositories listed.
	groupGen int
	grouped  bool
	groups   core.WorkspaceChangeGroups
	// focus is the ID of the nested repository a folder of the project tree asked for; empty
	// when the project's own repository is meant.
	focus string
	// logRepo is the ID of the nested repository the Git log walks; empty for the project's own
	// repository (git_log_repo.go).
	logRepo string
	// chosen are the Core IDs of the repositories the Git log walks together, in Core's order,
	// the first of them logRepo's; nil while it walks one (gitlog_multi.go).
	chosen []string
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

// loadNestedRepos reads the repositories of the project folder, the status of each nested one and
// their colors in the background. It does nothing with a kernel that does not discover them.
func (a *App) loadNestedRepos(p *project) {
	discoverer, ok := a.kernel.(repositoryDiscoverer)
	if !ok {
		return
	}
	n := &p.nested
	n.gen++
	gen := n.gen
	kernel, root := a.kernel, p.root
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		found, err := discoverer.DiscoverWorkspaceRepositories(ctx, root)
		var repos []nestedRepo
		var slots map[string]int
		showColors := false
		if err == nil {
			ids := make([]string, 0, len(found))
			for _, repo := range found {
				ids = append(ids, repo.ID)
				if repo.Role != core.RepositoryNested {
					continue
				}
				path := filepath.FromSlash(repo.Path)
				status, serr := kernel.GitStatus(core.AutomaticRefresh(ctx), path)
				repos = append(repos, nestedRepo{id: repo.ID, name: repo.Name, root: path, branch: status.Branch, changes: status.Changes, err: serr})
			}
			slots, showColors = assignRepositoryColors(ctx, kernel, ids)
		}
		return func(a *App) {
			if p.nested.gen != gen {
				return
			}
			if err != nil {
				a.backgroundFailed("workspace_repositories", err)
				return
			}
			n := &p.nested
			n.discovered, n.repos = found, repos
			n.slots, n.showColors = slots, showColors
			if _, ok := n.repo(n.focus); !ok {
				n.focus = ""
			}
			a.selectLogRepo(p)
			a.groupChanges(p)
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

// own is Core's entry of the repository that contains the project folder, which it lists first.
func (n *nestedState) own() (core.WorkspaceRepository, bool) {
	if len(n.discovered) > 0 && n.discovered[0].Role == core.RepositoryWorkspace {
		return n.discovered[0], true
	}
	return core.WorkspaceRepository{}, false
}

// ownID is the ID Core gives the project's own repository: "." for the project folder, ".."
// segments for a repository that contains it. It is commitRepositoryID before Core listed it.
func (p *project) ownID() string {
	if own, ok := p.nested.own(); ok {
		return own.ID
	}
	return commitRepositoryID
}

// isOwnID reports that id names the project's own repository: empty, commitRepositoryID or Core's ID.
func (p *project) isOwnID(id string) bool {
	return id == "" || id == commitRepositoryID || id == p.ownID()
}

// rootOf is where the repository with Core's ID id is on disk.
func (p *project) rootOf(id string) string {
	if p.isOwnID(id) {
		if !p.git.isRepository() {
			return ""
		}
		return p.git.repositoryRoot(p.root)
	}
	if repo, ok := p.nested.repo(id); ok {
		return repo.root
	}
	return ""
}

// hasRepository reports that the project has a repository to act on: its own, or one nested in
// its folder.
func (p *project) hasRepository() bool {
	return p.git.isRepository() || len(p.nested.repos) > 0
}

// workspaceMode reports that the views list the repositories of the folder one by one: the folder
// holds nested repositories.
func (p *project) workspaceMode() bool { return len(p.nested.repos) > 0 }

// workspaceRepository is one repository of the project folder as the branch popup, the Pull dialog
// and the Git Log's Paths filter list it.
type workspaceRepository struct {
	id, name, root string
	own            bool
}

// workspaceRepositories are the repositories of the project folder in Core's order: the project's
// own while the folder is in one, then each nested one.
func (p *project) workspaceRepositories() []workspaceRepository {
	var out []workspaceRepository
	if p.git.isRepository() {
		out = append(out, workspaceRepository{id: p.ownID(), name: p.repositoryName(""), root: p.git.repositoryRoot(p.root), own: true})
	}
	for _, repo := range p.nested.repos {
		out = append(out, workspaceRepository{id: repo.id, name: p.repositoryName(repo.id), root: repo.root})
	}
	return out
}

// branchOf is the branch the repository with ID id is on, empty before its status arrived.
func (p *project) branchOf(id string) string {
	if p.isOwnID(id) {
		return p.git.branch()
	}
	if repo, ok := p.nested.repo(id); ok && repo.err == nil {
		return repo.branch
	}
	return ""
}

// titleBranch is the branch the title bar shows: the project's own, or the one of the nested
// repository the log walks when the folder is no repository itself.
func (p *project) titleBranch() string {
	if branch := p.git.branch(); branch != "" {
		return branch
	}
	if repo := p.logRepo(); repo != nil && repo.err == nil {
		return repo.branch
	}
	return ""
}

// groupChanges asks Core in the background to group the changes of every repository of the folder
// and to plan what each checkbox writes. The answer of a grouping a newer one overtook is dropped.
func (a *App) groupChanges(p *project) {
	n := &p.nested
	discoverer, ok := a.kernel.(repositoryDiscoverer)
	if !ok || !p.workspaceMode() {
		n.grouped, n.groups = false, core.WorkspaceChangeGroups{}
		return
	}
	n.groupGen++
	gen := n.groupGen
	input := make([]core.WorkspaceRepositoryChanges, 0, len(n.discovered))
	for _, entry := range n.discovered {
		var changes []core.GitChange
		if entry.Role == core.RepositoryWorkspace {
			if !p.git.isRepository() {
				continue
			}
			changes = p.git.status.Changes
		} else if repo, ok := n.repo(entry.ID); ok {
			changes = repo.changes
		}
		input = append(input, core.WorkspaceRepositoryChanges{WorkspaceRepository: entry, Changes: changes})
	}
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		groups, err := discoverer.GroupWorkspaceChanges(ctx, input)
		return func(a *App) {
			if p.nested.groupGen != gen {
				return
			}
			if err != nil {
				a.backgroundFailed("workspace_change_groups", err)
				return
			}
			p.nested.groups, p.nested.grouped = groups, true
		}
	})
}

// changedFiles is the number of changed files the status bar counts: Core's count over every
// repository of the folder, the one the Commit window's list shows, while the folder holds nested
// ones, and the project's own status otherwise.
func (p *project) changedFiles() int {
	if p.workspaceMode() && p.nested.grouped {
		return p.nested.groups.FileCount
	}
	count, _ := p.git.changeCount()
	return count
}

// changesOf is the changes the group with Core's ID id lists: the project's status for its own
// repository, the nested repository's status otherwise.
func (p *project) changesOf(id string) []core.GitChange {
	if p.isOwnID(id) {
		return p.git.status.Changes
	}
	if repo, ok := p.nested.repo(id); ok {
		return repo.changes
	}
	return nil
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

// applyStaging writes Core's staging plan of the repository with ID id, as a click on the
// checkbox of its group asks.
func (a *App) applyStaging(p *project, id string, plan core.StagingPlan) {
	root := p.rootOf(id)
	if p.commit.busy || root == "" || len(plan.Paths) == 0 {
		return
	}
	a.writeNestedStaging(p, root, plan.Operation == core.StageChanges, plan.Paths)
}

// stageNestedChange stages or unstages one change of the nested repository repo, as the
// checkbox of its row asks.
func (a *App) stageNestedChange(p *project, repo nestedRepo, change core.GitChange) {
	if p.commit.busy || !change.CanToggleStaging {
		return
	}
	a.writeNestedStaging(p, repo.root, stagesChange(change), change.StagingPaths())
}

// writeNestedStaging stages or unstages paths of the repository at root, then reads the
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
			a.reloadGit(p)
			if err != nil {
				a.stagingFailed(stage, err)
			}
		}
	})
}

// stageWorkspace writes Core's plan of the change list's checkbox: it stages, or unstages, the
// paths of every repository it names, one repository after another, then reads them again.
func (a *App) stageWorkspace(p *project, plan core.WorkspaceStageAll) {
	if p.commit.busy || len(plan.Repositories) == 0 {
		return
	}
	stage := plan.Operation == core.StageChanges
	type write struct {
		root  string
		paths []string
	}
	var writes []write
	for _, repo := range plan.Repositories {
		if root := p.rootOf(repo.ID); root != "" && len(repo.Paths) > 0 {
			writes = append(writes, write{root: root, paths: repo.Paths})
		}
	}
	if stage {
		a.performed("git.stageAll", surfaceButton)
	} else {
		a.performed("git.unstageAll", surfaceButton)
	}
	p.commit.busy = true
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		var err error
		for _, w := range writes {
			if stage {
				err = kernel.GitStage(ctx, w.root, w.paths)
			} else {
				err = kernel.GitUnstage(ctx, w.root, w.paths)
			}
			if err != nil {
				break
			}
		}
		return func(a *App) { a.stagingDone(p, stage, err) }
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
			a.reloadGit(p)
		},
	}
}

// canCommitNested reports that the commit button of repo may start a commit of its staged changes.
func (p *project) canCommitNested(repo nestedRepo) bool {
	return !p.lists.inUse() && p.listsReady() && p.commit.idle() && !p.commit.busy &&
		countStaged(repo.changes) > 0 && p.commit.message() != ""
}
