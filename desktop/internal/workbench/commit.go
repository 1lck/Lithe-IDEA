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
	// busy is set while the kernel prepares, runs or stages; the actions wait for it.
	busy bool
	// review is the plan the user is asked to confirm, nil when no review is open.
	review *commitReview
	// attempt is the session of the last run, kept while its results are shown; nil when
	// there are none.
	attempt *core.WorkspaceCommitSession
}

// commitReview is an open review: the kernel's plan, and the destination the user picked for
// each push whose branch tracks a differently named one.
type commitReview struct {
	prep    core.WorkspaceCommitPreparation
	choices map[string]core.PushTargetChoice
}

func newCommitState() commitState {
	c := commitState{}
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

// commitRepositoryName is how the review and the results name a repository of the plan.
func (p *project) commitRepositoryName(id string) string {
	if id == commitRepositoryID {
		return filepath.Base(p.git.repositoryRoot(p.root))
	}
	return id
}

// commitRequest is the request that plans a commit of the staged changes with the message
// typed, pushed afterwards when push is set.
func (p *project) commitRequest(push bool) core.WorkspaceCommitRequest {
	return core.WorkspaceCommitRequest{
		Repositories:            []core.WorkspaceCommitRepository{{ID: commitRepositoryID, Root: p.git.repositoryRoot(p.root)}},
		Message:                 p.commit.message(),
		Amend:                   p.commit.amend,
		Push:                    push,
		IncludeParentReferences: true,
	}
}

// stagedCount is the number of changes that have something in the index.
func (g gitState) stagedCount() int {
	n := 0
	for _, change := range g.status.Changes {
		if change.Staged {
			n++
		}
	}
	return n
}

// canCommit reports that the commit buttons may start a commit: there is something staged,
// a message, and no other commit work under way or waiting for the user.
func (p *project) canCommit() bool {
	c := &p.commit
	return p.git.isRepository() && !c.busy && c.review == nil && !c.retryable() && p.git.stagedCount() > 0 && c.message() != ""
}

// retryable reports that the last run stopped part of the way and can be continued.
func (c *commitState) retryable() bool {
	return c.attempt != nil && !c.attempt.Succeeded && c.attempt.CanRetry
}

// startCommit plans a commit of the staged changes and runs it, through the review when the
// plan or a push asks for one. surface is where the user asked.
func (a *App) startCommit(p *project, push bool, surface string) {
	c := &p.commit
	if c.busy || c.review != nil {
		return
	}
	action := "git.commit"
	if push {
		action = "git.commitAndPush"
	}
	a.performed(action, surface)
	request := p.commitRequest(push)
	if request.Message == "" {
		a.notify(a.text.Commit.EnterMessage)
		return
	}
	// The macOS client always shows the plan of a push before anything runs.
	a.prepareCommit(p, request, push)
}

// retryCommit plans the rest of the last run and shows it for review.
func (a *App) retryCommit(p *project) {
	c := &p.commit
	if c.busy || !c.retryable() {
		return
	}
	a.performed("git.commitRetry", surfaceButton)
	previous := *c.attempt
	request := p.commitRequest(previous.Push)
	request.Message, request.Amend = previous.Message, previous.Amend
	request.Previous = &previous
	a.prepareCommit(p, request, true)
}

// prepareCommit asks the kernel for the plan of request. A plan that needs a confirmation,
// or a destination for a push, opens the review, and so does review; any other plan runs.
func (a *App) prepareCommit(p *project, request core.WorkspaceCommitRequest, review bool) {
	c := &p.commit
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
			a.runCommit(p, prep.Session)
		}
	})
}

// confirmReview runs the plan the user confirmed. The plan is prepared again against the
// reviewed one, with the destinations picked: when the repositories moved in between, the
// new plan is shown instead of run.
func (a *App) confirmReview(p *project) {
	c := &p.commit
	r := c.review
	if r == nil || c.busy {
		return
	}
	if !r.answered() {
		a.notify(a.text.Commit.ChooseTarget)
		return
	}
	session := r.prep.Session
	request := p.commitRequest(session.Push)
	request.Message, request.Amend = session.Message, session.Amend
	request.Reviewed = &session
	if session.IsRetry && c.attempt != nil {
		previous := *c.attempt
		request.Previous = &previous
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
				a.runCommit(p, prep.Session)
			}
		}
	})
}

// cancelReview closes the review without running anything.
func (a *App) cancelReview(p *project) { p.commit.review = nil }

// runCommit steps session until it finishes, then reads the status again and reports how the
// run ended. The steps run one after another in one background task: each is a commit or a
// push the kernel guards against the state the user reviewed.
func (a *App) runCommit(p *project, session core.WorkspaceCommitSession) {
	c := &p.commit
	c.busy, c.review, c.attempt = true, nil, nil
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
			a.loadGit(p)
			if p.log.started {
				a.loadLog(p)
			}
			if err != nil {
				a.commitFailed(err)
				return
			}
			a.commitFinished(p, session)
		}
	})
}

// commitFinished reports the end of a run. A run that succeeded clears the message; one that
// did not keeps its results, and a retry while it can continue.
func (a *App) commitFinished(p *project, session core.WorkspaceCommitSession) {
	c := &p.commit
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

// dismissResults forgets the results of the last run.
func (a *App) dismissResults(p *project) { p.commit.attempt = nil }

// commitFailed reports a commit the kernel refused or could not run.
func (a *App) commitFailed(err error) {
	a.notify(a.text.Commit.Failed(err.Error()))
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
	if change.Staged && !change.Worktree {
		a.performed("git.unstage", surfaceButton)
		a.writeStaging(p, false, change.StagingPaths())
		return
	}
	a.performed("git.stage", surfaceButton)
	a.writeStaging(p, true, change.StagingPaths())
}

// allStaged reports that every change that can be staged is staged in full, and that there
// is one.
func (g gitState) allStaged() bool {
	found := false
	for _, change := range g.status.Changes {
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

// stageAll stages every change, or unstages every staged one when everything is staged
// already, as the checkbox of the change list does.
func (a *App) stageAll(p *project, surface string) {
	if p.commit.busy {
		return
	}
	if p.git.allStaged() {
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

// unstageAll unstages every staged change.
func (a *App) unstageAll(p *project, surface string) {
	if p.commit.busy {
		return
	}
	var paths []string
	for _, change := range p.git.status.Changes {
		if change.Staged && change.CanToggleStaging {
			paths = append(paths, change.StagingPaths()...)
		}
	}
	if len(paths) == 0 {
		return
	}
	a.performed("git.unstageAll", surface)
	a.writeStaging(p, false, paths)
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
	if err == nil {
		return
	}
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
