package workbench

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// This file keeps the state of the Commit tool window and the actions it starts: staging a
// change, and a commit that the kernel plans (git.workspaceCommitPrepare), the user reviews
// when the plan asks for it, and the window runs one step at a time
// (git.workspaceCommitStep). What the tool window shows is declared in commit_view.go, and
// commit_page.go hosts that page in the window.

const (
	// commitRunTimeout bounds a whole run: every commit and push of the plan.
	commitRunTimeout = 5 * time.Minute
	// commitListMin and commitAreaMin are the least the change list and the commit area get
	// from the splitter between them; commitAreaHeight is the commit area's first height.
	commitListMin    = 80
	commitAreaMin    = 140
	commitAreaHeight = 200
)

// commitState is what a project's Commit tool window holds: the message being typed, the
// review that is open, and the results of the last run.
type commitState struct {
	// editor holds the commit message; message is the text area's handle on it, bound once
	// so the page edits the editor the project reads.
	editor       *text.Editor
	messageField ui.Field
	amend        bool
	// author is the "Name <email>" the next commit records as its author, empty for the
	// configured identity; it clears when a commit succeeds, as amend does.
	author ui.Field
	// signOff adds a Signed-off-by trailer to the commits; it stays on until turned off.
	signOff bool
	// optionsOpen is whether the commit options popover is open.
	optionsOpen bool
	// parents also records, in a parent repository, the new commits of the submodules
	// committed with it; it starts on, as on macOS.
	parents bool
	// busy is set while the kernel prepares, runs or stages; the actions wait for it.
	busy bool
	// review is the plan the user is asked to confirm, nil when no review is open.
	review *commitReview
	// attempt is the session of the last run, kept while its results are shown; nil when
	// there are none.
	attempt *core.WorkspaceCommitSession
	// ai is the AI message generation of the commit area (aicommit.go).
	ai aiCommitState
}

// commitReview is an open review: the kernel's plan, and the destination the user picked for
// each push whose branch tracks a differently named one.
type commitReview struct {
	prep    core.WorkspaceCommitPreparation
	choices map[string]core.PushTargetChoice
}

func newCommitState() commitState {
	c := commitState{parents: true}
	c.resetMessage()
	return c
}

// resetMessage empties the commit message with an editor of its own, so the history of the
// message that was committed cannot be undone into the next one.
func (c *commitState) resetMessage() {
	c.editor = text.NewEditor("")
	c.messageField = ui.Field{}
	c.messageField.Bind(c.editor)
}

// message is the typed commit message without the text an input method is still composing
// and without the blank space around it.
func (c *commitState) message() string {
	return strings.TrimSpace(c.editor.CommittedString())
}

// answered reports that every push of the review has a destination.
func (r *commitReview) answered() bool {
	for _, q := range r.prep.PushTargetQuestions {
		if _, ok := r.choices[q.RepositoryID]; !ok {
			return false
		}
	}
	return true
}

// repositoryRoot is the top level of the project's repository: the paths of the status are
// relative to it, and Git commits there.
func (g gitState) repositoryRoot(projectRoot string) string {
	root := g.status.RepositoryRoot
	if filepath.IsAbs(root) {
		return root
	}
	return filepath.Join(projectRoot, root)
}

// commitRepositoryID is the ID the project's repository has in a workspace commit: the
// project is the workspace, and its repository the only one.
const commitRepositoryID = "."

// commitTarget is a checkout the commit flow commits in, with its own message, review and
// results: the project's repository, which the Commit tool window commits, or a linked
// worktree, which the Changes tab of the Worktrees tab commits.
type commitTarget struct {
	state *commitState
	// root is the top level of the repository the commit runs in.
	root string
	// scope is the ChangeList scope the commit is held to; a linked worktree has none.
	scope *core.ChangeListScope
	// written reads again what a run changed.
	written func(*App)
	// console says a run shows the Console tab of the Git tool window: the commit is the
	// Commit tool window's, outside the Git tool window.
	console bool
}

// projectCommit is the commit of the project's repository, held to the active ChangeList.
func (p *project) projectCommit() commitTarget {
	return commitTarget{
		state:   &p.commit,
		root:    p.git.repositoryRoot(p.root),
		scope:   p.commitScope(),
		console: true,
		written: func(a *App) {
			a.checkoutWritten(p, p.git.repositoryRoot(p.root))
			if p.log.started {
				a.loadLog(p)
			}
		},
	}
}

// repositoryName is how the review and the results name a repository of the plan.
func (t commitTarget) repositoryName(id string) string {
	if id == commitRepositoryID {
		return filepath.Base(t.root)
	}
	return id
}

// request is the request that plans a commit of the staged changes of the target with the
// message typed, pushed afterwards when push is set. A retry leaves the scope out: Core keeps
// the scope of the run it continues.
func (t commitTarget) request(push bool) core.WorkspaceCommitRequest {
	c := t.state
	return core.WorkspaceCommitRequest{
		Repositories:            []core.WorkspaceCommitRepository{{ID: commitRepositoryID, Root: t.root}},
		Message:                 c.message(),
		Amend:                   c.amend,
		Author:                  c.authorText(),
		SignOff:                 c.signOff,
		Push:                    push,
		IncludeParentReferences: c.parents,
		PathScope:               t.scope,
	}
}

// authorText is the author typed in the commit options, without the spaces around it.
func (c *commitState) authorText() string { return strings.TrimSpace(c.author.Text()) }

// stagedCount is the number of changes that have something in the index.
func (g gitState) stagedCount() int { return countStaged(g.status.Changes) }

// countStaged is the number of changes that have something in the index.
func countStaged(changes []core.GitChange) int {
	n := 0
	for _, change := range changes {
		if change.Staged {
			n++
		}
	}
	return n
}

// canCommit reports that the commit buttons may start a commit: the active ChangeList has
// something staged and no other list does, there is a message, and no other commit work is
// under way or waiting for the user.
func (p *project) canCommit() bool {
	c := &p.commit
	return p.git.isRepository() && p.listsReady() && c.idle() &&
		p.activeStagedCount() > 0 && !p.otherStaged() && c.message() != ""
}

// idle reports that no commit work is under way or waiting for the user: nothing runs, no
// review is open and the last run does not wait for a retry.
func (c *commitState) idle() bool { return !c.busy && c.review == nil && !c.retryable() }

// retryable reports that the last run stopped part of the way and can be continued.
func (c *commitState) retryable() bool {
	return c.attempt != nil && !c.attempt.Succeeded && c.attempt.CanRetry
}

// startCommit plans a commit of the project's staged changes and runs it, through the review
// when the plan or a push asks for one. surface is where the user asked.
func (a *App) startCommit(p *project, push bool, surface string) {
	a.startCommitIn(p, p.projectCommit(), push, surface)
}

// startCommitIn is startCommit in the checkout of t.
func (a *App) startCommitIn(p *project, t commitTarget, push bool, surface string) {
	c := t.state
	if c.busy || c.review != nil {
		return
	}
	action := "git.commit"
	if push {
		action = "git.commitAndPush"
	}
	a.performed(action, surface)
	request := t.request(push)
	if request.Message == "" {
		a.notify(a.text.Commit.EnterMessage)
		return
	}
	// The macOS client always shows the plan of a push before anything runs.
	a.prepareCommit(p, t, request, push)
}

// retryCommit plans the rest of the last run in the checkout of t and shows it for review.
func (a *App) retryCommit(p *project, t commitTarget) {
	c := t.state
	if c.busy || !c.retryable() {
		return
	}
	a.performed("git.commitRetry", surfaceButton)
	previous := *c.attempt
	request := t.request(previous.Push)
	request.Message, request.Amend = previous.Message, previous.Amend
	request.Author, request.SignOff = previous.Author, previous.SignOff
	request.Previous, request.PathScope = &previous, nil
	a.prepareCommit(p, t, request, true)
}

// prepareCommit asks the kernel for the plan of request. A plan that needs a confirmation,
// or a destination for a push, opens the review, and so does review; any other plan runs.
func (a *App) prepareCommit(p *project, t commitTarget, request core.WorkspaceCommitRequest, review bool) {
	c := t.state
	c.busy = true
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		prep, err := kernel.WorkspaceCommitPrepare(ctx, request)
		return func(a *App) {
			c.busy = false
			if err != nil {
				a.commitFailed(err)
				return
			}
			if review || prep.RequiresConfirmation || len(prep.PushTargetQuestions) > 0 {
				c.review = &commitReview{prep: prep, choices: map[string]core.PushTargetChoice{}}
				return
			}
			a.runCommit(p, t, prep.Session)
		}
	})
}

// confirmReview runs the plan the user confirmed. The plan is prepared again against the
// reviewed one, with the destinations picked: when the repositories moved in between, the
// new plan is shown instead of run.
func (a *App) confirmReview(p *project, t commitTarget) {
	c := t.state
	r := c.review
	if r == nil || c.busy {
		return
	}
	if !r.answered() {
		a.notify(a.text.Commit.ChooseTarget)
		return
	}
	session := r.prep.Session
	request := t.request(session.Push)
	request.Message, request.Amend = session.Message, session.Amend
	request.Author, request.SignOff = session.Author, session.SignOff
	request.Reviewed = &session
	if session.IsRetry && c.attempt != nil {
		previous := *c.attempt
		request.Previous, request.PathScope = &previous, nil
	}
	if len(r.prep.PushTargetQuestions) > 0 {
		request.PushTargets = map[string]core.WorkspaceCommitPushTarget{}
		for _, q := range r.prep.PushTargetQuestions {
			request.PushTargets[q.RepositoryID] = q.Answer(r.choices[q.RepositoryID])
		}
	}
	c.busy = true
	kernel := a.kernel
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		prep, err := kernel.WorkspaceCommitPrepare(ctx, request)
		return func(a *App) {
			c.busy = false
			switch {
			case err != nil:
				c.review = nil
				a.commitFailed(err)
			case prep.ReviewChanged:
				c.review = &commitReview{prep: prep, choices: r.choices}
				a.notify(a.text.Commit.PlanChanged)
			case len(prep.PushTargetQuestions) > 0:
				c.review = &commitReview{prep: prep, choices: r.choices}
				a.notify(a.text.Commit.ChooseTarget)
			default:
				a.runCommit(p, t, prep.Session)
			}
		}
	})
}

// cancelReview closes the review of c without running anything.
func (a *App) cancelReview(c *commitState) { c.review = nil }

// runCommit steps session until it finishes, then reads the checkout again and reports how
// the run ended. The steps run one after another in one background task: each is a commit or
// a push the kernel guards against the state the user reviewed.
func (a *App) runCommit(p *project, t commitTarget, session core.WorkspaceCommitSession) {
	c := t.state
	c.busy, c.review, c.attempt = true, nil, nil
	if t.console {
		a.showGitConsole(itemCommit)
	}
	kernel := a.kernel
	a.background(p, commitRunTimeout, func(ctx context.Context) func(*App) {
		var err error
		for !session.Finished {
			next, stepErr := kernel.WorkspaceCommitStep(ctx, session)
			if stepErr != nil {
				err = stepErr
				break
			}
			session = next
		}
		return func(a *App) {
			c.busy = false
			t.written(a)
			if err != nil {
				a.commitFailed(err)
				return
			}
			a.commitFinished(c, session)
		}
	})
}

// commitFinished reports the end of a run. A run that succeeded clears the message, amend and
// the author; one that did not keeps its results, and a retry while it can continue.
func (a *App) commitFinished(c *commitState, session core.WorkspaceCommitSession) {
	switch {
	case session.Succeeded && session.Push:
		a.notify(a.text.Commit.Pushed)
	case session.Succeeded:
		a.notify(a.text.Commit.Done)
	default:
		a.notify(a.text.Commit.NeedsAttention)
		a.gitOperationFailed("git_commit", incompleteRun(session))
	}
	if session.Succeeded {
		c.resetMessage()
		c.amend = false
		c.author.SetText("")
		c.attempt = nil
		return
	}
	c.attempt = &session
}

// incompleteRun is the error a run that stopped part of the way is logged with: the status
// and detail of the first repository that did not finish, in the order the plan ran them.
func incompleteRun(session core.WorkspaceCommitSession) error {
	for _, id := range session.OrderedIDs {
		result := session.Results[id]
		switch result.Status {
		case core.CommitCommitted, core.CommitCommittedAndPushed, core.CommitNotIncluded:
			continue
		}
		if result.Detail != "" {
			return fmt.Errorf("%s: %s", result.Status, result.Detail)
		}
		return errors.New(string(result.Status))
	}
	return errors.New("workspace commit did not succeed")
}

// dismissResults forgets the results of the last run of c.
func (a *App) dismissResults(c *commitState) { c.attempt = nil }

// commitFailed reports a commit the kernel refused or could not run.
func (a *App) commitFailed(err error) {
	var e *core.Error
	if errors.As(err, &e) && e.Code == core.CodeGitCommitAuthorInvalid {
		a.notify(a.text.Commit.AuthorInvalid)
	} else {
		a.notify(a.text.Commit.Failed(err.Error()))
	}
	a.gitOperationFailed("git_commit", err)
}

// The log event of a Git operation that failed, and the level the kernel's event catalog
// declares for it.
const (
	operationFailedEvent = "app.notification.operation_failed"
	operationFailedLevel = core.LevelError
)

// gitOperationFailed logs a Git operation that failed.
func (a *App) gitOperationFailed(operation string, err error) {
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields(operation, err))
}

// operationFailedFields are the fields of app.notification.operation_failed.
func operationFailedFields(operation string, err error) map[string]any {
	fields := logwindow.ErrorFields(err)
	fields["operation"] = operation
	return fields
}

// stageChange stages or unstages one change, as a click on its checkbox asks: a change with
// nothing staged is staged, one that is partly staged gets the rest, and one that is fully
// staged is unstaged.
func (a *App) stageChange(p *project, change core.GitChange) {
	if p.commit.busy || !change.CanToggleStaging {
		return
	}
	stage := stagesChange(change)
	if stage {
		a.performed("git.stage", surfaceButton)
	} else {
		a.performed("git.unstage", surfaceButton)
	}
	a.writeStaging(p, stage, change.StagingPaths())
}

// stagesChange reports that a click on the checkbox of change stages it: a change that is
// staged and has nothing left in the worktree is unstaged instead.
func stagesChange(change core.GitChange) bool {
	return !change.Staged || change.Worktree
}

// allStaged reports that every one of the changes that can be staged is staged in full, and
// that there is one.
func allStaged(changes []core.GitChange) bool {
	found := false
	for _, change := range changes {
		if !change.CanToggleStaging {
			continue
		}
		if !change.Staged || change.Worktree {
			return false
		}
		found = true
	}
	return found
}

// stageAll stages every change of the active ChangeList, or unstages every staged one when
// everything is staged already, as the checkbox of the change list does. While only the
// default list exists that is every change of the repository.
func (a *App) stageAll(p *project, surface string) {
	if p.commit.busy || !p.listsReady() {
		return
	}
	if p.lists.inUse() {
		a.stageChanges(p, p.activeChanges(), surface)
		return
	}
	if allStaged(p.git.status.Changes) {
		a.unstageAll(p, surface)
		return
	}
	a.performed("git.stageAll", surface)
	p.commit.busy = true
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		err := kernel.GitStageAll(ctx, root)
		return func(a *App) { a.stagingDone(p, true, err) }
	})
}

// stageChanges stages every one of changes, or unstages them all when they are all staged,
// as the checkbox of a ChangeList section does.
func (a *App) stageChanges(p *project, changes []core.GitChange, surface string) {
	if p.commit.busy || !p.listsReady() {
		return
	}
	if allStaged(changes) {
		if paths := stagedPaths(changes); len(paths) > 0 {
			a.performed("git.unstageAll", surface)
			a.writeStaging(p, false, paths)
		}
		return
	}
	var paths []string
	for _, change := range changes {
		if change.CanToggleStaging && stagesChange(change) {
			paths = append(paths, change.StagingPaths()...)
		}
	}
	if len(paths) == 0 {
		return
	}
	a.performed("git.stageAll", surface)
	a.writeStaging(p, true, paths)
}

// unstageAll unstages every staged change.
func (a *App) unstageAll(p *project, surface string) {
	if p.commit.busy {
		return
	}
	paths := stagedPaths(p.git.status.Changes)
	if len(paths) == 0 {
		return
	}
	a.performed("git.unstageAll", surface)
	a.writeStaging(p, false, paths)
}

// stagedPaths are the paths that unstage every staged one of the changes.
func stagedPaths(changes []core.GitChange) []string {
	var paths []string
	for _, change := range changes {
		if change.Staged && change.CanToggleStaging {
			paths = append(paths, change.StagingPaths()...)
		}
	}
	return paths
}

// writeStaging stages or unstages paths and reads the status again.
func (a *App) writeStaging(p *project, stage bool, paths []string) {
	p.commit.busy = true
	kernel, root := a.kernel, p.git.repositoryRoot(p.root)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		var err error
		if stage {
			err = kernel.GitStage(ctx, root, paths)
		} else {
			err = kernel.GitUnstage(ctx, root, paths)
		}
		return func(a *App) { a.stagingDone(p, stage, err) }
	})
}

// stagingDone reports a staging change that failed and reads the status again either way.
func (a *App) stagingDone(p *project, stage bool, err error) {
	p.commit.busy = false
	a.loadGit(p)
	if err != nil {
		a.stagingFailed(stage, err)
	}
}

// stagingFailed tells the user that staging or unstaging failed and logs it.
func (a *App) stagingFailed(stage bool, err error) {
	if stage {
		a.notify(a.text.Commit.StageFailed(err.Error()))
		a.gitOperationFailed("git_stage", err)
		return
	}
	a.notify(a.text.Commit.UnstageFailed(err.Error()))
	a.gitOperationFailed("git_unstage", err)
}

// refreshChanges reads the project's status again.
func (a *App) refreshChanges(p *project) {
	a.performed("git.refreshChanges", surfaceButton)
	a.loadGit(p)
}
