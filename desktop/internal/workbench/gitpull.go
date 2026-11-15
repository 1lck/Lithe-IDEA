package workbench

import (
	"context"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file is the Pull dialog of the log tab (IDEA's Pull). It picks a repository, a remote
// branch and a strategy, then pulls the remote branch into the repository's checked-out branch
// through Core. The dialog reads the repositories when it opens; Core decides the strategy the
// dialog starts from and runs the pull. The remotes and their branches come from Core's lists,
// and the dialog only groups and shows them.

// pullKernel is the part of the kernel the Pull dialog uses. *core.Client implements it.
type pullKernel interface {
	GitRemotes(ctx context.Context, root string) ([]core.GitRemote, error)
	GitDefaultPullStrategy(ctx context.Context, preflight core.GitPullPreflight, fastForwardPossible bool) (core.GitPullStrategy, error)
	GitPullFrom(ctx context.Context, root string, source core.GitReference, strategy core.GitPullStrategy) error
}

// pullStrategies are the strategies the dialog offers, in the order of its strategy select.
var pullStrategies = []core.GitPullStrategy{core.GitPullMerge, core.GitPullRebase, core.GitPullFastForward}

// pullRepo is a repository the dialog can pull into.
type pullRepo struct {
	root string
	name string
}

// pullState is what the Pull dialog holds: the repositories of the project, what each one has
// read, and the picks of the user, which are indexes into those lists.
type pullState struct {
	gen     int
	loading bool
	// err is why a repository could not be read; the dialog still shows what it could.
	err     string
	repos   []pullRepo
	refs    map[string]core.GitReferences
	remotes map[string][]core.GitRemote
	// repo indexes repos; remote indexes the remotes of that repository and branch the remote
	// branches of that remote; strategy indexes pullStrategies.
	repo, remote, branch, strategy int
}

// pickedRemotes are the remotes of the picked repository.
func (s *pullState) pickedRemotes() []core.GitRemote {
	if s.repo < 0 || s.repo >= len(s.repos) {
		return nil
	}
	return s.remotes[s.repos[s.repo].root]
}

// pickedBranches are the remote-tracking branches of the picked remote in the picked repository.
// A remote-tracking reference belongs to the remote whose name its full name starts with.
func (s *pullState) pickedBranches() []core.GitReference {
	remotes := s.pickedRemotes()
	if s.remote < 0 || s.remote >= len(remotes) {
		return nil
	}
	prefix := "refs/remotes/" + remotes[s.remote].Name + "/"
	var out []core.GitReference
	for _, r := range s.refs[s.repos[s.repo].root].References {
		if r.Kind == "remote" && strings.HasPrefix(r.FullName, prefix) {
			out = append(out, r)
		}
	}
	return out
}

// selection is the repository, the remote branch and the strategy the dialog would pull with;
// ok is false while the picks name none.
func (s *pullState) selection() (pullRepo, core.GitReference, core.GitPullStrategy, bool) {
	branches := s.pickedBranches()
	if s.loading || s.repo < 0 || s.repo >= len(s.repos) ||
		s.branch < 0 || s.branch >= len(branches) || s.strategy < 0 || s.strategy >= len(pullStrategies) {
		return pullRepo{}, core.GitReference{}, "", false
	}
	return s.repos[s.repo], branches[s.branch], pullStrategies[s.strategy], true
}

// preselectUpstream picks the remote branch the checked-out branch of the repository at root
// tracks, when it has one that is listed; otherwise the first remote and its first branch.
func (s *pullState) preselectUpstream(root string) {
	s.remote, s.branch = 0, 0
	upstream := ""
	for _, r := range s.refs[root].References {
		if r.Kind == "local" && r.IsCurrent {
			upstream = r.UpstreamShortName
		}
	}
	if upstream == "" {
		return
	}
	full := "refs/remotes/" + upstream
	remotes := s.pickedRemotes()
	best := -1
	for i, remote := range remotes {
		if strings.HasPrefix(full, "refs/remotes/"+remote.Name+"/") && (best < 0 || len(remote.Name) > len(remotes[best].Name)) {
			best = i
		}
	}
	if best < 0 {
		return
	}
	s.remote = best
	if i := slices.IndexFunc(s.pickedBranches(), func(r core.GitReference) bool { return r.FullName == full }); i >= 0 {
		s.branch = i
	}
}

// pullRepos are the repositories the Pull dialog can pull into: the project's own, then each
// nested repository, in the order the workspace lists them.
func (a *App) pullRepos(p *project) []pullRepo {
	repos := []pullRepo{{root: p.git.repositoryRoot(p.root), name: p.repositoryName("")}}
	for _, repo := range p.nested.repos {
		repos = append(repos, pullRepo{root: repo.root, name: p.repositoryName(repo.id)})
	}
	return repos
}

// openPullDialog opens the Pull dialog. It reads every repository's references and remotes in
// the background, and the strategy Core starts from for the repository the log walks; the
// dialog starts on that repository, with the branch it tracks picked.
func (a *App) openPullDialog(p *project) {
	s := &p.log.sync
	if s.busy || !p.git.isRepository() {
		return
	}
	repos := a.pullRepos(p)
	logRoot := p.logRepositoryRoot()
	repo := 0
	for i, r := range repos {
		if r.root == logRoot {
			repo = i
		}
	}
	s.dialog = syncDialogPull
	pull := &s.pull
	gen := pull.gen + 1
	*pull = pullState{gen: gen, loading: true, repos: repos, repo: repo, strategy: 0}
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		refs := make(map[string]core.GitReferences, len(repos))
		remotes := make(map[string][]core.GitRemote, len(repos))
		var readErr error
		pk, canPull := kernel.(pullKernel)
		for _, r := range repos {
			references, err := kernel.GitReferences(ctx, r.root)
			if err != nil && readErr == nil {
				readErr = err
			}
			refs[r.root] = references
			if canPull {
				rs, err := pk.GitRemotes(ctx, r.root)
				if err != nil && readErr == nil {
					readErr = err
				}
				remotes[r.root] = rs
			}
		}
		strategy := core.GitPullFastForward
		if canPull {
			if pre, err := kernel.GitPullPreflight(ctx, logRoot); err == nil {
				if chosen, err := pk.GitDefaultPullStrategy(ctx, pre, !pre.Diverged); err == nil && chosen != "" {
					strategy = chosen
				}
			}
		}
		return func(a *App) {
			s := &p.log.sync
			if s.pull.gen != gen || s.dialog != syncDialogPull {
				return
			}
			pull := &s.pull
			pull.loading = false
			pull.refs, pull.remotes = refs, remotes
			if readErr != nil {
				pull.err = a.text.Sync.Pull.ReadFailed(syncReason(readErr))
			}
			if i := slices.Index(pullStrategies, strategy); i >= 0 {
				pull.strategy = i
			}
			pull.preselectUpstream(logRoot)
		}
	})
}

// submitPull pulls the picked remote branch into the picked repository with the picked strategy.
func (a *App) submitPull(p *project) {
	s := &p.log.sync
	pk, ok := a.kernel.(pullKernel)
	if !ok || s.busy {
		return
	}
	repo, source, strategy, ok := s.pull.selection()
	if !ok {
		return
	}
	s.dialog = syncDialogNone
	a.performed("git.pull.dialog", surfaceButton)
	t := a.text.Sync
	a.runSyncAt(p, repo.root, "git_pull", t.Updating(source.ShortName), t.UpdateFailed,
		func(ctx context.Context, kernel Kernel, root string) (func(*App), error) {
			return func(a *App) { a.notifySuccess(t.Updated(source.ShortName)) }, pk.GitPullFrom(ctx, root, source, strategy)
		})
}
