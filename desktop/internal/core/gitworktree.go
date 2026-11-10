package core

import "context"

// GitWorktree is one working tree registered with a repository, as git.worktrees reports it.
type GitWorktree struct {
	// Path is the checkout's absolute, canonical path. A linked worktree may live outside the
	// opened project.
	Path string `json:"path"`
	// Head is the commit the worktree has checked out.
	Head string `json:"head"`
	// Branch is the fully qualified local branch the worktree has checked out, empty for a
	// detached or bare worktree.
	Branch string `json:"branch"`
	// IsCurrent says this is the worktree the request was made from.
	IsCurrent bool `json:"isCurrent"`
	// IsPrimary says this is the repository's main worktree.
	IsPrimary  bool `json:"isPrimary"`
	IsBare     bool `json:"isBare"`
	IsDetached bool `json:"isDetached"`
	IsLocked   bool `json:"isLocked"`
	// LockReason is the reason the worktree was locked with, when one was given.
	LockReason string `json:"lockReason"`
	// IsPrunable says the registration's checkout is gone, so pruning removes it.
	IsPrunable bool `json:"isPrunable"`
	// PruneReason is Git's explanation of why the registration can be pruned.
	PruneReason string `json:"pruneReason"`
}

// GitWorktrees returns the worktrees registered with the repository at root, in Git's order.
//
// GitWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitWorktrees(ctx context.Context, root string) ([]GitWorktree, error) {
	var response struct {
		Worktrees []GitWorktree `json:"worktrees"`
	}
	if err := c.Execute(ctx, "git.worktrees", struct {
		Root string `json:"root"`
	}{root}, &response); err != nil {
		return nil, err
	}
	return response.Worktrees, nil
}

// How a created worktree gets its checkout, for GitWorktreeCreation.Mode.
const (
	// GitWorktreeNewBranch creates a branch for the worktree.
	GitWorktreeNewBranch = "newBranch"
	// GitWorktreeExistingBranch checks out a local branch no other worktree has checked out.
	GitWorktreeExistingBranch = "existingBranch"
	// GitWorktreeDetached checks out a commit without a branch.
	GitWorktreeDetached = "detached"
)

// GitWorktreeCreation is what a new worktree checks out and where.
type GitWorktreeCreation struct {
	// Mode is one of GitWorktreeNewBranch, GitWorktreeExistingBranch and GitWorktreeDetached.
	Mode string
	// Name is the branch a GitWorktreeNewBranch worktree creates; the other modes take none.
	Name string
	// Reference is where the worktree starts: the start of a new branch, which tracks it when
	// it is a remote branch and no Revision is given; the local branch of a
	// GitWorktreeExistingBranch worktree; or the commit of a detached one. A detached worktree
	// may give a Revision instead.
	Reference *GitReference
	// Revision is the commit a new branch or a detached worktree starts at instead of
	// Reference's; an existing-branch worktree takes none.
	Revision string
	// Destination is the absolute path of the new checkout. Git refuses a directory that is
	// not empty.
	Destination string
	// NoCheckout registers the worktree and prepares its HEAD without filling its directory.
	NoCheckout bool
}

// GitCreateWorktree adds a worktree to the repository at root.
//
// GitCreateWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitCreateWorktree(ctx context.Context, root string, creation GitWorktreeCreation) error {
	request := gitWriteRequest{
		Root:         root,
		Operation:    "createWorktree",
		WorktreeMode: creation.Mode,
		Name:         creation.Name,
		Revision:     creation.Revision,
		Destination:  creation.Destination,
		NoCheckout:   creation.NoCheckout,
	}
	if creation.Reference != nil {
		request.GitReference = creation.Reference.request()
	}
	return c.gitWrite(ctx, request)
}

// GitRemoveWorktree removes the worktree registered at path, and its checkout, from the
// repository at root. The worktree's branch is kept. A refusal is an *Error whose code names
// its reason: CodeGitWorktreeNotRegistered, CodeGitWorktreePrimary, CodeGitWorktreeCurrent
// (path is the worktree root belongs to) or CodeGitWorktreeLocked from Core, and
// CodeGitWorktreeHasChanges when Git refuses a checkout with changes; force removes it anyway
// and deletes those changes.
//
// GitRemoveWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitRemoveWorktree(ctx context.Context, root, path string, force bool) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "removeWorktree", Destination: path, Force: force})
}

// GitLockWorktree locks the worktree registered at path, so it is not pruned or removed.
// Core refuses a path that is not registered (CodeGitWorktreeNotRegistered) and the
// primary worktree (CodeGitWorktreePrimary).
//
// GitLockWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitLockWorktree(ctx context.Context, root, path string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "lockWorktree", Destination: path})
}

// GitUnlockWorktree unlocks the worktree registered at path.
// Core refuses a path that is not registered (CodeGitWorktreeNotRegistered) and the
// primary worktree (CodeGitWorktreePrimary).
//
// GitUnlockWorktree starts git and blocks; call it from a background goroutine.
func (c *Client) GitUnlockWorktree(ctx context.Context, root, path string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "unlockWorktree", Destination: path})
}

// GitPruneWorktrees removes the registrations of the repository at root whose checkouts are
// gone. It deletes no branch and no checkout.
//
// GitPruneWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitPruneWorktrees(ctx context.Context, root string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "pruneWorktrees"})
}

// GitRepairWorktrees repairs the links between the repository at root and its worktrees,
// after a checkout or the repository was moved.
//
// GitRepairWorktrees starts git and blocks; call it from a background goroutine.
func (c *Client) GitRepairWorktrees(ctx context.Context, root string) error {
	return c.gitWrite(ctx, gitWriteRequest{Root: root, Operation: "repairWorktrees"})
}
