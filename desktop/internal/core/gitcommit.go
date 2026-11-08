package core

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
)

// gitWriteRequest is the payload of the git.write operations this client sends. The kernel's
// request has many more fields; every one of them is optional and left out.
type gitWriteRequest struct {
	Root      string   `json:"root"`
	Operation string   `json:"operation"`
	Paths     []string `json:"paths,omitempty"`
}

// gitWriteResponse is the part of git.write's answer the client reads: whether the operation
// failed, and what Git printed when it did.
type gitWriteResponse struct {
	Output   string `json:"output"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exitCode"`
	// OperationError is a failure the kernel found after it had already started Git.
	OperationError *wireError `json:"operationError"`
}

// failure is the error the answer reports, nil when the operation succeeded. A Git process
// that exited with a status other than 0 is CodeProcessFailed, and its message is the first
// line Git printed, which is what a user needs to see.
func (r gitWriteResponse) failure() error {
	if r.OperationError != nil {
		return &Error{Command: "git.write", Code: r.OperationError.Code, Message: r.OperationError.Message, Details: r.OperationError.Details}
	}
	if r.ExitCode == 0 {
		return nil
	}
	message := firstLine(r.Stderr)
	if message == "" {
		message = firstLine(r.Output)
	}
	return &Error{Command: "git.write", Code: CodeProcessFailed, Message: message, Details: r.Output}
}

// firstLine is the first line of s that is not blank, trimmed.
func firstLine(s string) string {
	for line := range strings.Lines(s) {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
}

// gitWrite runs one git.write operation and turns a failed answer into an error.
func (c *Client) gitWrite(ctx context.Context, request gitWriteRequest) error {
	var response gitWriteResponse
	if err := c.Execute(ctx, "git.write", request, &response); err != nil {
		return err
	}
	return response.failure()
}

// StagingPaths are the paths that stage or unstage change: both sides of a rename or copy, so
// the old path is not left behind as a deletion, and the path itself otherwise.
func (change GitChange) StagingPaths() []string {
	if change.OriginalPath != "" {
		return []string{change.OriginalPath, change.Path}
	}
	return []string{change.Path}
}

// GitStage records the current content of paths in the index of the repository at root,
// including their deletion. Paths are relative to root and taken literally, never as patterns.
// A path Git refuses, or a failing git process, fails with CodeProcessFailed and the first line
// Git printed.
//
// GitStage starts git and blocks; call it from a background goroutine.
func (c *Client) GitStage(ctx context.Context, root string, paths []string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stage", Paths: nonNil(paths)})
}

// GitUnstage puts the index entries of paths back to what HEAD records, leaving the working
// tree alone. Paths are taken as GitStage takes them.
//
// GitUnstage starts git and blocks; call it from a background goroutine.
func (c *Client) GitUnstage(ctx context.Context, root string, paths []string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "unstage", Paths: nonNil(paths)})
}

// GitStageAll stages every change of the repository at root, untracked files included.
//
// GitStageAll starts git and blocks; call it from a background goroutine.
func (c *Client) GitStageAll(ctx context.Context, root string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stageAll"})
}

// WorkspaceCommitRepository binds a repository's identity in the workspace to where it is on
// disk. ID is the repository's path relative to the workspace with "/" separators, "." for the
// workspace itself; Root is where Git runs.
type WorkspaceCommitRepository struct {
	ID   string `json:"id"`
	Root string `json:"root"`
}

// PushTargetChoice is the destination the user picked for a branch whose upstream has a
// different name.
type PushTargetChoice string

const (
	// PushTargetPublish publishes the branch under its own name on the upstream's remote.
	PushTargetPublish PushTargetChoice = "publish"
	// PushTargetUpstream keeps pushing to the upstream branch, whatever it is called.
	PushTargetUpstream PushTargetChoice = "upstream"
)

// WorkspaceCommitPushTarget is a destination the user confirmed. It names the remote branch
// the user was shown, so the kernel refuses the push if the tracking configuration changed in
// between.
type WorkspaceCommitPushTarget struct {
	Choice       PushTargetChoice `json:"choice"`
	Remote       string           `json:"remote"`
	RemoteBranch string           `json:"remoteBranch"`
}

// PushTargetQuestion is a repository of a commit and push whose branch tracks a differently
// named remote branch. The push waits until the user picks one of the two destinations.
type PushTargetQuestion struct {
	RepositoryID string `json:"repositoryId"`
	// LocalBranch is the short name of the branch being pushed.
	LocalBranch string `json:"localBranch"`
	// Remote is where both destinations are.
	Remote string `json:"remote"`
	// Upstream is the upstream's short name, such as "origin/release".
	Upstream string `json:"upstream"`
	// UpstreamBranch is the upstream's branch name on Remote.
	UpstreamBranch string `json:"upstreamBranch"`
}

// Answer is the confirmation of choice for q.
func (q PushTargetQuestion) Answer(choice PushTargetChoice) WorkspaceCommitPushTarget {
	branch := q.LocalBranch
	if choice == PushTargetUpstream {
		branch = q.UpstreamBranch
	}
	return WorkspaceCommitPushTarget{Choice: choice, Remote: q.Remote, RemoteBranch: branch}
}

// WorkspaceCommitRequest asks the kernel for a plan to commit, and optionally push, the staged
// changes of the repositories of a workspace.
type WorkspaceCommitRequest struct {
	Repositories []WorkspaceCommitRepository
	Message      string
	Amend        bool
	Push         bool
	// PushTargets are the destinations the user confirmed by repository ID, answering the
	// questions of an earlier preparation.
	PushTargets map[string]WorkspaceCommitPushTarget
	// IncludeParentReferences also records, in a parent repository, the new commits of the
	// child repositories committed with it.
	IncludeParentReferences bool
	// Previous is the session of a failed attempt to retry; nil starts afresh.
	Previous *WorkspaceCommitSession
	// Reviewed is the session whose plan the user confirmed; the kernel reports
	// ReviewChanged when the repositories no longer match it. Nil asks for a first plan.
	Reviewed *WorkspaceCommitSession
}

// workspaceCommitPrepareRequest is the payload of git.workspaceCommitPrepare.
type workspaceCommitPrepareRequest struct {
	Repositories            []WorkspaceCommitRepository          `json:"repositories"`
	Message                 string                               `json:"message"`
	Amend                   bool                                 `json:"amend"`
	Push                    bool                                 `json:"push"`
	PushTargets             map[string]WorkspaceCommitPushTarget `json:"pushTargets,omitempty"`
	IncludeParentReferences bool                                 `json:"includeParentReferences"`
	Previous                *WorkspaceCommitSession              `json:"previous,omitempty"`
	Reviewed                json.RawMessage                      `json:"reviewed,omitempty"`
}

// WorkspaceCommitStatus is the kernel's stable key for where one repository of a workspace
// commit stands.
type WorkspaceCommitStatus string

const (
	CommitPending             WorkspaceCommitStatus = "pending"
	CommitNotIncluded         WorkspaceCommitStatus = "notIncluded"
	CommitCommitted           WorkspaceCommitStatus = "committed"
	CommitPushPending         WorkspaceCommitStatus = "committedPushPending"
	CommitCommittedAndPushed  WorkspaceCommitStatus = "committedAndPushed"
	CommitFailed              WorkspaceCommitStatus = "commitFailed"
	CommitHeadAdvanced        WorkspaceCommitStatus = "headAdvanced"
	CommitOutcomeUnknown      WorkspaceCommitStatus = "outcomeUnknown"
	CommitPushFailed          WorkspaceCommitStatus = "pushFailed"
	CommitReviewRequired      WorkspaceCommitStatus = "reviewRequired"
	CommitWaitingForSubmodule WorkspaceCommitStatus = "waitingForSubmodule"
)

// WorkspaceCommitResult is where one repository of a workspace commit stands. Commits that
// succeeded are never rolled back when another repository fails.
type WorkspaceCommitResult struct {
	Committed bool                  `json:"committed"`
	Pushed    bool                  `json:"pushed"`
	Status    WorkspaceCommitStatus `json:"status"`
	// Detail is what Git printed about a failure, empty otherwise.
	Detail string `json:"detail"`
}

// WorkspaceCommitState is the part of a repository's reviewed Git state the window shows.
type WorkspaceCommitState struct {
	// Head is the commit HEAD names, empty in a repository without commits.
	Head string `json:"head"`
	// Branch is the full name of the checked-out branch, such as "refs/heads/main", and empty
	// when HEAD is detached.
	Branch          string   `json:"branch"`
	StagedPaths     []string `json:"stagedPaths"`
	ConflictedPaths []string `json:"conflictedPaths"`
}

// WorkspaceCommitSession is the kernel's continuation of a workspace commit. The client hands
// it back unchanged to the next step, a retry or a review, so it keeps the exact bytes the
// kernel sent; its fields are a read-only summary of them.
type WorkspaceCommitSession struct {
	raw  json.RawMessage
	plan json.RawMessage

	// OrderedIDs are the repositories of the plan in the order they commit: a child before the
	// parent that records it.
	OrderedIDs []string
	Message    string
	Amend      bool
	Push       bool
	// IsRetry reports a plan that continues a failed attempt.
	IsRetry bool
	// States are the reviewed states of the plan's repositories by ID.
	States map[string]WorkspaceCommitState
	// Results are where each repository stands, by ID.
	Results map[string]WorkspaceCommitResult
	// Blocked are repositories that will not commit because one they depend on failed.
	Blocked []string
	// CommandFailed reports that a Git command failed, as opposed to a guard refusing a step.
	CommandFailed bool
	Finished      bool
	Succeeded     bool
	// CanRetry reports that preparing again with this session as Previous may finish the work.
	CanRetry bool
}

// errEmptySession is the encoding error of a session the kernel never sent.
var errEmptySession = errors.New("workspace commit session has no kernel state")

// MarshalJSON returns the session exactly as the kernel sent it.
func (s WorkspaceCommitSession) MarshalJSON() ([]byte, error) {
	if len(s.raw) == 0 {
		return nil, errEmptySession
	}
	return s.raw, nil
}

// UnmarshalJSON keeps the kernel's bytes and decodes the summary.
func (s *WorkspaceCommitSession) UnmarshalJSON(data []byte) error {
	var wire struct {
		Plan          json.RawMessage                  `json:"plan"`
		Results       map[string]WorkspaceCommitResult `json:"results"`
		Blocked       []string                         `json:"blocked"`
		CommandFailed bool                             `json:"commandFailed"`
		Finished      bool                             `json:"finished"`
		Succeeded     bool                             `json:"succeeded"`
		CanRetry      bool                             `json:"canRetry"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	var plan struct {
		Message    string                          `json:"message"`
		Amend      bool                            `json:"amend"`
		Push       bool                            `json:"push"`
		IsRetry    bool                            `json:"isRetry"`
		OrderedIDs []string                        `json:"orderedIds"`
		States     map[string]WorkspaceCommitState `json:"states"`
	}
	if len(wire.Plan) == 0 {
		return errors.New("workspace commit session has no plan")
	}
	if err := json.Unmarshal(wire.Plan, &plan); err != nil {
		return err
	}
	*s = WorkspaceCommitSession{
		raw:           append(json.RawMessage(nil), data...),
		plan:          append(json.RawMessage(nil), wire.Plan...),
		OrderedIDs:    plan.OrderedIDs,
		Message:       plan.Message,
		Amend:         plan.Amend,
		Push:          plan.Push,
		IsRetry:       plan.IsRetry,
		States:        plan.States,
		Results:       wire.Results,
		Blocked:       wire.Blocked,
		CommandFailed: wire.CommandFailed,
		Finished:      wire.Finished,
		Succeeded:     wire.Succeeded,
		CanRetry:      wire.CanRetry,
	}
	return nil
}

// WorkspaceCommitPreparation is the kernel's plan for a workspace commit and whether the user
// must look at it first.
type WorkspaceCommitPreparation struct {
	Session WorkspaceCommitSession `json:"session"`
	// ReviewChanged reports that the repositories no longer match the plan the user reviewed;
	// the new plan must be shown again.
	ReviewChanged bool `json:"reviewChanged"`
	// RequiresConfirmation reports a plan the user must confirm before it runs: a retry, or
	// repositories that record each other's commits.
	RequiresConfirmation bool `json:"requiresConfirmation"`
	// PushTargetQuestions are pushes that need a destination before anything is committed.
	// While there are any, the session must not be stepped.
	PushTargetQuestions []PushTargetQuestion `json:"pushTargetQuestions"`
}

// WorkspaceCommitPrepare plans a workspace commit. It reads every repository and changes
// nothing. A blank message fails with CodeInvalidRequest, and so does a plan in which no
// repository has a staged change.
//
// WorkspaceCommitPrepare starts git and blocks; call it from a background goroutine.
func (c *Client) WorkspaceCommitPrepare(ctx context.Context, request WorkspaceCommitRequest) (WorkspaceCommitPreparation, error) {
	payload := workspaceCommitPrepareRequest{
		Repositories:            nonNil(request.Repositories),
		Message:                 request.Message,
		Amend:                   request.Amend,
		Push:                    request.Push,
		PushTargets:             request.PushTargets,
		IncludeParentReferences: request.IncludeParentReferences,
		Previous:                request.Previous,
	}
	if request.Reviewed != nil {
		payload.Reviewed = request.Reviewed.plan
	}
	var preparation WorkspaceCommitPreparation
	if err := c.Execute(ctx, "git.workspaceCommitPrepare", payload, &preparation); err != nil {
		return WorkspaceCommitPreparation{}, err
	}
	return preparation, nil
}

// workspaceCommitStepRequest is the payload of git.workspaceCommitStep.
type workspaceCommitStepRequest struct {
	Session WorkspaceCommitSession `json:"session"`
}

// WorkspaceCommitStep runs at most one commit or one push of session and returns the session
// that continues it. Call it until the result is Finished. A session that was already stepped
// is refused with the reviewRequired status rather than run twice.
//
// WorkspaceCommitStep starts git and blocks; call it from a background goroutine.
func (c *Client) WorkspaceCommitStep(ctx context.Context, session WorkspaceCommitSession) (WorkspaceCommitSession, error) {
	var next WorkspaceCommitSession
	if err := c.Execute(ctx, "git.workspaceCommitStep", workspaceCommitStepRequest{Session: session}, &next); err != nil {
		return WorkspaceCommitSession{}, err
	}
	return next, nil
}
