package core

import (
	"context"
	"strings"
)

// GitFetchSubmodules is the per-fetch policy for submodules; GitFetchInherit keeps the
// user's Git configuration.
type GitFetchSubmodules string

const (
	GitFetchSubmodulesInherit  GitFetchSubmodules = "inherit"
	GitFetchSubmodulesNo       GitFetchSubmodules = "no"
	GitFetchSubmodulesOnDemand GitFetchSubmodules = "onDemand"
	GitFetchSubmodulesYes      GitFetchSubmodules = "yes"
)

// GitFetchTags is the per-fetch tag policy.
type GitFetchTags string

const (
	GitFetchTagsInherit GitFetchTags = "inherit"
	GitFetchTagsAll     GitFetchTags = "all"
	GitFetchTagsNone    GitFetchTags = "none"
	// GitFetchTagsPrune also removes local tags the remote no longer has.
	GitFetchTagsPrune GitFetchTags = "prune"
)

// GitFetchOptions are the choices of one fetch. They never change Git configuration.
type GitFetchOptions struct {
	// Remote is one configured remote name; nil fetches every remote.
	Remote     *string            `json:"remote"`
	Prune      bool               `json:"prune"`
	Submodules GitFetchSubmodules `json:"submodules"`
	Tags       GitFetchTags       `json:"tags"`
}

// DefaultGitFetchOptions fetch all remotes and prune, as Core's own default does.
func DefaultGitFetchOptions() GitFetchOptions {
	return GitFetchOptions{Prune: true, Submodules: GitFetchSubmodulesInherit, Tags: GitFetchTagsInherit}
}

// GitPullStrategy is how a pull combines a diverged history.
type GitPullStrategy string

const (
	GitPullFastForward GitPullStrategy = "ffOnly"
	GitPullMerge       GitPullStrategy = "merge"
	GitPullRebase      GitPullStrategy = "rebase"
)

// GitPullPreflight is what a pull of the current branch would meet.
type GitPullPreflight struct {
	// Upstream is the tracked remote branch, empty when the branch tracks none.
	Upstream string `json:"upstream"`
	Ahead    int    `json:"ahead"`
	Behind   int    `json:"behind"`
	Diverged bool   `json:"diverged"`
	// HasLocalChanges says the working tree is not clean.
	HasLocalChanges bool `json:"hasLocalChanges"`
	// ConfiguredStrategy is the strategy pull.rebase or pull.ff selects, empty when none.
	ConfiguredStrategy GitPullStrategy `json:"configuredStrategy"`
}

// IsUpToDate says the branch has nothing to take from its upstream.
func (p GitPullPreflight) IsUpToDate() bool { return p.Upstream != "" && p.Behind == 0 }

// GitFetch fetches the remotes of the repository at root with options, nil meaning Core's
// defaults (all remotes). Authentication is Git's own: a refused sign-in fails with
// CodeProcessFailed.
//
// GitFetch starts git and may take long; call it from a background goroutine and cancel
// ctx to stop it.
func (c *Client) GitFetch(ctx context.Context, root string, options *GitFetchOptions) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "fetch", FetchOptions: options})
}

// GitPullPreflight reports how far the current branch is from its upstream, from the
// remote-tracking state as it is now: fetch first to see the remote as it is.
func (c *Client) GitPullPreflight(ctx context.Context, root string) (GitPullPreflight, error) {
	var out GitPullPreflight
	err := c.Execute(ctx, "git.pullPreflight", gitRootRequest{Root: root}, &out)
	return out, err
}

// GitPull brings the current branch up to its upstream with strategy; GitPullFastForward
// refuses a diverged history instead of inventing a merge.
//
// GitPull starts git and may take long; call it from a background goroutine.
func (c *Client) GitPull(ctx context.Context, root string, strategy GitPullStrategy) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "pull", Mode: string(strategy)})
}

// GitUpdateBranch fast-forwards the local branch, which must not be the current one, from
// its upstream without touching HEAD.
func (c *Client) GitUpdateBranch(ctx context.Context, root string, branch GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "updateBranch", GitReference: branch.request()})
}

// IsAuthenticationFailure reports whether err is Git refusing to sign in to a remote,
// from the markers Git prints whatever its locale. Core has no dedicated code for it.
func IsAuthenticationFailure(err error) bool {
	e, ok := err.(*Error)
	if !ok {
		return false
	}
	text := e.Message + "\n" + e.Details
	for _, marker := range []string{"Authentication failed", "could not read Username", "could not read Password", "Permission denied (publickey"} {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}
