package core

import (
	"context"
	"errors"
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

// IsAuthenticationFailure reports whether err is Git refusing to sign in to a remote, which
// Core reports with the git_authentication_failed code.
func IsAuthenticationFailure(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.Code == CodeGitAuthenticationFailed
}

// GitFetchSettings is what a fetch of the repository would do without being told otherwise:
// the options Core resolves from the repository's own Git configuration (lithe.fetch.*) and
// the application defaults, and where each choice comes from.
type GitFetchSettings struct {
	// Options are the effective choices; they are Core's defaults when Invalid.
	Options GitFetchOptions
	// Sources says per choice ("prune", "submodules", "tags") where it is configured:
	// "local" for the repository's own configuration, "application" for Core's default.
	Sources map[string]string
	// TagBehavior is how Git will actually treat tags for this repository: reachable, all,
	// none, prune, custom, remoteDependent or unavailable. Empty when Core cannot resolve it.
	TagBehavior string
	// Invalid says the repository's fetch preferences cannot be resolved; Problem is Core's
	// own message about it, which may be empty.
	Invalid bool
	Problem string
}

// GitFetchSettingsOf reads, without writing anything, the fetch behaviour Git configuration
// of the repository at root selects. It starts git and blocks; call it from a background
// goroutine.
func (c *Client) GitFetchSettingsOf(ctx context.Context, root string) (GitFetchSettings, error) {
	var out struct {
		FetchOptions *GitFetchOptions `json:"fetchOptions"`
		FetchError   *struct {
			Message string `json:"message"`
		} `json:"fetchError"`
		FetchSources map[string]struct {
			Scope string `json:"scope"`
		} `json:"fetchSources"`
		Resolved *struct {
			Tags struct {
				Value string `json:"value"`
			} `json:"tags"`
		} `json:"resolvedFetchBehavior"`
	}
	if err := c.Execute(ctx, "git.executionInspect", struct {
		Root string `json:"root"`
	}{root}, &out); err != nil {
		return GitFetchSettings{}, err
	}
	settings := GitFetchSettings{Options: DefaultGitFetchOptions(), Sources: map[string]string{}}
	if out.FetchOptions != nil {
		settings.Options = *out.FetchOptions
	}
	if out.FetchError != nil {
		settings.Invalid, settings.Problem = true, out.FetchError.Message
	}
	for name, source := range out.FetchSources {
		settings.Sources[name] = source.Scope
	}
	if out.Resolved != nil {
		settings.TagBehavior = out.Resolved.Tags.Value
	}
	return settings, nil
}

// GitPullFrom brings the current branch up to source, a remote-tracking branch (kind "remote"),
// with strategy. Core splits the remote from the branch and chooses the Git arguments; the
// caller only names the reference it picked.
//
// GitPullFrom starts git and may take long; call it from a background goroutine.
func (c *Client) GitPullFrom(ctx context.Context, root string, source GitReference, strategy GitPullStrategy) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "pull", GitReference: source.request(), Mode: string(strategy)})
}

// GitRemote is one fetch remote of a repository.
type GitRemote struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// GitRemotes lists the fetch remotes of the repository at root, as Git configures them.
func (c *Client) GitRemotes(ctx context.Context, root string) ([]GitRemote, error) {
	var out struct {
		Remotes []GitRemote `json:"remotes"`
	}
	err := c.Execute(ctx, "git.remotes", gitRootRequest{Root: root}, &out)
	return out.Remotes, err
}

// GitDefaultPullStrategy is the strategy a Pull dialog preselects for preflight, which Core
// derives from the Git configuration and whether a fast-forward is possible.
func (c *Client) GitDefaultPullStrategy(ctx context.Context, preflight GitPullPreflight, fastForwardPossible bool) (GitPullStrategy, error) {
	var out struct {
		Strategy GitPullStrategy `json:"strategy"`
	}
	err := c.Execute(ctx, "git.updatePlan", struct {
		Stage               string           `json:"stage"`
		Preflight           GitPullPreflight `json:"preflight"`
		FastForwardPossible bool             `json:"fastForwardPossible"`
	}{"defaultStrategy", preflight, fastForwardPossible}, &out)
	return out.Strategy, err
}
