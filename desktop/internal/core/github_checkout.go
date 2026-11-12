package core

import "context"

// This file wraps the pull-request checkout commands (shared/contracts/github.md): a preview that
// inspects the checkout without changing it, and the checkout that rechecks the reviewed preview
// under the repository's write lease before it fetches and creates the branch.

// PullRequestCheckoutPreview is Core's proposal for checking out a pull request, with the checkout
// it was made from: the plan (its branch, conflict and actions), the HEAD, the current branch, and
// a fingerprint of the origin URL that never discloses the URL.
type PullRequestCheckoutPreview struct {
	Plan              GitHubCheckoutPlan `json:"plan"`
	Head              string             `json:"head"`
	CurrentBranch     *string            `json:"currentBranch"`
	OriginFingerprint string             `json:"originFingerprint"`
}

// GitHubCheckoutPlan is the branch a pull request's checkout would create.
type GitHubCheckoutPlan struct {
	Allowed  bool     `json:"allowed"`
	Branch   string   `json:"branch"`
	Conflict *string  `json:"conflict"`
	Actions  []string `json:"actions"`
}

// GitPullRequestCheckoutPreview previews the checkout of pull request number from headRef in the
// repository at root. A conflicting branch name fails with the git_branch_exists code. repo, when
// set, is the repository the pull request was displayed for, which Core checks origin against.
func (c *Client) GitPullRequestCheckoutPreview(ctx context.Context, root string, number uint64, headRef string, repo *GitHubRepo) (PullRequestCheckoutPreview, error) {
	var preview PullRequestCheckoutPreview
	payload := struct {
		Root               string      `json:"root"`
		Number             uint64      `json:"number"`
		HeadRef            string      `json:"headRef"`
		ExpectedRepository *GitHubRepo `json:"expectedRepository,omitempty"`
	}{root, number, headRef, repo}
	if err := c.Execute(ctx, "git.pullRequestCheckoutPreview", payload, &preview); err != nil {
		return PullRequestCheckoutPreview{}, err
	}
	return preview, nil
}

// GitPullRequestCheckout checks out the reviewed preview: the HEAD, branch and origin fingerprint
// must still match it, or Core fails with git_checkout_changed (a new review is needed). A branch
// that now exists fails with git_branch_exists; no existing ref is ever reset.
//
// GitPullRequestCheckout starts git and blocks; call it from a background goroutine.
func (c *Client) GitPullRequestCheckout(ctx context.Context, root string, number uint64, headRef string, reviewed PullRequestCheckoutPreview, repo *GitHubRepo) error {
	payload := struct {
		Root                      string      `json:"root"`
		Number                    uint64      `json:"number"`
		HeadRef                   string      `json:"headRef"`
		ExpectedHead              string      `json:"expectedHead"`
		ExpectedBranch            *string     `json:"expectedBranch"`
		ExpectedOriginFingerprint string      `json:"expectedOriginFingerprint"`
		ExpectedRepository        *GitHubRepo `json:"expectedRepository,omitempty"`
	}{root, number, headRef, reviewed.Head, reviewed.CurrentBranch, reviewed.OriginFingerprint, repo}
	var response gitWriteResponse
	if err := c.Execute(ctx, "git.pullRequestCheckout", payload, &response); err != nil {
		return err
	}
	return response.failure()
}

// GitRemoteURL reads the configured URL of remote in the repository at root, nil when it has none.
// Callers that show or log it must not disclose credentials it may contain.
func (c *Client) GitRemoteURL(ctx context.Context, root, remote string) (*string, error) {
	var response struct {
		URL *string `json:"url"`
	}
	if err := c.Execute(ctx, "git.remoteUrl", struct {
		Root   string `json:"root"`
		Remote string `json:"remote"`
	}{root, remote}, &response); err != nil {
		return nil, err
	}
	return response.URL, nil
}

// PullRequestContext is what Core knows before a pull request is created from the checkout: the
// current branch, the likely base, the branch a push would publish, whether the branch must be
// published first, whether HEAD is detached, and whether the working tree has uncommitted changes.
type PullRequestContext struct {
	CurrentBranch          *string `json:"currentBranch"`
	SuggestedBaseBranch    *string `json:"suggestedBaseBranch"`
	SuggestedPublishBranch *string `json:"suggestedPublishBranch"`
	RequiresPublish        bool    `json:"requiresPublish"`
	Detached               bool    `json:"detached"`
	HasUncommittedChanges  bool    `json:"hasUncommittedChanges"`
}

// GitPullRequestContext reads the pull-request facts of the checkout at root.
func (c *Client) GitPullRequestContext(ctx context.Context, root string) (PullRequestContext, error) {
	var result PullRequestContext
	if err := c.Execute(ctx, "git.pullRequestContext", gitRootRequest{Root: root}, &result); err != nil {
		return PullRequestContext{}, err
	}
	return result, nil
}
