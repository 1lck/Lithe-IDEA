package core

import "context"

// GitWorktree is one worktree Git registers for a repository.
type GitWorktree struct {
	// Path is absolute and opaque: a linked worktree may live outside the opened folder.
	Path       string  `json:"path"`
	Head       string  `json:"head"`
	Branch     *string `json:"branch"`
	IsCurrent  bool    `json:"isCurrent"`
	IsPrimary  bool    `json:"isPrimary"`
	IsBare     bool    `json:"isBare"`
	IsDetached bool    `json:"isDetached"`
	IsLocked   bool    `json:"isLocked"`
	LockReason *string `json:"lockReason"`
	IsPrunable bool    `json:"isPrunable"`
	PruneNote  *string `json:"pruneReason"`
}

// GitWorktrees lists the registered worktrees, the primary one first and then by path. Core
// reads them with one porcelain call and does not look into each checkout.
//
// GitWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitWorktrees(ctx context.Context, root string) ([]GitWorktree, error) {
	var response struct {
		Worktrees []GitWorktree `json:"worktrees"`
	}
	if err := c.Execute(ctx, "git.worktrees", gitRootRequest{Root: root}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Worktrees), nil
}

// GitWorktreeMode says how GitCreateWorktree takes the checkout's branch.
type GitWorktreeMode string

const (
	// GitWorktreeNewBranch creates a branch named Name from a reference.
	GitWorktreeNewBranch GitWorktreeMode = "newBranch"
	// GitWorktreeExistingBranch checks out an existing local branch.
	GitWorktreeExistingBranch GitWorktreeMode = "existingBranch"
	// GitWorktreeDetached checks out a reference or revision detached.
	GitWorktreeDetached GitWorktreeMode = "detached"
)

// GitCreateWorktree adds a worktree at destination. For GitWorktreeNewBranch, name is the new
// branch and from the reference it starts at; for GitWorktreeExistingBranch, from is the local
// branch; for GitWorktreeDetached, from is the reference to check out.
//
// GitCreateWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitCreateWorktree(ctx context.Context, root, destination string, mode GitWorktreeMode, name string, from GitReference) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "createWorktree", Destination: destination,
		WorktreeMode: string(mode), Name: name, GitReference: from.request()})
}

// GitRemoveWorktree removes a registered worktree. Core refuses the current, the primary and a
// locked one; force removes a dirty one.
func (c *Client) GitRemoveWorktree(ctx context.Context, root, path string, force bool) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "removeWorktree", Destination: path, Force: force})
}

// GitLockWorktree locks a registered worktree, and GitUnlockWorktree unlocks it.
func (c *Client) GitLockWorktree(ctx context.Context, root, path string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "lockWorktree", Destination: path})
}

// GitUnlockWorktree unlocks a locked worktree.
func (c *Client) GitUnlockWorktree(ctx context.Context, root, path string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "unlockWorktree", Destination: path})
}

// GitPruneWorktrees removes the registrations whose checkout is already gone.
func (c *Client) GitPruneWorktrees(ctx context.Context, root string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "pruneWorktrees"})
}

// GitStash is one entry of the stash list. Reference is the positional name (stash@{0}); OID
// is the immutable identity writes should use.
type GitStash struct {
	Reference string `json:"reference"`
	OID       string `json:"oid"`
	Message   string `json:"message"`
	Date      string `json:"date"`
}

// GitStashes lists the stash entries, newest first.
//
// GitStashes starts git and blocks; call it from a background goroutine.
func (c *Client) GitStashes(ctx context.Context, root string) ([]GitStash, error) {
	var response struct {
		Stashes []GitStash `json:"stashes"`
	}
	if err := c.Execute(ctx, "git.stashes", gitRootRequest{Root: root}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Stashes), nil
}

// GitStashPush stashes the local changes under message, with the untracked files when asked.
func (c *Client) GitStashPush(ctx context.Context, root, message string, includeUntracked bool) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashPush", Message: message, IncludeUntracked: includeUntracked})
}

// GitStashApply applies a stash and keeps it.
func (c *Client) GitStashApply(ctx context.Context, root string, stash GitStash) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashApply", Reference: stash.OID})
}

// GitStashPop applies a stash and drops it once it applied.
func (c *Client) GitStashPop(ctx context.Context, root string, stash GitStash) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashPop", Reference: stash.OID})
}

// GitStashDrop drops a stash.
func (c *Client) GitStashDrop(ctx context.Context, root string, stash GitStash) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "stashDrop", Reference: stash.OID})
}
