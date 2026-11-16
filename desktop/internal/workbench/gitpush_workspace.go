package workbench

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file keeps the state and the actions of the Push Commits dialog of a workspace, which
// opens after Commit and Push as IDEA's Push dialog does: every repository of the commit with
// the branch it would push, its destination and the commits that remote lacks, the changed files
// of the selected commit, and the tag option. Core reviews every repository and orders the list
// (git.workspacePushPreview); the dialog pushes the checked ones in that order, each against its
// own reviewed preview, and skips a repository whose recorded submodule failed to push.

// workspacePushTagChoices are the choices of the dialog's tag select once Push tags is on: the
// tags of the pushed branch, which IDEA calls Current Branch, or all of them.
var workspacePushTagChoices = []core.GitPushTags{core.GitPushTagsReachable, core.GitPushTagsAll}

// workspacePushKernel is what the dialog asks of the kernel; a kernel without it offers no dialog,
// and Commit and Push then only commits.
type workspacePushKernel interface {
	WorkspacePushPreview(ctx context.Context, repositories []core.WorkspaceCommitRepository, tags core.GitPushTags, targets map[string]core.PushTargetChoice) ([]core.WorkspacePushRepository, error)
	GitPushInWorkspace(ctx context.Context, root string, preview core.GitPushPreview, tags core.GitPushTags, target core.PushTargetChoice) error
	GitCommitFiles(ctx context.Context, root, commit string) ([]core.GitCommitFile, error)
	changedFileGrouper
}

// workspacePushState is the open Push Commits dialog.
type workspacePushState struct {
	open    bool
	loading bool
	gen     int
	// err is why the last review failed as a whole.
	err string
	// bindings are the repositories the dialog reviews and names the name each shows.
	bindings []core.WorkspaceCommitRepository
	names    map[string]string
	// repos is Core's review in push order.
	repos []core.WorkspacePushRepository
	// checked are the repositories the user checked. prefer are the ones checked once the first
	// review arrives, among those ready to push; nil checks every ready one.
	checked  map[string]bool
	prefer   map[string]bool
	reviewed bool
	// folded are the repositories whose commits the list hides under their row.
	folded map[string]bool
	// targets answer divergent upstreams by repository ID.
	targets map[string]core.PushTargetChoice
	// tagsOn is the Push tags checkbox, and tags indexes workspacePushTagChoices.
	tagsOn bool
	tags   int
	// selRepo and selCommit are the selected commit, whose files the right side lists.
	selRepo   string
	selCommit string
	files     savedFiles
	filesGen  int
	filesErr  string
	fileState logFiles
	// outcomes are how the last push went for each repository it reached.
	outcomes map[string]workspacePushOutcome
	// busy is set while the pushes run.
	busy bool
}

// workspacePushOutcome is how one repository's push went.
type workspacePushOutcome struct {
	pushed bool
	// skippedFor is the submodule whose failed push kept this repository from pushing.
	skippedFor string
	err        string
}

// workspacePushStep is one push of a run: the repository, where it runs, and what it was
// reviewed against.
type workspacePushStep struct {
	id, root string
	preview  core.GitPushPreview
	target   core.PushTargetChoice
	records  []string
}

// workspacePusher is the window's kernel as the dialog uses it.
func (a *App) workspacePusher() (workspacePushKernel, bool) {
	k, ok := a.kernel.(workspacePushKernel)
	return k, ok
}

// openWorkspacePush opens the Push Commits dialog on bindings, checking the ready repositories
// among prefer, every ready one when prefer is empty. names gives each binding's label.
func (a *App) openWorkspacePush(p *project, bindings []core.WorkspaceCommitRepository, names map[string]string, prefer map[string]bool, surface actionSurface) {
	if _, ok := a.workspacePusher(); !ok || len(bindings) == 0 {
		return
	}
	s := &p.review.workspacePush
	if s.busy {
		return
	}
	if len(prefer) == 0 {
		prefer = nil
	}
	*s = workspacePushState{
		open: true, gen: s.gen + 1, bindings: bindings, names: names, prefer: prefer,
		checked: map[string]bool{}, folded: map[string]bool{}, targets: map[string]core.PushTargetChoice{},
	}
	a.performed("git.workspacePush.open", surface)
	a.loadWorkspacePush(p)
}

// closeWorkspacePush closes the dialog; it stays open while the pushes run.
func (a *App) closeWorkspacePush(p *project) {
	s := &p.review.workspacePush
	if s.busy {
		return
	}
	s.open = false
	s.gen++
	s.filesGen++
}

// pushTags is the tag scope of the dialog's pushes.
func (s *workspacePushState) pushTags() core.GitPushTags {
	if !s.tagsOn {
		return core.GitPushTagsNone
	}
	return workspacePushTagChoices[s.tags]
}

// loadWorkspacePush reads Core's review with the choices made so far.
func (a *App) loadWorkspacePush(p *project) {
	kernel, ok := a.workspacePusher()
	if !ok {
		return
	}
	s := &p.review.workspacePush
	s.loading, s.err, s.gen = true, "", s.gen+1
	gen, bindings, tags := s.gen, s.bindings, s.pushTags()
	targets := make(map[string]core.PushTargetChoice, len(s.targets))
	for id, target := range s.targets {
		targets[id] = target
	}
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		repos, err := kernel.WorkspacePushPreview(ctx, bindings, tags, targets)
		return func(a *App) {
			s := &p.review.workspacePush
			if !s.open || s.gen != gen {
				return
			}
			s.loading = false
			if err != nil {
				s.err = i18n.Shared(a.language(), "git.pushDialog.previewFailed") + " " + reviewReason(err)
				a.operationFailed("git_workspace_push_preview", err)
				return
			}
			s.repos = repos
			a.reviewedWorkspacePush(p)
		}
	})
}

// reviewedWorkspacePush applies a new review: the first one checks the preferred repositories,
// every one drops the checks of repositories that can no longer push, and the selection moves
// to the first commit when its own is gone.
func (a *App) reviewedWorkspacePush(p *project) {
	s := &p.review.workspacePush
	for _, repo := range s.repos {
		switch {
		case repo.State != core.WorkspacePushReady:
			delete(s.checked, repo.ID)
		case !s.reviewed:
			s.checked[repo.ID] = s.prefer == nil || s.prefer[repo.ID]
		}
	}
	s.reviewed = true
	if _, ok := s.commit(s.selRepo, s.selCommit); ok {
		return
	}
	for _, repo := range s.repos {
		if repo.Preview != nil && len(repo.Preview.Commits) > 0 && s.checked[repo.ID] {
			a.selectWorkspacePushCommit(p, repo.ID, repo.Preview.Commits[0].Hash)
			return
		}
	}
	s.selRepo, s.selCommit = "", ""
	s.files.reset()
	s.fileState = logFilesIdle
}

// commit is the listed commit hash of the repository id.
func (s *workspacePushState) commit(id, hash string) (core.GitCommit, bool) {
	if hash == "" {
		return core.GitCommit{}, false
	}
	for _, repo := range s.repos {
		if repo.ID != id || repo.Preview == nil {
			continue
		}
		for _, commit := range repo.Preview.Commits {
			if commit.Hash == hash {
				return commit, true
			}
		}
	}
	return core.GitCommit{}, false
}

// rootOf is where the repository id runs.
func (s *workspacePushState) rootOf(id string) string {
	for _, binding := range s.bindings {
		if binding.ID == id {
			return binding.Root
		}
	}
	return ""
}

// nameOf is the label of the repository id.
func (s *workspacePushState) nameOf(id string) string {
	if name := s.names[id]; name != "" {
		return name
	}
	if id == commitRepositoryID {
		return filepath.Base(s.rootOf(id))
	}
	return id
}

// selectWorkspacePushCommit selects a commit of the repository id and reads its changed files.
func (a *App) selectWorkspacePushCommit(p *project, id, hash string) {
	kernel, ok := a.workspacePusher()
	if !ok {
		return
	}
	s := &p.review.workspacePush
	if s.selRepo == id && s.selCommit == hash && s.fileState != logFilesIdle {
		return
	}
	s.selRepo, s.selCommit = id, hash
	s.filesGen++
	s.fileState, s.filesErr = logFilesLoading, ""
	s.files.reset()
	gen, root := s.filesGen, s.rootOf(id)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		files, err := kernel.GitCommitFiles(ctx, root, hash)
		var layer savedLayer
		if err == nil {
			changed := make([]core.GitDiffFile, len(files))
			for i, file := range files {
				changed[i] = core.GitDiffFile{Path: file.Path, Status: file.Status}
			}
			layer, err = newSavedLayer(ctx, kernel, "", changed)
		}
		return func(a *App) {
			s := &p.review.workspacePush
			if !s.open || s.filesGen != gen {
				return
			}
			if err != nil {
				s.fileState, s.filesErr = logFilesFailed, reviewReason(err)
				a.operationFailed("git_commit_files", err)
				return
			}
			s.files.reset(layer)
			s.fileState = logFilesReady
		}
	})
}

// openWorkspacePushFile opens the diff of a changed file of the selected commit.
func (a *App) openWorkspacePushFile(p *project, path string) {
	s := &p.review.workspacePush
	if s.selCommit == "" {
		return
	}
	root := s.rootOf(s.selRepo)
	for _, layer := range s.files.layers {
		for _, file := range layer.files {
			if file.Path == path {
				a.openCommitDiff(p, root, s.selCommit, core.GitCommitFile{Path: file.Path, Status: file.Status})
				return
			}
		}
	}
}

// chooseWorkspacePushTarget answers the divergent upstream of the repository id and reviews
// again with it.
func (a *App) chooseWorkspacePushTarget(p *project, id string, target core.PushTargetChoice) {
	s := &p.review.workspacePush
	if s.busy {
		return
	}
	s.targets[id] = target
	a.loadWorkspacePush(p)
}

// workspacePushSteps are the checked repositories that can push, in Core's order.
func (s *workspacePushState) workspacePushSteps() []workspacePushStep {
	var steps []workspacePushStep
	for _, repo := range s.repos {
		if !s.checked[repo.ID] || repo.State != core.WorkspacePushReady || repo.Preview == nil {
			continue
		}
		steps = append(steps, workspacePushStep{
			id: repo.ID, root: s.rootOf(repo.ID), preview: *repo.Preview,
			target: s.targets[repo.ID], records: repo.Records,
		})
	}
	return steps
}

// canPushWorkspace reports that the checked repositories may be pushed: at least one is
// checked, and each checked divergent upstream has a destination.
func (s *workspacePushState) canPushWorkspace() bool {
	if s.loading || s.busy || !s.reviewed {
		return false
	}
	any := false
	for _, repo := range s.repos {
		if !s.checked[repo.ID] || repo.State != core.WorkspacePushReady {
			continue
		}
		if repo.NeedsTarget {
			return false
		}
		any = true
	}
	return any
}

// submitWorkspacePush pushes the checked repositories one after another in Core's order. A
// repository whose recorded submodule did not push is skipped, since Git would refuse it.
func (a *App) submitWorkspacePush(p *project) {
	s := &p.review.workspacePush
	if !s.canPushWorkspace() || p.log.sync.busy {
		return
	}
	steps, tags := s.workspacePushSteps(), s.pushTags()
	a.performed("git.workspacePush", surfaceButton)
	s.busy, s.outcomes = true, map[string]workspacePushOutcome{}
	outcomes := map[string]workspacePushOutcome{}
	// The dialog stays open on a failure and shows each repository's reason under its row.
	a.runSyncAt(p, p.root, "git_push", i18n.Shared(a.language(), "git.pushing"), func(string) string {
		return i18n.Shared(a.language(), "desktop.git.pushAll.someFailed")
	}, func(ctx context.Context, kernel Kernel, _ string) (func(*App), error) {
		pusher, ok := kernel.(workspacePushKernel)
		if !ok {
			return nil, errors.New("push is not available")
		}
		var first error
		for _, step := range steps {
			if blocked := blockedBy(step, outcomes); blocked != "" {
				outcomes[step.id] = workspacePushOutcome{skippedFor: blocked}
				continue
			}
			if err := pusher.GitPushInWorkspace(ctx, step.root, step.preview, tags, step.target); err != nil {
				outcomes[step.id] = workspacePushOutcome{err: syncReason(err)}
				if first == nil {
					first = fmt.Errorf("%s: %w", step.id, err)
				}
				if errors.Is(err, context.Canceled) {
					return nil, err
				}
				continue
			}
			outcomes[step.id] = workspacePushOutcome{pushed: true}
		}
		if first != nil {
			return nil, first
		}
		return func(a *App) { a.notifySuccess(i18n.Shared(a.language(), "git.changesPushed")) }, nil
	})
	// The dialog follows the outcome: it closes once everything pushed, and otherwise shows how
	// each repository went and reviews the repositories as they are now.
	p.log.sync.done = func(a *App, err error) {
		s := &p.review.workspacePush
		s.busy = false
		s.outcomes = outcomes
		a.loadNestedRepos(p)
		if err == nil {
			a.closeWorkspacePush(p)
			return
		}
		a.loadWorkspacePush(p)
	}
}

// blockedBy is the recorded submodule of step whose push did not succeed in this run, empty
// when none failed.
func blockedBy(step workspacePushStep, outcomes map[string]workspacePushOutcome) string {
	for _, child := range step.records {
		if outcome, ok := outcomes[child]; ok && !outcome.pushed {
			return child
		}
	}
	return ""
}
