package core

import (
	"context"
	"encoding/json"
)

// RebaseBlocker is a reason Core refuses an interactive rebase.
type RebaseBlocker struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// RebaseCommit is one commit of the range a rebase replays, oldest first.
type RebaseCommit struct {
	Hash    string   `json:"hash"`
	Parents []string `json:"parents"`
	Message string   `json:"message"`
}

// RebasePreview is the reviewed range "Rebase from Here" would replay. ExpectedState is Core's
// snapshot of it, returned unchanged to GitRebaseStart; it is nil unless Allowed.
type RebasePreview struct {
	Allowed       bool            `json:"allowed"`
	Blockers      []RebaseBlocker `json:"blockers"`
	Branch        *string         `json:"branch"`
	Head          *string         `json:"head"`
	Base          *string         `json:"base"`
	Commits       []RebaseCommit  `json:"commits"`
	ExpectedState json.RawMessage `json:"expectedState"`
}

// RebaseStep is one commit of the plan with its action: pick, reword, edit, squash, fixup or
// drop. Message is the complete replacement message of a reword or squash.
type RebaseStep struct {
	Hash    string `json:"hash"`
	Action  string `json:"action"`
	Message string `json:"message,omitempty"`
}

// RebaseSession is the durable state of a rebase Lithe started. Status is starting, conflict,
// edit, paused, completed, aborted, failed or interrupted.
type RebaseSession struct {
	SessionID         string       `json:"sessionId"`
	Status            string       `json:"status"`
	Branch            string       `json:"branch"`
	OriginalHead      string       `json:"originalHead"`
	Head              *string      `json:"head"`
	RecoveryReference string       `json:"recoveryReference"`
	Steps             []RebaseStep `json:"steps"`
	CompletedSteps    int          `json:"completedSteps"`
	CurrentCommit     *string      `json:"currentCommit"`
	CurrentMessage    *string      `json:"currentMessage"`
	ConflictedPaths   []string     `json:"conflictedPaths"`
	CanContinue       bool         `json:"canContinue"`
	CanSkip           bool         `json:"canSkip"`
	CanAbort          bool         `json:"canAbort"`
}

// GitRebasePreview reads the range after the unchanged base revision.
//
// GitRebasePreview starts git and blocks; call it from a background goroutine.
func (c *Client) GitRebasePreview(ctx context.Context, root, base string) (RebasePreview, error) {
	var preview RebasePreview
	payload := struct {
		Root     string `json:"root"`
		Revision string `json:"revision"`
	}{root, base}
	if err := c.Execute(ctx, "git.rebasePreview", payload, &preview); err != nil {
		return RebasePreview{}, err
	}
	preview.Blockers = nonNil(preview.Blockers)
	preview.Commits = nonNil(preview.Commits)
	return preview, nil
}

type rebaseResponse struct {
	Session *RebaseSession `json:"session"`
}

// GitRebaseStart starts the reviewed plan, which must hold every commit of the preview once.
// It returns the session after Git ran, which may be paused at a conflict or an edit.
func (c *Client) GitRebaseStart(ctx context.Context, root string, preview RebasePreview, steps []RebaseStep) (*RebaseSession, error) {
	payload := struct {
		Root          string          `json:"root"`
		ExpectedState json.RawMessage `json:"expectedState"`
		Steps         []RebaseStep    `json:"steps"`
	}{root, preview.ExpectedState, nonNil(steps)}
	var response rebaseResponse
	_, err := c.ExecuteWithEvents(ctx, "git.rebaseStart", payload, &response, gitProgressObserver(ctx))
	return response.Session, err
}

// GitRebaseSession reads the latest rebase session of the repository, nil when there is none.
func (c *Client) GitRebaseSession(ctx context.Context, root string) (*RebaseSession, error) {
	var session *RebaseSession
	if err := c.Execute(ctx, "git.rebaseSession", gitRootRequest{Root: root}, &session); err != nil {
		return nil, err
	}
	return session, nil
}

// GitRebaseControl continues, skips or aborts a session. amendMessage and expectedHead apply to
// continuing an edit pause only.
func (c *Client) GitRebaseControl(ctx context.Context, root string, session RebaseSession, action, amendMessage, expectedHead string) (*RebaseSession, error) {
	payload := struct {
		Root         string `json:"root"`
		SessionID    string `json:"sessionId"`
		Action       string `json:"action"`
		AmendMessage string `json:"amendMessage,omitempty"`
		ExpectedHead string `json:"expectedHead,omitempty"`
	}{root, session.SessionID, action, amendMessage, expectedHead}
	var response rebaseResponse
	_, err := c.ExecuteWithEvents(ctx, "git.rebaseControl", payload, &response, gitProgressObserver(ctx))
	return response.Session, err
}
