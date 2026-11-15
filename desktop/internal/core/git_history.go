package core

import (
	"context"
	"encoding/json"
)

// This file wraps the history actions of the log's commit menu: the four reviewed rewrites
// (undo, edit message, drop and squash), which Core previews and then runs only against the
// unchanged preview; cherry-pick, revert and reset, which run at once; and the merge,
// cherry-pick or revert Git left active at a conflict, with its continue, skip and abort.

// History rewrite operations, as git.historyRewritePreview and git.write name them.
const (
	HistoryUndoCommit        = "undoCommit"
	HistoryEditCommitMessage = "editCommitMessage"
	HistoryDeleteCommit      = "deleteCommit"
	HistorySquashCommits     = "squashCommits"
)

// HistoryCommit is one commit a history rewrite selects or rebuilds, with its complete message.
type HistoryCommit struct {
	Hash    string   `json:"hash"`
	Parents []string `json:"parents"`
	Message string   `json:"message"`
}

// HistoryBlocker is a reason Core refuses a history rewrite.
type HistoryBlocker struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// HistoryRewritePreview is the reviewed rewrite: the selected commits, every commit whose
// identity changes, oldest first, and the message Core suggests for an edit or a squash.
// ExpectedState is Core's snapshot of the repository, returned unchanged to GitHistoryRewrite;
// it is nil unless Allowed.
type HistoryRewritePreview struct {
	Operation        string           `json:"operation"`
	Allowed          bool             `json:"allowed"`
	Blockers         []HistoryBlocker `json:"blockers"`
	Branch           *string          `json:"branch"`
	Head             *string          `json:"head"`
	SelectedCommits  []HistoryCommit  `json:"selectedCommits"`
	AffectedCommits  []HistoryCommit  `json:"affectedCommits"`
	SuggestedMessage string           `json:"suggestedMessage"`
	ExpectedState    json.RawMessage  `json:"expectedState"`
}

// HistoryRewriteResult is the outcome of a rewrite that reached its recovery point. The branch
// moved only when MutationApplied; when OutcomeKnown is false Core could not tell, and the
// user must look at RecoveryReference before trying again. WorktreeRefresh is notNeeded, ready
// or failed.
type HistoryRewriteResult struct {
	Operation         string  `json:"operation"`
	Branch            string  `json:"branch"`
	OriginalHead      string  `json:"originalHead"`
	NewHead           *string `json:"newHead"`
	RecoveryReference string  `json:"recoveryReference"`
	MutationApplied   bool    `json:"mutationApplied"`
	OutcomeKnown      bool    `json:"outcomeKnown"`
	WorktreeRefresh   string  `json:"worktreeRefresh"`
}

// GitWarning is a problem a write reports without failing, such as a recovery ref Core could
// not clean up.
type GitWarning struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// HistoryActionCapabilities are Core's hints for the commit menu of a selection: whether
// cherry-pick, undo and squash fit it at all. They grant nothing; the preview of an action
// still decides. Head is the checked-out commit, nil on an unborn branch.
type HistoryActionCapabilities struct {
	Head          *string `json:"head"`
	CanCherryPick bool    `json:"canCherryPick"`
	CanUndo       bool    `json:"canUndo"`
	CanSquash     bool    `json:"canSquash"`
}

// MaxHistorySelection is the most commits Core takes in one history request.
const MaxHistorySelection = 1000

// GitHistoryActionCapabilities reads the hints for revisions, at most MaxHistorySelection full
// commit hashes.
func (c *Client) GitHistoryActionCapabilities(ctx context.Context, root string, revisions []string) (HistoryActionCapabilities, error) {
	payload := struct {
		Root      string   `json:"root"`
		Revisions []string `json:"revisions"`
	}{root, nonNil(revisions)}
	var capabilities HistoryActionCapabilities
	if err := c.Execute(ctx, "git.historyActionCapabilities", payload, &capabilities); err != nil {
		return HistoryActionCapabilities{}, err
	}
	return capabilities, nil
}

// GitHistoryRewritePreview previews one history rewrite of revisions: one commit, or two or
// more contiguous ones for a squash.
//
// GitHistoryRewritePreview starts git and blocks; call it from a background goroutine.
func (c *Client) GitHistoryRewritePreview(ctx context.Context, root, operation string, revisions []string) (HistoryRewritePreview, error) {
	payload := struct {
		Root      string   `json:"root"`
		Operation string   `json:"operation"`
		Revisions []string `json:"revisions"`
	}{root, operation, nonNil(revisions)}
	var preview HistoryRewritePreview
	if err := c.Execute(ctx, "git.historyRewritePreview", payload, &preview); err != nil {
		return HistoryRewritePreview{}, err
	}
	preview.Blockers = nonNil(preview.Blockers)
	preview.SelectedCommits = nonNil(preview.SelectedCommits)
	preview.AffectedCommits = nonNil(preview.AffectedCommits)
	return preview, nil
}

// historyExpectation is the part of a preview's expected state a write repeats in its own
// revision fields.
type historyExpectation struct {
	Revisions []string `json:"revisions"`
}

// historyRewriteResponse is the answer of a reviewed history write.
type historyRewriteResponse struct {
	gitWriteResponse
	HistoryRewrite *HistoryRewriteResult `json:"historyRewrite"`
	Warnings       []GitWarning          `json:"warnings"`
}

// GitHistoryRewrite runs the reviewed rewrite of preview. message is the new message of an
// edit or a squash and is ignored by the other two. Core checks the repository against the
// preview again and refuses a stale one.
//
// The result is non-nil once Core created the recovery point, also when the write then failed:
// the caller must not take an error for "nothing happened" and keeps the recovery reference
// in reach.
func (c *Client) GitHistoryRewrite(ctx context.Context, root string, preview HistoryRewritePreview, message string) (*HistoryRewriteResult, []GitWarning, error) {
	var expected historyExpectation
	if err := json.Unmarshal(preview.ExpectedState, &expected); err != nil || len(expected.Revisions) == 0 {
		return nil, nil, &Error{Command: "git.write", Code: CodeInvalidRequest, Message: "history rewrite has no reviewed preview"}
	}
	request := struct {
		gitWriteRequest
		Revisions     []string        `json:"revisions,omitempty"`
		ExpectedState json.RawMessage `json:"expectedState"`
	}{gitWriteRequest: gitWriteRequest{Root: root, Operation: preview.Operation}, ExpectedState: preview.ExpectedState}
	if preview.Operation == HistorySquashCommits {
		request.Revisions = expected.Revisions
	} else {
		request.Revision = expected.Revisions[0]
	}
	if preview.Operation == HistoryEditCommitMessage || preview.Operation == HistorySquashCommits {
		request.Message = message
	}
	var response historyRewriteResponse
	_, err := c.ExecuteWithEvents(ctx, "git.write", request, &response, gitProgressObserver(ctx))
	if err != nil {
		return nil, nil, err
	}
	return response.HistoryRewrite, nonNil(response.Warnings), response.failure()
}

// GitResetMode is how a reset treats the index and the work tree.
type GitResetMode string

// The reset modes Core accepts.
const (
	GitResetSoft  GitResetMode = "--soft"
	GitResetMixed GitResetMode = "--mixed"
	GitResetHard  GitResetMode = "--hard"
)

// GitCherryPick applies the change of the commit revision on top of the current branch. A
// cherry-pick that stops on conflicts fails with CodeProcessFailed and stays active; see
// GitOperationState.
func (c *Client) GitCherryPick(ctx context.Context, root, revision string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "cherryPick", Revision: revision})
}

// GitRevert commits the inverse of the commit revision on the current branch. A revert that
// stops on conflicts fails with CodeProcessFailed and stays active; see GitOperationState.
func (c *Client) GitRevert(ctx context.Context, root, revision string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "revert", Revision: revision})
}

// GitReset moves the current branch to revision, keeping or discarding the index and the work
// tree as mode says.
func (c *Client) GitReset(ctx context.Context, root, revision string, mode GitResetMode) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "reset", Revision: revision, Mode: string(mode)})
}

// GitOperation is the merge, rebase, cherry-pick or revert Git holds active in a repository.
// Kind is empty when there is none. Step and Total count the steps of a rebase only.
type GitOperation struct {
	Kind            string   `json:"kind"`
	Reference       *string  `json:"reference"`
	Step            *int     `json:"step"`
	Total           *int     `json:"total"`
	ConflictedPaths []string `json:"conflictedPaths"`
}

// GitOperationState reads the operation Git holds active, also one started outside Lithe.
func (c *Client) GitOperationState(ctx context.Context, root string) (GitOperation, error) {
	var state GitOperation
	if err := c.Execute(ctx, "git.operationState", gitRootRequest{Root: root}, &state); err != nil {
		return GitOperation{}, err
	}
	state.ConflictedPaths = nonNil(state.ConflictedPaths)
	return state, nil
}

// Controls of the active operation.
const (
	GitOperationContinue = "operationContinue"
	GitOperationAbort    = "operationAbort"
	GitOperationSkip     = "operationSkip"
)

// GitOperationControl continues, aborts or skips the active operation; Core picks it from
// Git's own state. Continue fails while conflicted paths remain, and skip applies to a rebase
// only.
func (c *Client) GitOperationControl(ctx context.Context, root, control string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: control})
}

// IntegrationPreflight is the local changes an integration would overwrite. BlocksEntirely
// says no part of the work tree may be dirty, as for a rebase.
type IntegrationPreflight struct {
	BlockingPaths  []string `json:"blockingPaths"`
	BlocksEntirely bool     `json:"blocksEntirely"`
}

// GitIntegrationPreflight finds the local changes that block operation, one of merge, rebase,
// cherryPick or revert, of reference.
func (c *Client) GitIntegrationPreflight(ctx context.Context, root, operation, reference string) (IntegrationPreflight, error) {
	payload := struct {
		Root      string `json:"root"`
		Operation string `json:"operation"`
		Reference string `json:"reference"`
	}{root, operation, reference}
	var preflight IntegrationPreflight
	if err := c.Execute(ctx, "git.integrationPreflight", payload, &preflight); err != nil {
		return IntegrationPreflight{}, err
	}
	preflight.BlockingPaths = nonNil(preflight.BlockingPaths)
	return preflight, nil
}
